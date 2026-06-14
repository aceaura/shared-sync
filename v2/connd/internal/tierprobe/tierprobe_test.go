package tierprobe

import (
	"context"
	"testing"
	"time"

	"github.com/aceaura/shared-sync/v2/connd/internal/ladder"
	"github.com/aceaura/shared-sync/v2/connd/internal/nebula"
)

// TestClassifyDirect:心跳通 + hostmap=DIRECT → T0 UP,T1 UP,T2 看后端。
func TestClassifyDirectNoBackend(t *testing.T) {
	tiers := Classify(nebula.PeerDirect, true, 5*time.Millisecond, false, 0)
	if tiers[TierDirect].State != ladder.TierUp {
		t.Fatalf("direct+心跳 应 T0 UP")
	}
	if tiers[TierUDPRelay].State != ladder.TierUp {
		t.Fatalf("direct 时 relay 应作为退路 UP")
	}
	if tiers[TierTCPRelay].State != ladder.TierDown {
		t.Fatalf("无 T2 后端应 DOWN")
	}
	if tiers[TierDirect].RTT != 5*time.Millisecond {
		t.Fatalf("T0 RTT 应取心跳值")
	}
}

// TestClassifyRelay:心跳通 + hostmap=RELAY → T0 DOWN,T1 UP。
func TestClassifyRelay(t *testing.T) {
	tiers := Classify(nebula.PeerRelay, true, 30*time.Millisecond, false, 0)
	if tiers[TierDirect].State != ladder.TierDown {
		t.Fatalf("relay 时 T0 应 DOWN")
	}
	if tiers[TierUDPRelay].State != ladder.TierUp {
		t.Fatalf("relay+心跳 应 T1 UP")
	}
}

// TestClassifyUnknownButReachable:hostmap UNKNOWN(sshd 失败)但心跳通 → 保守 T1 UP,T0 DOWN。
func TestClassifyUnknownButReachable(t *testing.T) {
	tiers := Classify(nebula.PeerUnknown, true, 20*time.Millisecond, false, 0)
	if tiers[TierDirect].State != ladder.TierDown {
		t.Fatalf("UNKNOWN 不应误升 T0")
	}
	if tiers[TierUDPRelay].State != ladder.TierUp {
		t.Fatalf("心跳通时至少 T1 UP")
	}
}

// TestClassifyOverlayUnreachable:心跳不通 → T0/T1 都 DOWN(即使 hostmap 报 direct,
// 因为 hostmap 滞后,心跳是权威兜底)。
func TestClassifyOverlayUnreachable(t *testing.T) {
	tiers := Classify(nebula.PeerDirect, false, 0, false, 0)
	if tiers[TierDirect].State != ladder.TierDown || tiers[TierUDPRelay].State != ladder.TierDown {
		t.Fatalf("心跳不通时 T0/T1 都应 DOWN(hostmap 滞后,心跳权威)")
	}
}

// TestClassifyT2Healthy:T2 后端通 → T2 UP。
func TestClassifyT2Healthy(t *testing.T) {
	tiers := Classify(nebula.PeerUnknown, false, 0, true, 50*time.Millisecond)
	if tiers[TierTCPRelay].State != ladder.TierUp {
		t.Fatalf("T2 后端通应 T2 UP")
	}
	if tiers[TierTCPRelay].RTT != 50*time.Millisecond {
		t.Fatalf("T2 RTT 应取探测值")
	}
}

// TestProbeTiersDirect:NebulaTierProber 用假 fetcher(direct)+ 假心跳(通)→ T0/T1 UP。
func TestProbeTiersDirect(t *testing.T) {
	f := nebula.FetcherFunc(func(ctx context.Context) ([]byte, error) {
		return []byte(`[{"vpnAddrs":["10.77.0.2"],"currentRemote":"1.2.3.4:4242","currentRelaysToMe":[]}]`), nil
	})
	p := NewNebulaTierProber(Options{
		PeerOverlayIP:      "10.77.0.2",
		LighthouseUnderlay: "54.198.93.78:4242",
		Fetcher:            f,
		Heartbeat:          FakeHeartbeat{Reachable: true, RTTVal: 3 * time.Millisecond},
	})
	res := p.ProbeTiers(context.Background())
	h := res.Health()
	if h[TierDirect] != ladder.TierUp || h[TierUDPRelay] != ladder.TierUp {
		t.Fatalf("direct 探测应 T0/T1 UP,实际 %v", h)
	}
	if h[TierTCPRelay] != ladder.TierDown {
		t.Fatalf("无 T2 后端应 DOWN")
	}
	if res.CurrentRemote != "1.2.3.4:4242" {
		t.Fatalf("currentRemote 应被记录,实际 %q", res.CurrentRemote)
	}
	if p.LastCurrentRemote() != "1.2.3.4:4242" {
		t.Fatalf("LastCurrentRemote 不符")
	}
}

