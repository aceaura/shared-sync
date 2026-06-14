// Package ladder 实现 connd 的「N 层优先级阶梯」状态机(DESIGN_v2.md §4)。
//
// 这是 Phase2 对 Phase0 两态 fsm 的泛化。Phase0 的 fsm 只有 FALLBACK⇄DIRECT
// 两态;v2 的真实路径阶梯有三层(T0 DIRECT / T1 UDP_RELAY / T2 TCP_RELAY),
// 且 DESIGN_v2.md §4 要求「阶梯可配置增减层数」。本包把状态机泛化为:
//
//	维护每层健康向量 → 始终运行在「当前健康的最高优先层」;
//	升级需更高层稳定 ≥ T_up(滞后窗口,防抖);
//	降级则当前层连续失败 N 次后落到下方仍健康的最高层(兜底优先于性能);
//	全部层都不健康 → 进入 RECONNECTING(对端真下线 / VPS 故障)。
//
// 与 Phase0 一致,状态机被刻意做成**纯逻辑**:不读时钟、不起协程、不碰网络。
// 探测结果(各层健康向量)与时间都由调用方(controller)注入,故可被确定性单测
// (见 ladder_test.go)。
//
// 层编号约定:索引 0 = 优先级最高(最优:最快/最省 VPS/最私密)= T0;
// 索引越大优先级越低,最后一层是终极兜底(T2)。这与 DESIGN_v2.md 的 T0/T1/T2
// 命名一致(Tier i 的索引就是 i)。
package ladder

import "time"

// TierState 是某一层的瞬时健康判定(由 prober 给出)。
type TierState int

const (
	// TierDown:该层本次探测不可达。
	TierDown TierState = iota
	// TierUp:该层本次探测可达且健康。
	TierUp
)

func (s TierState) String() string {
	if s == TierUp {
		return "UP"
	}
	return "DOWN"
}

// NoTier 是「当前未运行在任何层」的哨兵(RECONNECTING 时 Active() 返回它)。
const NoTier = -1

// Config 是阶梯状态机的可配参数(DESIGN_v2.md §4 末)。
type Config struct {
	// NumTiers:阶梯层数(≥1)。索引 0..NumTiers-1,0 最优。
	NumTiers int
	// TUp:升级滞后窗口。更高优先层必须**连续保持健康 ≥ TUp** 才升级上去。
	// 建议 20–30s。
	TUp time.Duration
	// N:降级阈值。当前层**连续失败 N 次**立即降级到下方仍健康的最高层。
	// 建议 3–5。
	N int
	// P:上层探测/打洞重试周期。运行在非最优层时,每隔 P 触发一次后台重试
	// (由调用方监听 RetryProbe 决定是否真正发起,如灌包驱动 nebula promote)。
	// 建议 30–60s。
	P time.Duration
	// Heartbeat:心跳/探测间隔。仅作元信息暴露;Tick 的实际节奏由调用方掌握。
	Heartbeat time.Duration
}

// DefaultConfig 返回 DESIGN_v2.md §4 建议值(三层)。
func DefaultConfig() Config {
	return Config{
		NumTiers:  3,
		TUp:       25 * time.Second,
		N:         3,
		P:         45 * time.Second,
		Heartbeat: 7 * time.Second,
	}
}

// Validate 校验配置并对非法值回退默认。返回是否做过回退,便于调用方告警。
func (c *Config) Validate() (fixed bool) {
	d := DefaultConfig()
	if c.NumTiers <= 0 {
		c.NumTiers = d.NumTiers
		fixed = true
	}
	if c.TUp <= 0 {
		c.TUp = d.TUp
		fixed = true
	}
	if c.N <= 0 {
		c.N = d.N
		fixed = true
	}
	if c.P <= 0 {
		c.P = d.P
		fixed = true
	}
	if c.Heartbeat <= 0 {
		c.Heartbeat = d.Heartbeat
		fixed = true
	}
	return fixed
}

// Transition 描述一次 Tick 后的决策结果,供调用方驱动副作用
// (原子切换本地代理上游、触发上层重试等)。
type Transition struct {
	// From/To:本次 Tick 前后的激活层索引(NoTier 表示 RECONNECTING)。
	// From==To 表示未切换。
	From int
	To   int
	// Switched:激活层是否发生变化(From != To)。
	Switched bool
	// Reconnecting:本次 Tick 后是否处于「所有层皆不健康」的重连态。
	Reconnecting bool
	// RetryProbe:本次 Tick 调用方是否应主动触发一次上层探测/重试
	// (如灌包驱动 nebula 从 relay 提升直连)。仅当存在比当前激活层更优、
	// 但尚未稳定的层、且距上次重试已过 P 时为 true。
	RetryProbe bool
}

