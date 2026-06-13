// Package fsm 实现 connd 的连接路径状态机(DESIGN_v2.md §4)。
//
// 状态机是 connd 的核心,被刻意设计成**纯逻辑**:它不直接做网络探测、
// 不读时钟、不起协程。所有外部输入(探测结果、时间)都由调用方注入,
// 这样状态机可以被确定性地单元测试(见 fsm_test.go)。
//
// 状态(DESIGN_v2.md §4):
//
//	FALLBACK(中继兜底)  ⇄  DIRECT(打洞直连)
//
//   - 启动即进入 FALLBACK:先用中继保证立刻可达,后台再尝试打洞。
//   - FALLBACK → DIRECT(升级/切回):直连健康**连续稳定 ≥ T_up**(滞后窗口)
//     才切过去,防止抖动导致频繁来回切(flapping)。
//   - DIRECT → FALLBACK(降级):直连心跳**连续失败 N 次**立即切回中继
//     (兜底优先于性能)。
package fsm

import "time"

// State 是连接路径的高层状态。
type State int

const (
	// Fallback:数据走中继(relay)。启动初值;也是直连不可用时的兜底。
	Fallback State = iota
	// Direct:数据走打洞后的 P2P 直连。
	Direct
)

func (s State) String() string {
	switch s {
	case Fallback:
		return "FALLBACK"
	case Direct:
		return "DIRECT"
	default:
		return "UNKNOWN"
	}
}

// Path 是探测器对**某条具体路径**的可达性归类(见 prober 包)。
// 与 State 不同:State 是状态机当前选定的路径;Path 是某一次探测的瞬时结果。
type Path int

const (
	// PathDown:该路径完全不通。
	PathDown Path = iota
	// PathRelay:仅经中继可达(打洞未成功)。
	PathRelay
	// PathDirect:打洞直连可达。
	PathDirect
)

func (p Path) String() string {
	switch p {
	case PathDirect:
		return "DIRECT"
	case PathRelay:
		return "RELAY"
	case PathDown:
		return "DOWN"
	default:
		return "UNKNOWN"
	}
}

// Config 是状态机的可配参数(DESIGN_v2.md §4 末)。
type Config struct {
	// TUp:升级滞后窗口。直连必须**连续保持健康 ≥ TUp** 才从 FALLBACK 升级到 DIRECT。
	// 建议 20–30s。
	TUp time.Duration
	// N:降级阈值。DIRECT 状态下直连心跳**连续失败 N 次**立即降级到 FALLBACK。
	// 建议 3–5。
	N int
	// P:打洞重试周期。FALLBACK 状态下每隔 P 触发一次后台打洞重试(由调用方监听
	// ShouldRetryPunch 决定是否真正发起)。建议 30–60s。
	P time.Duration
	// Heartbeat:心跳/探测间隔。仅作元信息暴露,Tick 的实际节奏由调用方掌握。
	// 建议 5–10s。
	Heartbeat time.Duration
}

// DefaultConfig 返回 DESIGN_v2.md §4 建议值的中位数。
func DefaultConfig() Config {
	return Config{
		TUp:       25 * time.Second,
		N:         3,
		P:         45 * time.Second,
		Heartbeat: 7 * time.Second,
	}
}

