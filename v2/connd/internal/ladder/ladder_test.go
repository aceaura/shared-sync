package ladder

import (
	"testing"
	"time"
)

// cfg3 给三层阶梯一组小而清晰的参数,便于推算时刻。
//
//	NumTiers = 3 (T0/T1/T2)
//	T_up = 20s(升级滞后)
//	N    = 3 (降级阈值)
//	P    = 30s(上层重试周期)
//	hb   = 5s
func cfg3() Config {
	return Config{NumTiers: 3, TUp: 20 * time.Second, N: 3, P: 30 * time.Second, Heartbeat: 5 * time.Second}
}

// 健康向量构造助手:up(0,1) => [DOWN... 指定层 UP]
func vec(states ...TierState) []TierState { return states }

const U = TierUp
const D = TierDown

func step(m *Machine, base time.Time, off time.Duration, h []TierState) Transition {
	return m.Tick(base.Add(off), h)
}

// ------------------------------------------------------------------ 基础

// TestInitialActiveIsLowestTier:启动落在最低优先层(终极兜底,DESIGN_v2 §2.2)。
func TestInitialActiveIsLowestTier(t *testing.T) {
	t0 := time.Unix(1_000_000, 0)
	m := New(cfg3(), t0)
	if m.Active() != 2 {
		t.Fatalf("初始激活层应为最低优先层 T2(索引 2),实际 %d", m.Active())
	}
}

// TestSelectionPicksHighestHealthy:从重连/兜底态出发,一旦多层健康,
// 立即抢救到最高优先健康层(先连上),其上更优层走升级滞后。
func TestRescueToHighestHealthyFromReconnecting(t *testing.T) {
	t0 := time.Unix(1_000_000, 0)
	c := cfg3()
	m := New(c, t0)

	// 先让全部层 DOWN 连续 N 次(active 在 T2,T2 也挂)→ 进入 RECONNECTING。
	var tr Transition
	for i := 1; i <= c.N; i++ {
		tr = step(m, t0, time.Duration(i)*c.Heartbeat, vec(D, D, D))
	}
	if !tr.Reconnecting || m.Active() != NoTier {
		t.Fatalf("全挂失败 N 次应进入 RECONNECTING,实际 active=%d reconn=%v", m.Active(), tr.Reconnecting)
	}
	// 现在 T1 健康(T0 仍挂):应立即抢救到 T1(不等 T_up,兜底优先)。
	tr = step(m, t0, time.Duration(c.N+1)*c.Heartbeat, vec(D, U, D))
	if !tr.Switched || m.Active() != 1 {
		t.Fatalf("有健康层应立即抢救到最高优先健康层 T1,实际 active=%d", m.Active())
	}
}

// ------------------------------------------------------------------ 升级滞后

// TestUpgradeRequiresStableTUp:T2→T0 升级需 T0 连续健康满 T_up。
func TestUpgradeRequiresStableTUp(t *testing.T) {
	t0 := time.Unix(1_000_000, 0)
	c := cfg3()
	m := New(c, t0)

	// T0 一直健康(T1/T2 也健康,但只关心能否升到最优 T0)。
	for off := time.Duration(0); off < c.TUp; off += c.Heartbeat {
		tr := step(m, t0, off, vec(U, U, U))
		if tr.To == 0 && tr.Switched {
			t.Fatalf("在 %v 处过早升级到 T0(< T_up=%v)", off, c.TUp)
		}
	}
	// 连续健康首拍在 off=0;到 off=T_up(20s)时满 T_up,应升到 T0。
	tr := step(m, t0, c.TUp, vec(U, U, U))
	if !tr.Switched || tr.To != 0 {
		t.Fatalf("T0 连续健康满 T_up 应升级到 T0,得到 %+v(active=%d)", tr, m.Active())
	}
}

