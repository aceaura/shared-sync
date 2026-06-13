package fsm

import (
	"testing"
	"time"
)

// testCfg 给测试用一组小而清晰的参数,便于推算时刻。
//
//	T_up = 20s(升级滞后窗口)
//	N    = 3 (降级阈值)
//	P    = 30s(打洞重试周期)
//	hb   = 5s (心跳间隔)
func testCfg() Config {
	return Config{
		TUp:       20 * time.Second,
		N:         3,
		P:         30 * time.Second,
		Heartbeat: 5 * time.Second,
	}
}

func directProbe() Probe { return Probe{DirectPath: PathDirect, RelayUp: true, RTT: 10 * time.Millisecond} }
func relayProbe() Probe  { return Probe{DirectPath: PathRelay, RelayUp: true, RTT: 40 * time.Millisecond} }
func downProbe() Probe   { return Probe{DirectPath: PathDown, RelayUp: true} }

// step 在 base + offset 处喂一个探测,返回 transition。
func step(m *Machine, base time.Time, offset time.Duration, p Probe) Transition {
	return m.Tick(base.Add(offset), p)
}

// TestInitialStateIsFallback:启动即兜底(DESIGN_v2.md §2.2)。
func TestInitialStateIsFallback(t *testing.T) {
	t0 := time.Unix(1_000_000, 0)
	m := New(testCfg(), t0)
	if m.State() != Fallback {
		t.Fatalf("初始状态应为 FALLBACK,实际 %v", m.State())
	}
}

// TestUpgradeRequiresStableTUp:直连健康必须**连续稳定满 T_up** 才升级到 DIRECT。
func TestUpgradeRequiresStableTUp(t *testing.T) {
	t0 := time.Unix(1_000_000, 0)
	cfg := testCfg()
	m := New(cfg, t0)

	// 心跳间隔 5s 喂直连健康。前几拍(< T_up=20s)不应升级。
	for off := 5 * time.Second; off < cfg.TUp; off += cfg.Heartbeat {
		tr := step(m, t0, off, directProbe())
		if tr.Switched {
			t.Fatalf("在 %v 处过早升级(< T_up=%v)", off, cfg.TUp)
		}
		if m.State() != Fallback {
			t.Fatalf("在 %v 处状态应仍为 FALLBACK", off)
		}
	}

	// 连续健康首拍在 t0+5s;到 t0+25s 时已连续健康 20s == T_up,应升级。
	tr := step(m, t0, 25*time.Second, directProbe())
	if !tr.Switched || tr.To != Direct {
		t.Fatalf("连续健康满 T_up 后应升级到 DIRECT,得到 %+v(state=%v)", tr, m.State())
	}
}

// TestUpgradeBoundary:恰好满 T_up 的边界(>=,非 >)。
func TestUpgradeBoundary(t *testing.T) {
	t0 := time.Unix(1_000_000, 0)
	cfg := testCfg()
	m := New(cfg, t0)

	// 健康段起点 t0+0;在 t0 + T_up 恰好满足 >= T_up。
	step(m, t0, 0, directProbe()) // healthySince = t0
	tr := step(m, t0, cfg.TUp, directProbe())
	if !tr.Switched || tr.To != Direct {
		t.Fatalf("恰好满 T_up(边界 >=)应升级,得到 %+v", tr)
	}
}

// TestDowngradeAfterNFailures:DIRECT 下直连连续失败 N 次立即降级 FALLBACK。
func TestDowngradeAfterNFailures(t *testing.T) {
	t0 := time.Unix(1_000_000, 0)
	cfg := testCfg()
	m := New(cfg, t0)

	// 先升级到 DIRECT。
	step(m, t0, 0, directProbe())
	step(m, t0, cfg.TUp, directProbe())
	if m.State() != Direct {
		t.Fatalf("前置:应已在 DIRECT,实际 %v", m.State())
	}

	base := t0.Add(cfg.TUp)
	// 失败 N-1 次:不应降级。
	for i := 1; i < cfg.N; i++ {
		tr := step(m, base, time.Duration(i)*cfg.Heartbeat, downProbe())
		if tr.Switched {
			t.Fatalf("第 %d 次失败就降级了(阈值 N=%d)", i, cfg.N)
		}
		if m.State() != Direct {
			t.Fatalf("第 %d 次失败后应仍为 DIRECT", i)
		}
	}
	// 第 N 次失败:降级。
	tr := step(m, base, time.Duration(cfg.N)*cfg.Heartbeat, downProbe())
	if !tr.Switched || tr.To != Fallback {
		t.Fatalf("第 N=%d 次失败应降级到 FALLBACK,得到 %+v(state=%v)", cfg.N, tr, m.State())
	}
}

