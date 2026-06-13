package prober

import (
	"context"
	"sync"
	"time"
)

// FakeProber 是测试/演示用探测器:按预置脚本或固定结果返回,完全确定性。
// 也可用于 connd 的 dry-run 模式(无真实 nebula 时跑通整条控制链路)。
type FakeProber struct {
	mu      sync.Mutex
	peer    string
	script  []Result // 逐次 Probe 依序返回;耗尽后重复最后一个
	idx     int
	fixed   *Result // 若非 nil,忽略 script,始终返回该结果
}

// NewFakeProber 用脚本构造。script 为空时 Probe 返回 DOWN。
func NewFakeProber(peer string, script ...Result) *FakeProber {
	return &FakeProber{peer: peer, script: script}
}

// NewFixedProber 始终返回固定结果。
func NewFixedProber(peer string, r Result) *FakeProber {
	return &FakeProber{peer: peer, fixed: &r}
}

// Peer 实现 Prober。
func (f *FakeProber) Peer() string { return f.peer }

// Probe 实现 Prober。
func (f *FakeProber) Probe(ctx context.Context) Result {
	f.mu.Lock()
	defer f.mu.Unlock()

	if f.fixed != nil {
		r := *f.fixed
		if r.At.IsZero() {
			r.At = time.Now()
		}
		return r
	}
	if len(f.script) == 0 {
		return Result{Path: 0 /*PathDown*/, At: time.Now()}
	}
	i := f.idx
	if i >= len(f.script) {
		i = len(f.script) - 1
	} else {
		f.idx++
	}
	r := f.script[i]
	if r.At.IsZero() {
		r.At = time.Now()
	}
	return r
}
