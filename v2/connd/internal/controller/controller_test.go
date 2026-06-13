package controller

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/aceaura/shared-sync/v2/connd/internal/fsm"
	"github.com/aceaura/shared-sync/v2/connd/internal/nebula"
	"github.com/aceaura/shared-sync/v2/connd/internal/prober"
)

// fakeClock 提供可控时钟。
type fakeClock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *fakeClock) now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}
func (c *fakeClock) advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.t = c.t.Add(d)
}

// TestControllerStatusReflectsProbe:tickOnce 后状态快照反映探测结果与状态机状态。
func TestControllerStatusReflectsProbe(t *testing.T) {
	clk := &fakeClock{t: time.Unix(2_000_000, 0)}
	cfg := fsm.Config{TUp: 20 * time.Second, N: 3, P: 30 * time.Second, Heartbeat: 5 * time.Second}

	p := prober.NewFixedProber("10.77.0.3", prober.Result{
		Path: fsm.PathRelay, RTT: 42 * time.Millisecond, RelayUp: true,
	})
	neb := nebula.NewManager(nebula.Options{DryRun: true})
	_ = neb.Start(context.Background())

	ctrl := New(cfg, p, neb, time.Second, clk.now)
	ctrl.tickOnce(context.Background())

	st := ctrl.Status()
	if st.Path != "RELAY" {
		t.Fatalf("path 应为 RELAY,实际 %q", st.Path)
	}
	if st.State != "FALLBACK" {
		t.Fatalf("初始状态应为 FALLBACK,实际 %q", st.State)
	}
	if st.Peer != "10.77.0.3" {
		t.Fatalf("peer 应为 10.77.0.3,实际 %q", st.Peer)
	}
	if st.RTTMs != 42 {
		t.Fatalf("rttMs 应为 42,实际 %v", st.RTTMs)
	}
	if st.Nebula != "RUNNING" {
		t.Fatalf("nebula 应为 RUNNING,实际 %q", st.Nebula)
	}
}

// TestControllerUpgradesThroughTicks:连续喂直连健康,经过 T_up 后状态升级到 DIRECT。
func TestControllerUpgradesThroughTicks(t *testing.T) {
	clk := &fakeClock{t: time.Unix(2_000_000, 0)}
	cfg := fsm.Config{TUp: 20 * time.Second, N: 3, P: 30 * time.Second, Heartbeat: 5 * time.Second}

	p := prober.NewFixedProber("10.77.0.3", prober.Result{
		Path: fsm.PathDirect, RTT: 8 * time.Millisecond, RelayUp: true,
	})
	ctrl := New(cfg, p, nil, time.Second, clk.now)

	// 每 5s 一拍,健康。第一拍建立 healthySince,满 20s 后升级。
	for i := 0; i < 6; i++ {
		ctrl.tickOnce(context.Background())
		clk.advance(5 * time.Second)
	}
	st := ctrl.Status()
	if st.State != "DIRECT" {
		t.Fatalf("连续健康越过 T_up 后应为 DIRECT,实际 %q", st.State)
	}
	if st.Path != "DIRECT" {
		t.Fatalf("path 应为 DIRECT,实际 %q", st.Path)
	}
	if st.Nebula != "DISABLED" {
		t.Fatalf("无 nebula 时应为 DISABLED,实际 %q", st.Nebula)
	}
}

// TestControllerRunStops:Run 在 ctx 取消后退出,且 nebula 被停止。
func TestControllerRunStops(t *testing.T) {
	cfg := fsm.Config{TUp: 20 * time.Second, N: 3, P: 30 * time.Second, Heartbeat: 10 * time.Millisecond}
	p := prober.NewFixedProber("10.77.0.3", prober.Result{Path: fsm.PathRelay, RelayUp: true})
	neb := nebula.NewManager(nebula.Options{DryRun: true})
	ctrl := New(cfg, p, neb, 5*time.Millisecond, nil)

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Millisecond)
	defer cancel()
	err := ctrl.Run(ctx)
	if err != context.DeadlineExceeded && err != context.Canceled {
		t.Fatalf("Run 应因 ctx 结束返回,实际 %v", err)
	}
	if s, _, _ := neb.Status(); s != nebula.StatusStopped {
		t.Fatalf("Run 退出后 nebula 应已停止,实际 %v", s)
	}
}