// TestFailStreakResetsOnHealthy:DIRECT 下偶发失败被健康打断,计数清零,不降级。
func TestFailStreakResetsOnHealthy(t *testing.T) {
	t0 := time.Unix(1_000_000, 0)
	cfg := testCfg()
	m := New(cfg, t0)
	step(m, t0, 0, directProbe())
	step(m, t0, cfg.TUp, directProbe())
	if m.State() != Direct {
		t.Fatalf("前置应在 DIRECT")
	}

	base := t0.Add(cfg.TUp)
	off := cfg.Heartbeat
	// 失败 N-1 次。
	for i := 0; i < cfg.N-1; i++ {
		step(m, base, off, downProbe())
		off += cfg.Heartbeat
	}
	// 一次健康打断:计数清零。
	step(m, base, off, directProbe())
	off += cfg.Heartbeat
	if m.State() != Direct {
		t.Fatalf("健康打断后应仍为 DIRECT")
	}
	if s := m.Snapshot(); s.FailStreak != 0 {
		t.Fatalf("健康后失败计数应清零,实际 %d", s.FailStreak)
	}
	// 再失败 N-1 次仍不够降级(因为已清零)。
	for i := 0; i < cfg.N-1; i++ {
		tr := step(m, base, off, downProbe())
		off += cfg.Heartbeat
		if tr.Switched {
			t.Fatalf("清零后第 %d 次失败不应降级", i+1)
		}
	}
}

// TestPunchRetryEveryP:FALLBACK 期间每 P 秒触发一次打洞重试,首拍立即重试。
func TestPunchRetryEveryP(t *testing.T) {
	t0 := time.Unix(1_000_000, 0)
	cfg := testCfg()
	m := New(cfg, t0)

	// 第一拍(FALLBACK 进入后的首次 Tick)应立即重试。
	tr := step(m, t0, 0, relayProbe())
	if !tr.ShouldRetryPunch {
		t.Fatalf("FALLBACK 首拍应触发打洞重试")
	}

	// 紧接着的几拍(< P=30s)不应再触发。
	for off := cfg.Heartbeat; off < cfg.P; off += cfg.Heartbeat {
		tr := step(m, t0, off, relayProbe())
		if tr.ShouldRetryPunch {
			t.Fatalf("在 %v 处不应重试(< P=%v,距上次未到周期)", off, cfg.P)
		}
	}

	// 到 t0+P 时(距上次 t0 已满 P)应再次触发。
	tr = step(m, t0, cfg.P, relayProbe())
	if !tr.ShouldRetryPunch {
		t.Fatalf("距上次重试满 P 应再次触发,得到 %+v", tr)
	}
}

// TestNoPunchRetryInDirect:DIRECT 状态不触发打洞重试(已直连,无需打洞)。
func TestNoPunchRetryInDirect(t *testing.T) {
	t0 := time.Unix(1_000_000, 0)
	cfg := testCfg()
	m := New(cfg, t0)
	step(m, t0, 0, directProbe())
	step(m, t0, cfg.TUp, directProbe())
	if m.State() != Direct {
		t.Fatalf("前置应在 DIRECT")
	}
	// 远超 P 的时间跨度,DIRECT 下都不应有重试请求。
	tr := step(m, t0, cfg.TUp+10*cfg.P, directProbe())
	if tr.ShouldRetryPunch {
		t.Fatalf("DIRECT 状态不应触发打洞重试")
	}
}