// TestUpgradeBoundaryGEQ:恰好满 T_up 的边界(>=,非 >)。
func TestUpgradeBoundaryGEQ(t *testing.T) {
	t0 := time.Unix(1_000_000, 0)
	c := cfg3()
	m := New(c, t0)
	step(m, t0, 0, vec(U, U, U)) // T0 healthySince = t0
	tr := step(m, t0, c.TUp, vec(U, U, U))
	if !tr.Switched || tr.To != 0 {
		t.Fatalf("恰好满 T_up(边界 >=)应升级到 T0,得到 %+v", tr)
	}
}

// TestStepwiseUpgrade:从 T2 起,先升到能稳定的 T1,再升到 T0(逐级)。
func TestStepwiseUpgradeT2toT1toT0(t *testing.T) {
	t0 := time.Unix(1_000_000, 0)
	c := cfg3()
	m := New(c, t0)

	// 阶段A:只有 T1 健康(T0 挂),稳定满 T_up → 升到 T1。
	for off := time.Duration(0); off <= c.TUp; off += c.Heartbeat {
		step(m, t0, off, vec(D, U, U))
	}
	if m.Active() != 1 {
		t.Fatalf("阶段A:T1 稳定满 T_up 应升到 T1,实际 %d", m.Active())
	}
	// 阶段B:T0 现在也健康,稳定满 T_up → 升到 T0。
	base := t0.Add(c.TUp + c.Heartbeat)
	step(m, base, 0, vec(U, U, U)) // T0 healthySince = base
	tr := step(m, base, c.TUp, vec(U, U, U))
	if !tr.Switched || tr.To != 0 {
		t.Fatalf("阶段B:T0 稳定满 T_up 应升到 T0,得到 %+v(active=%d)", tr, m.Active())
	}
}

// TestUpgradeChoosesHighestEligible:T0 与 T1 都已稳定满 T_up 时,升级跳到最优 T0。
func TestUpgradeChoosesHighestEligible(t *testing.T) {
	t0 := time.Unix(1_000_000, 0)
	c := cfg3()
	m := New(c, t0)
	// T0 与 T1 同时持续健康,满 T_up 后应直接落到 T0(而非 T1)。
	step(m, t0, 0, vec(U, U, U))
	tr := step(m, t0, c.TUp, vec(U, U, U))
	if !tr.Switched || tr.To != 0 {
		t.Fatalf("T0/T1 都满足时应升到最优 T0,得到 %+v", tr)
	}
}

// ------------------------------------------------------------------ 降级

// TestDowngradeAfterNFailuresFallsToHealthyBelow:T0 连续失败 N 次,落到下方健康的 T1。
func TestDowngradeAfterNFailuresFallsToHealthyBelow(t *testing.T) {
	t0 := time.Unix(1_000_000, 0)
	c := cfg3()
	m := New(c, t0)
	// 升到 T0。
	step(m, t0, 0, vec(U, U, U))
	step(m, t0, c.TUp, vec(U, U, U))
	if m.Active() != 0 {
		t.Fatalf("前置:应在 T0,实际 %d", m.Active())
	}

	base := t0.Add(c.TUp)
	// T0 失败,但 T1 仍健康。失败 N-1 次不降级。
	for i := 1; i < c.N; i++ {
		tr := step(m, base, time.Duration(i)*c.Heartbeat, vec(D, U, U))
		if tr.Switched {
			t.Fatalf("第 %d 次失败不应降级(阈值 N=%d)", i, c.N)
		}
	}
	// 第 N 次:降级到下方最高优先健康层 T1。
	tr := step(m, base, time.Duration(c.N)*c.Heartbeat, vec(D, U, U))
	if !tr.Switched || tr.To != 1 {
		t.Fatalf("T0 失败 N 次应降级到下方健康的 T1,得到 %+v(active=%d)", tr, m.Active())
	}
}

