package controller

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/aceaura/shared-sync/v2/connd/internal/ladder"
	"github.com/aceaura/shared-sync/v2/connd/internal/nebula"
	"github.com/aceaura/shared-sync/v2/connd/internal/proxy"
	"github.com/aceaura/shared-sync/v2/connd/internal/tierprobe"
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

func testCfg() ladder.Config {
	return ladder.Config{NumTiers: 3, TUp: 20 * time.Second, N: 3, P: 30 * time.Second, Heartbeat: 5 * time.Second}
}

// upstreamMap 把层映射到固定后端地址(测试用)。
func upstreamMap(tier int) string {
	switch tier {
	case tierprobe.TierDirect, tierprobe.TierUDPRelay:
		return "10.77.0.2:8418"
	case tierprobe.TierTCPRelay:
		return "127.0.0.1:9999"
	}
	return ""
}

// TestControllerStatusReflectsProbe:tickOnce 后快照反映探测结果与状态机。
func TestControllerStatusReflectsProbe(t *testing.T) {
	clk := &fakeClock{t: time.Unix(2_000_000, 0)}
	// T0 DOWN,T1 UP,T2 UP —— 起步在 T2,保持在 T2,验证基础字段。
	p := tierprobe.NewFixedTierProber("10.77.0.2", ladder.TierDown, ladder.TierUp, ladder.TierUp)
	neb := nebula.NewManager(nebula.Options{DryRun: true})
	_ = neb.Start(context.Background())

	ctrl := New(Options{
		Cfg: testCfg(), Prober: p, Nebula: neb, UpstreamOf: upstreamMap,
		ProbeTimeout: time.Second, LocalEndpoint: "127.0.0.1:8418", Now: clk.now,
	})
	ctrl.tickOnce(context.Background())

	st := ctrl.Status()
	if st.Tier != "T2" {
		t.Fatalf("起步应在 T2,实际 %q", st.Tier)
	}
	if !st.ViaVps {
		t.Fatalf("T2 应 viaVps=true")
	}
	if st.Peer != "10.77.0.2" {
		t.Fatalf("peer 不符: %q", st.Peer)
	}
	if st.Nebula != "RUNNING" {
		t.Fatalf("nebula 应 RUNNING,实际 %q", st.Nebula)
	}
	if st.TiersHealth["T1"] != "UP" || st.TiersHealth["T0"] != "DOWN" {
		t.Fatalf("tiersHealth 不符: %v", st.TiersHealth)
	}
	if st.LocalEndpoint != "127.0.0.1:8418" {
		t.Fatalf("localEndpoint 不符: %q", st.LocalEndpoint)
	}
}

// TestControllerUpgradesToT0:连续喂 T0 健康,经 T_up 后升到 T0,viaVps 变 false。
func TestControllerUpgradesToT0(t *testing.T) {
	clk := &fakeClock{t: time.Unix(2_000_000, 0)}
	p := tierprobe.NewFixedTierProber("10.77.0.2", ladder.TierUp, ladder.TierUp, ladder.TierUp)
	prx := proxy.New("127.0.0.1:0", time.Second)
	ctrl := New(Options{
		Cfg: testCfg(), Prober: p, Proxy: prx, UpstreamOf: upstreamMap,
		ProbeTimeout: time.Second, LocalEndpoint: "127.0.0.1:8418", Now: clk.now,
	})

	for i := 0; i < 6; i++ {
		ctrl.tickOnce(context.Background())
		clk.advance(5 * time.Second)
	}
	st := ctrl.Status()
	if st.Tier != "T0" {
		t.Fatalf("连续健康越过 T_up 应升到 T0,实际 %q", st.Tier)
	}
	if st.ViaVps {
		t.Fatalf("T0 应 viaVps=false")
	}
	// 代理上游应是 T0/T1 的数据中心后端。
	if prx.Upstream() != "10.77.0.2:8418" {
		t.Fatalf("代理上游应为数据中心后端,实际 %q", prx.Upstream())
	}
}

// TestControllerProxyUpstreamFollowsTier:起步层的后端在构造时即写入代理上游。
func TestControllerProxyUpstreamFollowsTier(t *testing.T) {
	clk := &fakeClock{t: time.Unix(2_000_000, 0)}
	p := tierprobe.NewScriptedTierProber("10.77.0.2",
		[]ladder.TierState{ladder.TierDown, ladder.TierDown, ladder.TierUp},
	)
	prx := proxy.New("127.0.0.1:0", time.Second)
	ctrl := New(Options{
		Cfg: testCfg(), Prober: p, Proxy: prx, UpstreamOf: upstreamMap,
		ProbeTimeout: time.Second, Now: clk.now,
	})
	if prx.Upstream() != "127.0.0.1:9999" {
		t.Fatalf("起步代理上游应为 T2 后端,实际 %q", prx.Upstream())
	}
	ctrl.tickOnce(context.Background())
	if ctrl.Status().Tier != "T2" {
		t.Fatalf("应在 T2")
	}
}

// TestControllerReconnecting:全挂 N 次后进入重连态,代理上游清空。
func TestControllerReconnecting(t *testing.T) {
	clk := &fakeClock{t: time.Unix(2_000_000, 0)}
	p := tierprobe.NewFixedTierProber("10.77.0.2", ladder.TierDown, ladder.TierDown, ladder.TierDown)
	prx := proxy.New("127.0.0.1:0", time.Second)
	ctrl := New(Options{
		Cfg: testCfg(), Prober: p, Proxy: prx, UpstreamOf: upstreamMap,
		ProbeTimeout: time.Second, Now: clk.now,
	})
	for i := 0; i < 4; i++ { // N=3,4 拍足够触发降级到重连
		ctrl.tickOnce(context.Background())
		clk.advance(5 * time.Second)
	}
	st := ctrl.Status()
	if !st.Reconnecting || st.Tier != "RECONNECTING" {
		t.Fatalf("全挂应进入重连态,实际 tier=%q reconn=%v", st.Tier, st.Reconnecting)
	}
	if prx.Upstream() != "" {
		t.Fatalf("重连态代理上游应清空,实际 %q", prx.Upstream())
	}
}

// TestControllerRunStops:Run 在 ctx 取消后退出,nebula 被停止。
func TestControllerRunStops(t *testing.T) {
	p := tierprobe.NewFixedTierProber("10.77.0.2", ladder.TierDown, ladder.TierUp, ladder.TierUp)
	neb := nebula.NewManager(nebula.Options{DryRun: true})
	prx := proxy.New("127.0.0.1:0", time.Second)
	cfg := ladder.Config{NumTiers: 3, TUp: 20 * time.Second, N: 3, P: 30 * time.Second, Heartbeat: 10 * time.Millisecond}
	ctrl := New(Options{Cfg: cfg, Prober: p, Proxy: prx, Nebula: neb, UpstreamOf: upstreamMap, ProbeTimeout: 5 * time.Millisecond})

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
