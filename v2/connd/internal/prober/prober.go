// Package prober 抽象"探测当前到 peer 的连接路径并归类"这件事。
//
// 设计要点(Phase0):接口清晰、可注入。状态机(fsm 包)只消费 Result,
// 不关心探测怎么实现。真实实现可后续替换为解析 nebula 状态(SIGUSR1 打印
// hostmap)/ overlay 内 ICMP ping + handshake 信息,而上层无需改动。
package prober

import (
	"context"
	"time"

	"github.com/aceaura/shared-sync/v2/connd/internal/fsm"
)

// Result 是一次探测的结果。
type Result struct {
	// Path:本次到 peer 的路径归类(DIRECT 直连 / RELAY 中继 / DOWN 不通)。
	Path fsm.Path
	// RTT:测得往返时延;Path==DOWN 时为 0。
	RTT time.Duration
	// RelayUp:中继路径本次是否可达(用于区分"直连断"与"对端真的下线",DESIGN_v2.md §5)。
	RelayUp bool
	// At:探测完成时刻。
	At time.Time
	// Err:探测过程中的非致命错误(如部分探测超时);Path 仍尽力给出。
	Err error
}

// ToProbe 把探测结果转成 fsm.Probe(状态机输入)。
func (r Result) ToProbe() fsm.Probe {
	return fsm.Probe{
		DirectPath: r.Path,
		RelayUp:    r.RelayUp,
		RTT:        r.RTT,
	}
}

// Prober 探测当前到指定 peer 的连接路径。实现必须是并发安全的、可被 ctx 取消的。
type Prober interface {
	// Probe 执行一次探测。ctx 用于超时/取消;实现应在 ctx 取消时尽快返回。
	Probe(ctx context.Context) Result
	// Peer 返回被探测对端的标识(overlay IP 或主机名),供状态暴露使用。
	Peer() string
}