// TestDowngradeSkipsUnhealthyTierToLower:T0 失败、T1 也挂、T2 健康 → 直接落到 T2。
func TestDowngradeSkipsUnhealthyTierToLower(t *testing.T) {
	t0 := time.Unix(1_000_000, 0)
	c := cfg3()
	m := New(c, t0)
	step(m, t0, 0, vec(U, U, U))
	step(m, t0, c.TUp, vec(U, U, U))
	if m.Active() != 0 {
		t.Fatalf("前置应在 T0")
	}
	base := t0.Add(c.TUp)
	// T0、T1 都挂,只有 T2 健康。失败 N 次后应跳过 T1 直接落 T2。
	for i := 1; i <= c.N; i++ {
		step(m, base, time.Duration(i)*c.Heartbeat, vec(D, D, U))
	}
	if m.Active() != 2 {
		t.Fatalf("T1 不健康应跳过,降到 T2,实际 active=%d", m.Active())
	}
}

// TestFailStreakResetsOnHealthy:偶发失败被健康打断,计数清零,不降级。
func TestFailStreakResetsOnHealthy(t *testing.T) {
	t0 := time.Unix(1_000_000, 0)
	c := cfg3()
	m := New(c, t0)
	step(m, t0, 0, vec(U, U, U))
	step(m, t0, c.TUp, vec(U, U, U))
	if m.Active() != 0 {
		t.Fatalf("前置应在 T0")
	}
	base := t0.Add(c.TUp)
	off := c.Heartbeat
	for i := 0; i < c.N-1; i++ { // 失败 N-1 次
		step(m, base, off, vec(D, U, U))
		off += c.Heartbeat
	}
	step(m, base, off, vec(U, U, U)) // 一次健康打断
	off += c.Heartbeat
	if m.Active() != 0 {
		t.Fatalf("健康打断后应仍在 T0,实际 %d", m.Active())
	}
	if s := m.Snapshot(); s.FailStreak != 0 {
		t.Fatalf("健康后失败计数应清零,实际 %d", s.FailStreak)
	}
}

// ------------------------------------------------------------------ 全挂 / 重连

// TestAllDownEntersReconnecting:所有层都挂 → RECONNECTING(active=NoTier)。
func TestAllDownEntersReconnecting(t *testing.T) {
	t0 := time.Unix(1_000_000, 0)
	c := cfg3()
	m := New(c, t0)
	// 当前在 T2,连续失败 N 次且无任何健康层 → 重连。
	base := t0
	for i := 1; i <= c.N; i++ {
		step(m, base, time.Duration(i)*c.Heartbeat, vec(D, D, D))
	}
	if m.Active() != NoTier {
		t.Fatalf("全挂失败 N 次应进入 RECONNECTING,实际 active=%d", m.Active())
	}
	s := m.Snapshot()
	if !s.Reconnecting {
		t.Fatalf("快照应标记 Reconnecting")
	}
}

// TestRecoverFromReconnecting:重连态下任一层恢复,立即抢救到最高优先健康层。
func TestRecoverFromReconnecting(t *testing.T) {
	t0 := time.Unix(1_000_000, 0)
	c := cfg3()
	m := New(c, t0)
	base := t0
	for i := 1; i <= c.N; i++ {
		step(m, base, time.Duration(i)*c.Heartbeat, vec(D, D, D))
	}
	if m.Active() != NoTier {
		t.Fatalf("前置应在 RECONNECTING")
	}
	// T2 恢复:立即抢救到 T2。
	tr := step(m, base, time.Duration(c.N+1)*c.Heartbeat, vec(D, D, U))
	if !tr.Switched || m.Active() != 2 {
		t.Fatalf("重连恢复应抢救到 T2,得到 %+v(active=%d)", tr, m.Active())
	}
}

// ------------------------------------------------------------------ 上层重试节拍

// TestRetryEveryP:非最优层时每 P 触发一次上层重试,首拍立即重试。
func TestRetryEveryP(t *testing.T) {
	t0 := time.Unix(1_000_000, 0)
	c := cfg3()
	m := New(c, t0)
	// 在 T2(active=2),T0/T1 不健康。
	tr := step(m, t0, 0, vec(D, D, U))
	if !tr.RetryProbe {
		t.Fatalf("非最优层首拍应触发上层重试")
	}
	for off := c.Heartbeat; off < c.P; off += c.Heartbeat {
		tr := step(m, t0, off, vec(D, D, U))
		if tr.RetryProbe {
			t.Fatalf("在 %v 处不应重试(< P=%v)", off, c.P)
		}
	}
	tr = step(m, t0, c.P, vec(D, D, U))
	if !tr.RetryProbe {
		t.Fatalf("距上次满 P 应再次触发重试,得到 %+v", tr)
	}
}