// Machine 是阶梯状态机本体。**非并发安全**:由单一驱动循环(controller)串行
// 调用 Tick;并发读快照请用上层加锁(见 controller 包)。
type Machine struct {
	cfg Config

	// active:当前激活层索引;NoTier 表示 RECONNECTING(无健康层)。
	active int

	// upHealthySince[i]:第 i 层「连续健康」段的起点;upHealthy[i] 标记是否有效。
	// 仅对**比 active 更优**(索引更小)的层有意义,用于升级滞后判定。
	upHealthySince []time.Time
	upHealthy      []bool

	// failStreak:active 层连续失败次数(用于降级阈值 N)。
	failStreak int

	// lastRetry / retried:上次主动上层重试时刻 / 是否已重试过(进入新态首拍立即重试)。
	lastRetry time.Time
	retried   bool

	// lastSwitch:上次激活层切换时刻(含启动初值)。
	lastSwitch time.Time

	// lastHealth:最近一次喂入的各层健康向量,供 Snapshot 暴露。
	lastHealth []TierState
}

// New 构造阶梯状态机。
//
// 初始激活层 = **最低优先层(索引 NumTiers-1)**:兜底优先(DESIGN_v2.md §2.2),
// 先用最可达的低层保证立刻可用,后台再逐级向上探测升级。
// now 为启动时刻,用于初始化 lastSwitch/lastRetry 基准。
func New(cfg Config, now time.Time) *Machine {
	cfg.Validate()
	m := &Machine{
		cfg:            cfg,
		active:         cfg.NumTiers - 1, // 启动落在最低优先层(终极兜底)
		upHealthySince: make([]time.Time, cfg.NumTiers),
		upHealthy:      make([]bool, cfg.NumTiers),
		lastSwitch:     now,
		lastHealth:     make([]TierState, cfg.NumTiers),
	}
	return m
}

// Active 返回当前激活层索引(NoTier 表示 RECONNECTING)。
func (m *Machine) Active() int { return m.active }

// Config 返回当前生效配置(已校验)。
func (m *Machine) Config() Config { return m.cfg }

// LastSwitch 返回上次切换时刻。
func (m *Machine) LastSwitch() time.Time { return m.lastSwitch }

// Tick 喂入一次「各层健康向量」并推进状态机。now 必须单调不减;
// health 长度须等于 NumTiers(health[i] 为第 i 层本次探测健康判定),
// 长度不符时按 NumTiers 截断 / 以 TierDown 补齐(健壮容错)。
//
// 决策规则(DESIGN_v2.md §4):
//
//  1. 降级优先于升级:若当前激活层本次不健康 → failStreak++;达 N 立即落到
//     **下方仍健康的最高优先层**(active 之下、最靠近 active 的健康层);
//     若下方也无健康层,则落到**全局最高优先的健康层**(可能在 active 之上,
//     即直接抢救到任一可用层);若全无健康层 → RECONNECTING(active=NoTier)。
//  2. 升级(滞后):存在比 active 更优(索引更小)的层,且其**连续健康 ≥ T_up**
//     → 升级到「满足 T_up 的最高优先层」。任一次不健康都会把该层连续健康段归零
//     (防抖核心)。
//  3. 从 RECONNECTING 恢复:一旦有任意层健康,立即抢救到**最高优先的健康层**
//     (兜底优先,先连上再说),其上更优层照常走升级滞后。
//  4. 上层重试节拍:存在比 active 更优但尚未升上去的层时,每 P 触发一次 RetryProbe。
func (m *Machine) Tick(now time.Time, health []TierState) Transition {
	m.recordHealth(health)
	from := m.active
	tr := Transition{From: from, To: from}

	// ---- 维护「更优层连续健康」段(升级滞后窗口的累积),对所有层统一维护 ----
	// 对每一层:健康则(若之前不在连续段)记起点;不健康则清零其连续段。
	for i := 0; i < m.cfg.NumTiers; i++ {
		if m.healthOf(health, i) == TierUp {
			if !m.upHealthy[i] {
				m.upHealthy[i] = true
				m.upHealthySince[i] = now
			}
		} else {
			m.upHealthy[i] = false
			m.upHealthySince[i] = time.Time{}
		}
	}

	activeHealthy := m.active != NoTier && m.healthOf(health, m.active) == TierUp

	// ---- 1) 降级 / 重连判定(当前层不健康)----
	if m.active == NoTier {
		// 当前在 RECONNECTING:一旦有任意健康层,立即抢救到最高优先健康层。
		if best := m.highestHealthy(health); best != NoTier {
			m.switchTo(best, now)
			tr.To = best
			tr.Switched = true
		}
	} else if activeHealthy {
		m.failStreak = 0
	} else {
		m.failStreak++
		if m.failStreak >= m.cfg.N {
			// 降级:优先落到 active **下方**仍健康的最高优先层(兜底优先于性能)。
			target := m.highestHealthyBelow(health, m.active)
			if target == NoTier {
				// 下方无健康层 → 退而求其次,抢救到全局最高优先健康层
				// (可能在 active 之上;此时"当前层挂了但更优层还活着")。
				target = m.highestHealthy(health)
			}
			if target == NoTier {
				// 全无健康层 → 进入重连态。
				m.switchTo(NoTier, now)
				tr.To = NoTier
				tr.Switched = true
			} else if target != m.active {
				m.switchTo(target, now)
				tr.To = target
				tr.Switched = true
			} else {
				// target==active 不应发生(active 不健康),保险起见重置计数。
				m.failStreak = 0
			}
		}
	}

	// ---- 2) 升级判定(滞后):仅当未在本拍降级切换时考虑 ----
	if !tr.Switched && m.active != NoTier {
		if up := m.upgradeTarget(now); up != NoTier && up < m.active {
			m.switchTo(up, now)
			tr.To = up
			tr.Switched = true
		}
	}

	tr.Reconnecting = m.active == NoTier

	// ---- 3) 上层重试节拍 ----
	if m.shouldRetry(now, health) {
		tr.RetryProbe = true
		m.lastRetry = now
		m.retried = true
	}

	return tr
}