// Validate 校验配置并对非法值回退到默认。返回是否做过回退,便于调用方告警。
func (c *Config) Validate() (fixed bool) {
	d := DefaultConfig()
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

// Probe 是一次探测的输入快照,喂给 Machine.Tick。
type Probe struct {
	// DirectPath:本次探测对**直连路径**的归类。
	// PathDirect=直连健康;PathRelay/PathDown=直连不健康(后两者对状态机等价,
	// 都视为"直连这次没成")。
	DirectPath Path
	// RelayUp:中继路径本次是否可达。仅用于暴露/诊断,不参与 FALLBACK⇄DIRECT 的
	// 主决策(降级永远先回到 FALLBACK 这一兜底)。
	RelayUp bool
	// RTT:本次探测测得的往返时延;PathDown 时无意义。仅作元信息。
	RTT time.Duration
}

// Transition 描述一次 Tick 之后的决策结果,供调用方驱动副作用
// (真正切换 endpoint、触发打洞等)。
type Transition struct {
	// From/To:本次 Tick 前后的状态。From==To 表示未切换。
	From State
	To   State
	// Switched:状态是否发生变化(From != To)。
	Switched bool
	// ShouldRetryPunch:本次 Tick 调用方是否应发起一次后台打洞重试。
	// 仅在 FALLBACK 状态、且距上次重试已过 P 时为 true。
	ShouldRetryPunch bool
}

// Machine 是状态机本体。**非并发安全**:由单一驱动循环(connd 的 control loop)
// 串行调用 Tick;需要并发读快照请用上层加锁(见 connd 包)。
type Machine struct {
	cfg   Config
	state State

	// directHealthySince:直连连续健康的起点;清零表示"当前不在连续健康段内"。
	directHealthySince time.Time
	// directHealthy:directHealthySince 是否有效(避免零值时刻歧义)。
	directHealthy bool

	// directFailStreak:DIRECT 状态下直连连续失败次数。
	directFailStreak int

	// lastPunchRetry:上次发起打洞重试的时刻。
	lastPunchRetry time.Time
	// punchRetried:lastPunchRetry 是否已被设置过。
	punchRetried bool

	// lastSwitch:上次状态切换的时刻(含启动初值)。
	lastSwitch time.Time

	// lastProbe:最近一次探测快照,供 Snapshot 暴露。
	lastProbe Probe
}

// New 构造状态机。初始状态恒为 FALLBACK(兜底优先,DESIGN_v2.md §2.2)。
// now 为启动时刻,用于初始化 lastSwitch/lastPunchRetry 基准。
func New(cfg Config, now time.Time) *Machine {
	cfg.Validate()
	return &Machine{
		cfg:        cfg,
		state:      Fallback,
		lastSwitch: now,
	}
}

// State 返回当前高层状态。
func (m *Machine) State() State { return m.state }

// Config 返回当前生效配置(已校验过)。
func (m *Machine) Config() Config { return m.cfg }

// LastSwitch 返回上次切换时刻。
func (m *Machine) LastSwitch() time.Time { return m.lastSwitch }

// Tick 喂入一次探测结果并推进状态机。now 为本次探测的时刻,必须单调不减。
//
// 决策规则(DESIGN_v2.md §4):
//
//	DIRECT 状态:
//	  - 直连健康  → 清零失败计数,保持 DIRECT。
//	  - 直连不健康 → 失败计数 +1;累计达 N 次立即降级 FALLBACK。
//	FALLBACK 状态:
//	  - 直连健康  → 维护"连续健康"段;连续健康时长 ≥ T_up 才升级 DIRECT。
//	  - 直连不健康 → 打断连续健康段(滞后窗口归零,这就是防抖核心)。
//	  - 距上次打洞重试 ≥ P → 标记 ShouldRetryPunch。
func (m *Machine) Tick(now time.Time, p Probe) Transition {
	m.lastProbe = p
	from := m.state
	healthy := p.DirectPath == PathDirect

	tr := Transition{From: from, To: from}

	switch m.state {
	case Direct:
		if healthy {
			m.directFailStreak = 0
		} else {
			m.directFailStreak++
			if m.directFailStreak >= m.cfg.N {
				m.transitionTo(Fallback, now)
				tr.To = Fallback
				tr.Switched = true
				// 刚降级,重置打洞重试基准,让 FALLBACK 立刻开始按 P 重试。
				m.punchRetried = false
			}
		}

	case Fallback:
		if healthy {
			if !m.directHealthy {
				m.directHealthy = true
				m.directHealthySince = now
			}
			// 滞后窗口:连续健康时长达到 T_up 才升级。
			if now.Sub(m.directHealthySince) >= m.cfg.TUp {
				m.transitionTo(Direct, now)
				tr.To = Direct
				tr.Switched = true
				m.directFailStreak = 0
			}
		} else {
			// 抖动:任一次不健康都打断连续健康段 → 滞后窗口归零。
			m.directHealthy = false
		}

		// 打洞重试节拍(与升级判定独立)。
		if m.shouldRetryPunch(now) {
			tr.ShouldRetryPunch = true
			m.lastPunchRetry = now
			m.punchRetried = true
		}
	}

	return tr
}

// shouldRetryPunch 判断 FALLBACK 下本次是否到了打洞重试节拍。
func (m *Machine) shouldRetryPunch(now time.Time) bool {
	if !m.punchRetried {
		return true // 进入/重入 FALLBACK 后的第一拍立即重试。
	}
	return now.Sub(m.lastPunchRetry) >= m.cfg.P
}

// transitionTo 执行状态切换的内部簿记。
func (m *Machine) transitionTo(s State, now time.Time) {
	m.state = s
	m.lastSwitch = now
	// 切换后清理对侧累积量,避免旧状态的计数污染新状态。
	switch s {
	case Direct:
		m.directHealthy = false
		m.directHealthySince = time.Time{}
	case Fallback:
		m.directFailStreak = 0
		m.directHealthy = false
		m.directHealthySince = time.Time{}
	}
}

// Snapshot 是供状态暴露(HTTP /status、CLI)的只读视图。
type Snapshot struct {
	State          State
	LastProbe      Probe
	LastSwitch     time.Time
	FailStreak     int
	HealthySince   time.Time // 仅 FALLBACK 且正在累积升级窗口时有意义
	HealthyForUpgr bool      // 当前是否在累积连续健康段
}

// Snapshot 返回当前内部状态的只读快照。
func (m *Machine) Snapshot() Snapshot {
	return Snapshot{
		State:          m.state,
		LastProbe:      m.lastProbe,
		LastSwitch:     m.lastSwitch,
		FailStreak:     m.directFailStreak,
		HealthySince:   m.directHealthySince,
		HealthyForUpgr: m.directHealthy,
	}
}
