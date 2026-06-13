package prober

import (
	"context"
	"net"
	"time"

	"github.com/aceaura/shared-sync/v2/connd/internal/fsm"
)

// NebulaProber 是 Phase0 的真实探测器**占位实现**。
//
// 思路(DESIGN_v2.md §5):
//   - "通不通":overlay 内对 peer 发轻量探测(此处用 TCP 拨号到 overlay IP 的
//     探测端口作占位;真实可换 ICMP ping 或 nebula 心跳)。
//   - "DIRECT vs RELAY":需要读 nebula 的 hostmap —— nebula 支持向其进程发
//     SIGUSR1 把 hostmap 打到日志,或解析 nebula stats。Phase0 暂未解析,
//     统一按 ClassifyHook 注入的判定函数归类,默认占位为 RELAY(保守:
//     未证实直连就当作中继,避免误升级)。
//
// TODO(phase1): 实现 hostmap 解析以真正区分 direct/relay:
//   - 方式A:向 nebula 进程发 SIGUSR1,从其日志/stderr 抓 "punchy"/"relay" 标记;
//   - 方式B:启用 nebula 的 -test 或 stats(prometheus/统计监听端口)读 remote 类型;
//   - 方式C:overlay 内 ping 的同时,比对 peer 的 underlay endpoint 是否为 relay IP。
type NebulaProber struct {
	// peerOverlayIP:peer 的 overlay 虚拟 IP(如 10.77.0.3)。
	peerOverlayIP string
	// probePort:overlay 内用于探测可达性的 TCP 端口(占位;真实可用 ICMP)。
	probePort string
	// relayUnderlayIP:relay 的公网/underlay IP,用于(将来)判定路径是否经中继。
	relayUnderlayIP string
	// dialTimeout:单次探测拨号超时。
	dialTimeout time.Duration

	// ClassifyHook 可注入,覆盖默认归类逻辑(主要给 Phase1 接 hostmap 解析,
	// 以及测试)。reachable 表示 overlay 探测是否成功;返回最终 Path。
	ClassifyHook func(reachable bool) fsm.Path
}

// NewNebulaProber 构造占位探测器。
func NewNebulaProber(peerOverlayIP, probePort, relayUnderlayIP string, dialTimeout time.Duration) *NebulaProber {
	if probePort == "" {
		probePort = "4242" // nebula 默认 UDP 端口号,这里仅作占位端口
	}
	if dialTimeout <= 0 {
		dialTimeout = 2 * time.Second
	}
	return &NebulaProber{
		peerOverlayIP:   peerOverlayIP,
		probePort:       probePort,
		relayUnderlayIP: relayUnderlayIP,
		dialTimeout:     dialTimeout,
	}
}

// Peer 实现 Prober。
func (n *NebulaProber) Peer() string { return n.peerOverlayIP }

// Probe 实现 Prober。Phase0:仅判定可达性,归类委托 ClassifyHook(默认 RELAY)。
func (n *NebulaProber) Probe(ctx context.Context) Result {
	at := time.Now()
	reachable, rtt, err := n.reach(ctx)

	classify := n.ClassifyHook
	if classify == nil {
		classify = defaultClassify
	}
	path := classify(reachable)

	return Result{
		Path: path,
		RTT:  rtt,
		// Phase0 占位:把"overlay 可达"近似当作中继可达。
		// TODO(phase1): 独立探测 relay 路径以精确区分对端下线 vs 仅直连断。
		RelayUp: reachable,
		At:      at,
		Err:     err,
	}
}

// defaultClassify:保守归类。不可达 → DOWN;可达但未证实直连 → RELAY。
// 这样在真正的 hostmap 解析接入前,状态机不会被误升级到 DIRECT。
func defaultClassify(reachable bool) fsm.Path {
	if !reachable {
		return fsm.PathDown
	}
	return fsm.PathRelay
}

// reach 占位可达性探测:向 peer overlay IP 的 probePort 拨 TCP。
// 真实环境应换 ICMP echo 或 nebula 自带心跳;此处仅为接口/流程可跑通。
func (n *NebulaProber) reach(ctx context.Context) (ok bool, rtt time.Duration, err error) {
	d := net.Dialer{Timeout: n.dialTimeout}
	dctx, cancel := context.WithTimeout(ctx, n.dialTimeout)
	defer cancel()

	start := time.Now()
	conn, err := d.DialContext(dctx, "tcp", net.JoinHostPort(n.peerOverlayIP, n.probePort))
	rtt = time.Since(start)
	if err != nil {
		return false, 0, err
	}
	_ = conn.Close()
	return true, rtt, nil
}