// upgradeTarget 返回「连续健康 ≥ T_up 的最高优先层」索引;无则 NoTier。
// 只考虑比当前 active 更优(索引更小)的层。
func (m *Machine) upgradeTarget(now time.Time) int {
	limit := m.active
	if m.active == NoTier {
		limit = m.cfg.NumTiers
	}
	for i := 0; i < limit; i++ {
		if m.upHealthy[i] && now.Sub(m.upHealthySince[i]) >= m.cfg.TUp {
			return i // 从最优往下扫,第一个满足的就是最高优先
		}
	}
	return NoTier
}

// highestHealthy 返回全局最高优先(索引最小)的健康层;无则 NoTier。
func (m *Machine) highestHealthy(health []TierState) int {
	for i := 0; i < m.cfg.NumTiers; i++ {
		if m.healthOf(health, i) == TierUp {
			return i
		}
	}
	return NoTier
}

// highestHealthyBelow 返回严格在 ref **下方**(索引 > ref)的最高优先健康层;无则 NoTier。
func (m *Machine) highestHealthyBelow(health []TierState, ref int) int {
	for i := ref + 1; i < m.cfg.NumTiers; i++ {
		if m.healthOf(health, i) == TierUp {
			return i
		}
	}
	return NoTier
}

// shouldRetry 判断本拍是否应触发上层探测/重试。
// 条件:存在比 active 更优、当前未健康(或健康但尚未稳定到可升级)的层,
// 且距上次重试已过 P(进入新态首拍立即重试一次)。
func (m *Machine) shouldRetry(now time.Time, health []TierState) bool {
	// 已在最优层(T0)则无更高层可升,不需重试。
	if m.active == 0 {
		return false
	}
	if !m.retried {
		return true // 进入/切换后的第一拍立即重试。
	}
	return now.Sub(m.lastRetry) >= m.cfg.P
}

// switchTo 执行激活层切换的内部簿记。
func (m *Machine) switchTo(target int, now time.Time) {
	m.active = target
	m.lastSwitch = now
	m.failStreak = 0
	// 切换后重置上层重试节拍,让新态首拍立即重试。
	m.retried = false
}

// recordHealth 记录本拍健康向量(规整到 NumTiers 长度)供 Snapshot 暴露。
func (m *Machine) recordHealth(health []TierState) {
	for i := 0; i < m.cfg.NumTiers; i++ {
		m.lastHealth[i] = m.healthOf(health, i)
	}
}

// healthOf 安全取第 i 层健康(越界按 DOWN)。
func (m *Machine) healthOf(health []TierState, i int) TierState {
	if i < 0 || i >= len(health) {
		return TierDown
	}
	return health[i]
}

// Snapshot 是供状态暴露(HTTP /status、CLI)的只读视图。
type Snapshot struct {
	Active       int         // 当前激活层索引;NoTier=RECONNECTING
	Reconnecting bool        // 是否在重连态
	LastSwitch   time.Time   // 上次切层时刻
	FailStreak   int         // 当前激活层连续失败次数
	TiersHealth  []TierState // 最近一次各层健康向量(长度 NumTiers)
}

// Snapshot 返回当前内部状态的只读快照。
func (m *Machine) Snapshot() Snapshot {
	h := make([]TierState, m.cfg.NumTiers)
	copy(h, m.lastHealth)
	return Snapshot{
		Active:       m.active,
		Reconnecting: m.active == NoTier,
		LastSwitch:   m.lastSwitch,
		FailStreak:   m.failStreak,
		TiersHealth:  h,
	}
}