// TestProbeTiersHostmapFailsButHeartbeatOK:hostmap 查询失败但心跳通 → 保守 T1 UP。
func TestProbeTiersHostmapFailsButHeartbeatOK(t *testing.T) {
	f := nebula.FetcherFunc(func(ctx context.Context) ([]byte, error) {
		return nil, context.DeadlineExceeded
	})
	p := NewNebulaTierProber(Options{
		PeerOverlayIP: "10.77.0.2",
		Fetcher:       f,
		Heartbeat:     FakeHeartbeat{Reachable: true, RTTVal: 8 * time.Millisecond},
	})
	res := p.ProbeTiers(context.Background())
	h := res.Health()
	if h[TierDirect] != ladder.TierDown {
		t.Fatalf("hostmap 失败不应误升 T0")
	}
	if h[TierUDPRelay] != ladder.TierUp {
		t.Fatalf("心跳通应保守 T1 UP")
	}
}

// TestProbeTiersAllDown:心跳不通 + 无 T2 → 全 DOWN。
func TestProbeTiersAllDown(t *testing.T) {
	p := NewNebulaTierProber(Options{
		PeerOverlayIP: "10.77.0.2",
		Heartbeat:     FakeHeartbeat{Reachable: false},
	})
	res := p.ProbeTiers(context.Background())
	h := res.Health()
	for i, s := range h {
		if s != ladder.TierDown {
			t.Fatalf("全不通时第 %d 层应 DOWN,实际 %v", i, s)
		}
	}
}

// TestProbeTiersWithT2Backend:接入 T2 后端(通)→ T2 UP(Phase3 形态预演)。
func TestProbeTiersWithT2Backend(t *testing.T) {
	p := NewNebulaTierProber(Options{
		PeerOverlayIP: "10.77.0.2",
		Heartbeat:     FakeHeartbeat{Reachable: false},
		T2Probe:       FakeHeartbeat{Reachable: true, RTTVal: 40 * time.Millisecond},
	})
	res := p.ProbeTiers(context.Background())
	if res.Health()[TierTCPRelay] != ladder.TierUp {
		t.Fatalf("T2 后端通应 T2 UP")
	}
}

// blockingHeartbeat 模拟「UDP 被封死时 overlay TCP 拨号一直阻塞到 ctx 超时」的心跳:
// 它不主动返回,直到上层 ctx 取消(探测超时)才报不可达。用来复现「慢探测拖累其它层」。
type blockingHeartbeat struct{}

func (blockingHeartbeat) Beat(ctx context.Context) (bool, time.Duration) {
	<-ctx.Done() // 阻塞到探测超时(模拟挂死的 overlay 拨号)
	return false, 0
}

// TestProbeTiersSlowOverlayDoesNotStarveT2 是 Phase3 回归测试:
// 当 overlay 心跳阻塞到整个探测超时(UDP 封死),T2 后端探测仍须被正确判为 UP——
// 即各层并发探测,慢的 overlay 不能吃光预算把健康的 T2 误判成 DOWN。
// (该 bug 曾导致 connd 在 UDP 封死时进 RECONNECTING 而非降级到 T2。)
func TestProbeTiersSlowOverlayDoesNotStarveT2(t *testing.T) {
	p := NewNebulaTierProber(Options{
		PeerOverlayIP: "10.77.0.2",
		Heartbeat:     blockingHeartbeat{}, // overlay 拨号挂死
		T2Probe:       FakeHeartbeat{Reachable: true, RTTVal: 30 * time.Millisecond},
	})
	// 模拟 controller 注入的探测超时(probeTimeout)。
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()

	start := time.Now()
	res := p.ProbeTiers(ctx)
	elapsed := time.Since(start)

	h := res.Health()
	if h[TierDirect] != ladder.TierDown || h[TierUDPRelay] != ladder.TierDown {
		t.Fatalf("overlay 挂死时 T0/T1 应 DOWN,实际 %v", h)
	}
	if h[TierTCPRelay] != ladder.TierUp {
		t.Fatalf("overlay 挂死不应饿死 T2 探测:T2 应仍判 UP,实际 %v", h)
	}
	// 并发探测下,总耗时由最慢的 overlay(到超时)决定,而非两者相加;
	// 若退化成串行且 T2 在 overlay 之后,这里仍会 UP,但 elapsed 会明显更长。
	// 主要断言是上面的 T2=UP;此处给个宽松上界防止意外退化。
	if elapsed > 1*time.Second {
		t.Fatalf("探测耗时异常(%v),疑似串行化退化", elapsed)
	}
}

// TestFakeTierProberScript:脚本探测器按序返回。
func TestFakeTierProberScript(t *testing.T) {
	fp := NewScriptedTierProber("10.77.0.2",
		[]ladder.TierState{ladder.TierDown, ladder.TierDown, ladder.TierUp},
		[]ladder.TierState{ladder.TierUp, ladder.TierUp, ladder.TierUp},
	)
	r1 := fp.ProbeTiers(context.Background())
	if r1.Health()[TierDirect] != ladder.TierDown {
		t.Fatalf("第一拍 T0 应 DOWN")
	}
	r2 := fp.ProbeTiers(context.Background())
	if r2.Health()[TierDirect] != ladder.TierUp {
		t.Fatalf("第二拍 T0 应 UP")
	}
	// 耗尽后重复最后一个。
	r3 := fp.ProbeTiers(context.Background())
	if r3.Health()[TierDirect] != ladder.TierUp {
		t.Fatalf("耗尽后应重复最后一个")
	}
}

// TestTierName:层名稳定。
func TestTierName(t *testing.T) {
	if TierName(0) != "T0" || TierName(1) != "T1" || TierName(2) != "T2" {
		t.Fatalf("TierName 不符")
	}
}
