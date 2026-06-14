// Package tierprobe 实现「每层独立健康探测」(DESIGN_v2.md §5),产出阶梯状态机
// (ladder 包)需要的各层健康向量。
//
// 这是 Phase2 对 Phase0 prober 的泛化。Phase0 的 prober 只给单一 Path(DIRECT/RELAY/
// DOWN);v2 需要对**每一层独立**判定健康(T0 direct / T1 udp_relay / T2 tcp_relay),
// 因为升降级要看整个健康向量(§4)、且要区分「路径断」与「对端真下线」(§5:多层
// 同时探测,全不通才是数据中心离线)。
//
// 三层判定法(DESIGN_v2.md §5,Phase1b handoff):
//
//   - T0/T1(Nebula):查控制 sshd `list-hostmap -json` 的 currentRemote 定位当前
//     underlay 路径(direct/relay),**叠加** overlay 内对数据中心的轻量心跳确认
//     (hostmap 降级有 ~10-15s 滞后,须靠心跳兜住):
//   - currentRemote=direct 且心跳通 → T0 健康(T1 也视为可用:relay 是 T0 的退路)。
//   - currentRemote=relay/空 且心跳通 → T1 健康,T0 不健康。
//   - 心跳不通 → T0/T1 都不健康(此路径当前不可用)。
//   - T2(TCP 隧道):对 T2 后端(Phase3 的 frpc 本地转发端口)做 TCP 探活。
//     Phase2 该后端尚未接入,探测占位实现默认 T2 不健康(可注入)。
//
// 取数据(网络/ssh)与判定分离,核心判定函数 Classify 是纯逻辑可测。
package tierprobe

import (
	"context"
	"time"

	"github.com/aceaura/shared-sync/v2/connd/internal/ladder"
	"github.com/aceaura/shared-sync/v2/connd/internal/nebula"
)

// 层索引约定(与 ladder 一致:0 最优)。
const (
	TierDirect   = 0 // T0:Nebula UDP 直连
	TierUDPRelay = 1 // T1:Nebula UDP 中继
	TierTCPRelay = 2 // T2:frp 式 TCP 隧道兜底
	NumTiers     = 3
)

// TierName 返回层的人类可读名(T0/T1/T2 + 含义),供状态暴露。
func TierName(i int) string {
	switch i {
	case TierDirect:
		return "T0"
	case TierUDPRelay:
		return "T1"
	case TierTCPRelay:
		return "T2"
	default:
		return "T?"
	}
}

// TierStatus 是某一层一次探测的结果。
type TierStatus struct {
	// State:该层健康判定(UP/DOWN),直接喂 ladder。
	State ladder.TierState
	// RTT:该层测得 RTT(仅 UP 有意义)。
	RTT time.Duration
	// Detail:诊断信息(如 currentRemote、错误原因)。
	Detail string
}

// Result 是一次全量探测:各层状态 + 元信息。
type Result struct {
	// Tiers:长度 NumTiers,Tiers[i] 为第 i 层状态。
	Tiers []TierStatus
	// PeerOverlayIP:被探测的数据中心 overlay IP。
	Peer string
	// CurrentRemote:hostmap 报告的当前 underlay 端点(诊断/状态展示)。
	CurrentRemote string
	// At:探测完成时刻。
	At time.Time
}

// Health 返回喂给 ladder.Machine.Tick 的健康向量。
func (r Result) Health() []ladder.TierState {
	h := make([]ladder.TierState, len(r.Tiers))
	for i, t := range r.Tiers {
		h[i] = t.State
	}
	return h
}

// ActiveRTT 返回某层的 RTT(越界返回 0)。
func (r Result) RTT(i int) time.Duration {
	if i < 0 || i >= len(r.Tiers) {
		return 0
	}
	return r.Tiers[i].RTT
}

// TierProber 探测各层健康。实现须并发安全、可被 ctx 取消。
type TierProber interface {
	// ProbeTiers 执行一次全量探测,返回各层状态。
	ProbeTiers(ctx context.Context) Result
	// Peer 返回被探测数据中心的 overlay IP。
	Peer() string
}

// Heartbeat 抽象「overlay 内对数据中心的轻量心跳」(确认路径真的通 + 测 RTT,
// 并产生 overlay 流量驱动 nebula promote)。可注入(测试/真实 TCP 拨号)。
type Heartbeat interface {
	// Beat 对数据中心做一次心跳。reachable=是否通,rtt=往返时延。
	Beat(ctx context.Context) (reachable bool, rtt time.Duration)
}

// Classify 是**纯逻辑**核心:由 hostmap 判定 + overlay 心跳结果 + T2 探活,
// 推出各层健康向量。无网络,完全可测。
//
//	peerPath        : hostmap 对数据中心 peer 的判定(DIRECT/RELAY/UNKNOWN)
//	overlayReachable: overlay 心跳是否通(权威兜底,压过 hostmap 的滞后)
//	overlayRTT      : 心跳 RTT
//	t2Healthy/t2RTT : T2 后端探活结果(Phase2 占位 false)
func Classify(peerPath nebula.PeerPath, overlayReachable bool, overlayRTT time.Duration,
	t2Healthy bool, t2RTT time.Duration) []TierStatus {

	tiers := make([]TierStatus, NumTiers)

	// ---- T0 / T1:Nebula overlay 路径 ----
	// 心跳是权威健康兜底:hostmap 可能滞后(direct 断了 currentRemote 残留 10-15s)。
	// 规则:
	//   心跳通 + hostmap=DIRECT  → T0 UP,T1 UP(relay 是 T0 的现成退路,视为可用)
	//   心跳通 + hostmap=RELAY/?  → T0 DOWN,T1 UP(当前经中继,直连未建)
	//   心跳不通                  → T0 DOWN,T1 DOWN(overlay 路径整体不可用)
	switch {
	case overlayReachable && peerPath == nebula.PeerDirect:
		tiers[TierDirect] = TierStatus{State: ladder.TierUp, RTT: overlayRTT, Detail: "direct+heartbeat"}
		tiers[TierUDPRelay] = TierStatus{State: ladder.TierUp, RTT: overlayRTT, Detail: "relay available (fallback of direct)"}
	case overlayReachable:
		tiers[TierDirect] = TierStatus{State: ladder.TierDown, Detail: "no direct (currentRemote not direct)"}
		tiers[TierUDPRelay] = TierStatus{State: ladder.TierUp, RTT: overlayRTT, Detail: "relay+heartbeat"}
	default:
		tiers[TierDirect] = TierStatus{State: ladder.TierDown, Detail: "overlay unreachable"}
		tiers[TierUDPRelay] = TierStatus{State: ladder.TierDown, Detail: "overlay unreachable"}
	}

	// ---- T2:TCP 隧道兜底(Phase3 接入;Phase2 占位)----
	if t2Healthy {
		tiers[TierTCPRelay] = TierStatus{State: ladder.TierUp, RTT: t2RTT, Detail: "tcp tunnel"}
	} else {
		tiers[TierTCPRelay] = TierStatus{State: ladder.TierDown, Detail: "tcp tunnel backend not ready (phase3)"}
	}

	return tiers
}