// TestNoRetryAtTopTier:已在最优层 T0,无更高层可升,不触发重试。
func TestNoRetryAtTopTier(t *testing.T) {
	t0 := time.Unix(1_000_000, 0)
	c := cfg3()
	m := New(c, t0)
	step(m, t0, 0, vec(U, U, U))
	step(m, t0, c.TUp, vec(U, U, U))
	if m.Active() != 0 {
		t.Fatalf("前置应在 T0")
	}
	tr := step(m, t0, c.TUp+10*c.P, vec(U, U, U))
	if tr.RetryProbe {
		t.Fatalf("最优层 T0 不应触发上层重试")
	}
}

// ------------------------------------------------------------------ 防抖

// TestFlappingDoesNotUpgrade:T0 健康/不健康交替,滞后窗口反复归零,永不升到 T0。
func TestFlappingDoesNotUpgrade(t *testing.T) {
	t0 := time.Unix(1_000_000, 0)
	c := cfg3()
	m := New(c, t0)
	off := time.Duration(0)
	upgrades := 0
	for i := 0; i < 200; i++ {
		h := vec(U, U, U)
		if i%2 == 1 {
			h = vec(D, U, U) // 每隔一拍打断 T0 连续健康
		}
		tr := step(m, t0, off, h)
		if tr.Switched && tr.To == 0 {
			upgrades++
		}
		off += c.Heartbeat
	}
	if upgrades != 0 {
		t.Fatalf("T0 抖动期间不应升到 T0,实际升级 %d 次(active=%d)", upgrades, m.Active())
	}
	// 但 T1 一直稳定健康,应升到 T1(合理:T1 不抖)。
	if m.Active() != 1 {
		t.Fatalf("T1 稳定时应停在 T1,实际 %d", m.Active())
	}
}

// TestFlappingNearDowngradeThreshold:T0 失败接近阈值但被健康打断,不频繁降级。
func TestFlappingNearDowngradeThreshold(t *testing.T) {
	t0 := time.Unix(1_000_000, 0)
	c := cfg3()
	m := New(c, t0)
	step(m, t0, 0, vec(U, U, U))
	step(m, t0, c.TUp, vec(U, U, U))
	if m.Active() != 0 {
		t.Fatalf("前置应在 T0")
	}
	base := t0.Add(c.TUp)
	off := c.Heartbeat
	downgrades := 0
	pattern := []bool{false, false, true} // down,down,up —— 永远凑不满 3 连失败
	for i := 0; i < 90; i++ {
		h := vec(D, U, U)
		if pattern[i%3] {
			h = vec(U, U, U)
		}
		tr := step(m, base, off, h)
		if tr.Switched {
			downgrades++
		}
		off += c.Heartbeat
	}
	if downgrades != 0 {
		t.Fatalf("失败被周期性健康打断时不应降级,实际切换 %d 次(active=%d)", downgrades, m.Active())
	}
}

// ------------------------------------------------------------------ 完整往返

