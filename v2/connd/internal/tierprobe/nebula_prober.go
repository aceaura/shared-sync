package tierprobe

import (
	"context"
	"net"
	"sync"
	"time"

	"github.com/aceaura/shared-sync/v2/connd/internal/ladder"
	"github.com/aceaura/shared-sync/v2/connd/internal/nebula"
)

// NebulaTierProber 是接真 Nebula 的三层探测器(DESIGN_v2.md §5)。
//
//   - T0/T1:nebula 控制 sshd `list-hostmap -json`(via Fetcher)判 direct/relay,
//     叠加 overlay 心跳(via Heartbeat)确认真通 + 测 RTT。
//   - T2:对 T2 后端(Phase3 的 frpc 本地转发口)TCP 探活(via T2Probe;Phase2 占位 nil=DOWN)。
//
// 全部外部交互(ssh/网络)经接口注入,核心判定走 Classify(纯逻辑),故整体可测。
type NebulaTierProber struct {
	peerOverlayIP      string
	lighthouseUnderlay string

	fetcher nebula.Fetcher // 取 hostmap;nil 则 T0/T1 仅靠心跳(无法判 direct,保守 relay)
	hb      Heartbeat      // overlay 心跳

	// T2Probe 探测 T2 后端健康;nil 表示 Phase3 未接入(恒 DOWN)。
	t2 Heartbeat

	mu         sync.Mutex
	lastRemote string
}

// Options 构造 NebulaTierProber。
type Options struct {
	PeerOverlayIP      string
	LighthouseUnderlay string // lighthouse 的 underlay host(host 或 host:port),用于排除 currentRemote=lighthouse
	Fetcher            nebula.Fetcher
	Heartbeat          Heartbeat
	T2Probe            Heartbeat // nil = Phase3 未接入(T2 恒 DOWN)
}

// NewNebulaTierProber 构造。
func NewNebulaTierProber(opt Options) *NebulaTierProber {
	return &NebulaTierProber{
		peerOverlayIP:      opt.PeerOverlayIP,
		lighthouseUnderlay: opt.LighthouseUnderlay,
		fetcher:            opt.Fetcher,
		hb:                 opt.Heartbeat,
		t2:                 opt.T2Probe,
	}
}

// Peer 实现 TierProber。
func (p *NebulaTierProber) Peer() string { return p.peerOverlayIP }

// ProbeTiers 实现 TierProber:一次全量三层探测。
func (p *NebulaTierProber) ProbeTiers(ctx context.Context) Result {
	at := time.Now()

	// 1) overlay 心跳(权威健康兜底,也驱动 nebula promote)。
	var reachable bool
	var rtt time.Duration
	if p.hb != nil {
		reachable, rtt = p.hb.Beat(ctx)
	}

	// 2) hostmap 判 direct/relay(滞后,需心跳兜)。
	peerPath := nebula.PeerUnknown
	currentRemote := ""
	if p.fetcher != nil {
		if hr, err := nebula.QueryHostmap(ctx, p.fetcher, p.peerOverlayIP, p.lighthouseUnderlay); err == nil {
			peerPath = hr.Path
			currentRemote = hr.CurrentRemote
		}
		// QueryHostmap 失败(如 sshd 暂不可用):peerPath 保持 UNKNOWN。
		// 若心跳仍通,Classify 会归为 T1(保守不误升 T0),符合设计。
	}

	// 3) T2 后端探活(Phase3 接入)。
	var t2Healthy bool
	var t2RTT time.Duration
	if p.t2 != nil {
		t2Healthy, t2RTT = p.t2.Beat(ctx)
	}

	tiers := Classify(peerPath, reachable, rtt, t2Healthy, t2RTT)

	p.mu.Lock()
	p.lastRemote = currentRemote
	p.mu.Unlock()

	return Result{
		Tiers:         tiers,
		Peer:          p.peerOverlayIP,
		CurrentRemote: currentRemote,
		At:            at,
	}
}