// TestRoundTripRecovery:DIRECT→失败降级→FALLBACK 期间按 P 重试→恢复并稳定→切回 DIRECT。
func TestRoundTripRecovery(t *testing.T) {
	t0 := time.Unix(1_000_000, 0)
	cfg := testCfg()
	m := New(cfg, t0)

	// 1) 升级到 DIRECT。
	step(m, t0, 0, directProbe())
	step(m, t0, cfg.TUp, directProbe())
	if m.State() != Direct {
		t.Fatalf("阶段1:应在 DIRECT")
	}

	// 2) 连续失败 N 次降级。
	base := t0.Add(cfg.TUp)
	off := cfg.Heartbeat
	var downAt time.Time
	for i := 0; i < cfg.N; i++ {
		tr := step(m, base, off, downProbe())
		if i == cfg.N-1 {
			if !tr.Switched || tr.To != Fallback {
				t.Fatalf("阶段2:第 N 次应降级 FALLBACK")
			}
			downAt = base.Add(off)
		}
		off += cfg.Heartbeat
	}

	// 3) FALLBACK 刚进入,下一拍应立即重试打洞(降级时 punchRetried 被重置)。
	tr := step(m, downAt, cfg.Heartbeat, relayProbe())
	if !tr.ShouldRetryPunch {
		t.Fatalf("阶段3:降级后首拍应触发打洞重试,得到 %+v", tr)
	}

	// 4) 直连恢复且连续稳定满 T_up 后切回 DIRECT。
	recoverBase := downAt.Add(cfg.Heartbeat * 2)
	step(m, recoverBase, 0, directProbe()) // healthySince = recoverBase
	tr = step(m, recoverBase, cfg.TUp, directProbe())
	if !tr.Switched || tr.To != Direct {
		t.Fatalf("阶段4:恢复并稳定满 T_up 应切回 DIRECT,得到 %+v(state=%v)", tr, m.State())
	}
}

// TestFlappingDoesNotSwitch:抖动(健康/不健康交替)期间,滞后窗口反复归零,
// 永不升级,验证防抖。
func TestFlappingDoesNotSwitch(t *testing.T) {
	t0 := time.Unix(1_000_000, 0)
	cfg := testCfg()
	m := New(cfg, t0)

	// 抖动:每拍都健康一次然后不健康一次,交替很久(远超 T_up)。
	off := time.Duration(0)
	switches := 0
	for i := 0; i < 200; i++ { // 200 * 5s = 1000s,远超 T_up=20s
		p := directProbe()
		if i%2 == 1 {
			p = relayProbe() // 每隔一拍打断连续健康段
		}
		tr := step(m, t0, off, p)
		if tr.Switched {
			switches++
		}
		off += cfg.Heartbeat
	}
	if switches != 0 {
		t.Fatalf("抖动期间不应发生任何升级切换,实际切换 %d 次", switches)
	}
	if m.State() != Fallback {
		t.Fatalf("抖动期间应始终停留 FALLBACK,实际 %v", m.State())
	}
}

// TestFlappingNearThresholdDowngrade:DIRECT 下失败接近阈值但被健康打断,不应频繁降级。
func TestFlappingNearThresholdDowngrade(t *testing.T) {
	t0 := time.Unix(1_000_000, 0)
	cfg := testCfg() // N=3
	m := New(cfg, t0)
	step(m, t0, 0, directProbe())
	step(m, t0, cfg.TUp, directProbe())
	if m.State() != Direct {
		t.Fatalf("前置应在 DIRECT")
	}

	base := t0.Add(cfg.TUp)
	off := cfg.Heartbeat
	switches := 0
	// 模式:fail, fail, healthy, fail, fail, healthy ... 永远凑不满连续 3 次失败。
	pattern := []bool{false, false, true} // false=down, true=direct
	for i := 0; i < 90; i++ {
		var p Probe
		if pattern[i%3] {
			p = directProbe()
		} else {
			p = downProbe()
		}
		tr := step(m, base, off, p)
		if tr.Switched {
			switches++
		}
		off += cfg.Heartbeat
	}
	if switches != 0 {
		t.Fatalf("失败被周期性健康打断时不应降级,实际切换 %d 次(state=%v)", switches, m.State())
	}
}

// TestConfigValidateFallsBack:非法配置回退到默认。
func TestConfigValidateFallsBack(t *testing.T) {
	c := Config{TUp: -1, N: 0, P: 0, Heartbeat: -5}
	fixed := c.Validate()
	if !fixed {
		t.Fatalf("非法配置应被标记为已回退")
	}
	d := DefaultConfig()
	if c.TUp != d.TUp || c.N != d.N || c.P != d.P || c.Heartbeat != d.Heartbeat {
		t.Fatalf("非法字段应回退到默认,实际 %+v", c)
	}
}

// TestStateString:字符串表示稳定(被 HTTP/CLI 依赖)。
func TestStateString(t *testing.T) {
	if Fallback.String() != "FALLBACK" || Direct.String() != "DIRECT" {
		t.Fatalf("State.String 不符: %v %v", Fallback, Direct)
	}
	if PathDirect.String() != "DIRECT" || PathRelay.String() != "RELAY" || PathDown.String() != "DOWN" {
		t.Fatalf("Path.String 不符")
	}
}