// TestFullRoundTrip:T2 起步 → 升 T1 → 升 T0 → T0 挂降 T1 → T0 恢复升回 T0。
func TestFullRoundTrip(t *testing.T) {
	t0 := time.Unix(1_000_000, 0)
	c := cfg3()
	m := New(c, t0)

	// 起步 T2。
	if m.Active() != 2 {
		t.Fatalf("起步应在 T2")
	}
	// 升 T1。
	for off := time.Duration(0); off <= c.TUp; off += c.Heartbeat {
		step(m, t0, off, vec(D, U, U))
	}
	if m.Active() != 1 {
		t.Fatalf("应升到 T1,实际 %d", m.Active())
	}
	// 升 T0。
	b1 := t0.Add(c.TUp + c.Heartbeat)
	step(m, b1, 0, vec(U, U, U))
	step(m, b1, c.TUp, vec(U, U, U))
	if m.Active() != 0 {
		t.Fatalf("应升到 T0,实际 %d", m.Active())
	}
	// T0 挂,降 T1。
	b2 := b1.Add(c.TUp)
	for i := 1; i <= c.N; i++ {
		step(m, b2, time.Duration(i)*c.Heartbeat, vec(D, U, U))
	}
	if m.Active() != 1 {
		t.Fatalf("T0 挂应降到 T1,实际 %d", m.Active())
	}
	// T0 恢复并稳定,升回 T0。
	b3 := b2.Add(time.Duration(c.N+2) * c.Heartbeat)
	step(m, b3, 0, vec(U, U, U))
	tr := step(m, b3, c.TUp, vec(U, U, U))
	if !tr.Switched || tr.To != 0 {
		t.Fatalf("T0 恢复稳定应升回 T0,得到 %+v(active=%d)", tr, m.Active())
	}
}

// ------------------------------------------------------------------ 泛化层数

// TestGeneralizesToTwoTiers:两层阶梯(等价 Phase0 DIRECT/FALLBACK)行为正确。
func TestGeneralizesToTwoTiers(t *testing.T) {
	t0 := time.Unix(1_000_000, 0)
	c := Config{NumTiers: 2, TUp: 20 * time.Second, N: 3, P: 30 * time.Second, Heartbeat: 5 * time.Second}
	m := New(c, t0)
	if m.Active() != 1 {
		t.Fatalf("两层起步应在低优先层(索引1),实际 %d", m.Active())
	}
	// T0 稳定满 T_up → 升 T0。
	step(m, t0, 0, vec(U, U))
	tr := step(m, t0, c.TUp, vec(U, U))
	if !tr.Switched || tr.To != 0 {
		t.Fatalf("两层:T0 稳定应升到 T0,得到 %+v", tr)
	}
	// T0 失败 N 次 → 降回索引1。
	base := t0.Add(c.TUp)
	for i := 1; i <= c.N; i++ {
		step(m, base, time.Duration(i)*c.Heartbeat, vec(D, U))
	}
	if m.Active() != 1 {
		t.Fatalf("两层:T0 失败 N 次应降回索引1,实际 %d", m.Active())
	}
}

// TestGeneralizesToFourTiers:四层阶梯升降逻辑泛化正确。
func TestGeneralizesToFourTiers(t *testing.T) {
	t0 := time.Unix(1_000_000, 0)
	c := Config{NumTiers: 4, TUp: 20 * time.Second, N: 3, P: 30 * time.Second, Heartbeat: 5 * time.Second}
	m := New(c, t0)
	if m.Active() != 3 {
		t.Fatalf("四层起步应在索引3,实际 %d", m.Active())
	}
	// 只有索引1健康且稳定 → 升到索引1(跳过更低优先的2,但升不到挂掉的0)。
	for off := time.Duration(0); off <= c.TUp; off += c.Heartbeat {
		step(m, t0, off, vec(D, U, D, U))
	}
	if m.Active() != 1 {
		t.Fatalf("四层:索引1稳定应升到1,实际 %d", m.Active())
	}
}

// TestConfigValidateFallsBack:非法配置回退默认。
func TestConfigValidateFallsBack(t *testing.T) {
	c := Config{NumTiers: 0, TUp: -1, N: 0, P: 0, Heartbeat: -5}
	fixed := c.Validate()
	if !fixed {
		t.Fatalf("非法配置应标记为已回退")
	}
	d := DefaultConfig()
	if c.NumTiers != d.NumTiers || c.TUp != d.TUp || c.N != d.N || c.P != d.P || c.Heartbeat != d.Heartbeat {
		t.Fatalf("非法字段应回退默认,实际 %+v", c)
	}
}

// TestTierStateString:字符串稳定。
func TestTierStateString(t *testing.T) {
	if TierUp.String() != "UP" || TierDown.String() != "DOWN" {
		t.Fatalf("TierState.String 不符")
	}
}