// LastCurrentRemote 返回最近一次 hostmap 的 currentRemote(诊断/状态用)。
func (p *NebulaTierProber) LastCurrentRemote() string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.lastRemote
}

// ---------------------------------------------------------------------------
// TCPHeartbeat:对 overlay 内数据中心 host:port 做 TCP 拨号心跳。
// 既确认 overlay 路径真通、测 RTT,又产生 overlay 流量驱动 nebula try_promote。
// ---------------------------------------------------------------------------

// TCPHeartbeat 用 TCP 拨号实现 Heartbeat。
type TCPHeartbeat struct {
	// Addr:目标 "host:port"(如 数据中心 overlay 10.77.0.2:8418)。
	Addr string
	// Timeout:单次拨号超时。
	Timeout time.Duration
}

// NewTCPHeartbeat 构造。
func NewTCPHeartbeat(addr string, timeout time.Duration) *TCPHeartbeat {
	if timeout <= 0 {
		timeout = 2 * time.Second
	}
	return &TCPHeartbeat{Addr: addr, Timeout: timeout}
}

// Beat 实现 Heartbeat。
func (h *TCPHeartbeat) Beat(ctx context.Context) (bool, time.Duration) {
	if h.Addr == "" {
		return false, 0
	}
	d := net.Dialer{Timeout: h.Timeout}
	dctx, cancel := context.WithTimeout(ctx, h.Timeout)
	defer cancel()
	start := time.Now()
	conn, err := d.DialContext(dctx, "tcp", h.Addr)
	rtt := time.Since(start)
	if err != nil {
		return false, 0
	}
	_ = conn.Close()
	return true, rtt
}

// ---------------------------------------------------------------------------
// FakeTierProber / FakeHeartbeat —— 测试/dry-run 用,完全确定性。
// ---------------------------------------------------------------------------

// FakeHeartbeat 始终返回固定结果。
type FakeHeartbeat struct {
	Reachable bool
	RTTVal    time.Duration
}

// Beat 实现 Heartbeat。
func (f FakeHeartbeat) Beat(ctx context.Context) (bool, time.Duration) {
	return f.Reachable, f.RTTVal
}

// FakeTierProber 按脚本/固定向量返回各层状态(测试/dry-run)。
type FakeTierProber struct {
	mu     sync.Mutex
	peer   string
	script [][]ladder.TierState
	idx    int
	fixed  []ladder.TierState
}

// NewFixedTierProber 始终返回固定健康向量。
func NewFixedTierProber(peer string, health ...ladder.TierState) *FakeTierProber {
	return &FakeTierProber{peer: peer, fixed: health}
}

// NewScriptedTierProber 逐次返回脚本里的向量;耗尽后重复最后一个。
func NewScriptedTierProber(peer string, script ...[]ladder.TierState) *FakeTierProber {
	return &FakeTierProber{peer: peer, script: script}
}

// Peer 实现 TierProber。
func (f *FakeTierProber) Peer() string { return f.peer }

// ProbeTiers 实现 TierProber。
func (f *FakeTierProber) ProbeTiers(ctx context.Context) Result {
	f.mu.Lock()
	defer f.mu.Unlock()
	var h []ladder.TierState
	if f.fixed != nil {
		h = f.fixed
	} else if len(f.script) == 0 {
		h = make([]ladder.TierState, NumTiers) // 全 DOWN
	} else {
		i := f.idx
		if i >= len(f.script) {
			i = len(f.script) - 1
		} else {
			f.idx++
		}
		h = f.script[i]
	}
	tiers := make([]TierStatus, NumTiers)
	for i := 0; i < NumTiers; i++ {
		st := ladder.TierDown
		if i < len(h) {
			st = h[i]
		}
		tiers[i] = TierStatus{State: st}
	}
	return Result{Tiers: tiers, Peer: f.peer, At: time.Now()}
}
