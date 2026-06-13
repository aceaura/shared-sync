// Package controller 把状态机(fsm)、探测器(prober)与 nebula 子进程监督
// (nebula)粘合成 connd 的控制循环,并对外提供线程安全的状态快照。
package controller

import (
	"context"
	"log"
	"sync"
	"time"

	"github.com/aceaura/shared-sync/v2/connd/internal/fsm"
	"github.com/aceaura/shared-sync/v2/connd/internal/nebula"
	"github.com/aceaura/shared-sync/v2/connd/internal/prober"
)

// Status 是对外暴露的状态快照(HTTP /status、CLI 都消费它)。
// JSON 字段名与 DESIGN_v2.md 要求对齐:{path, peer, rttMs, since, lastSwitch}。
type Status struct {
	Path       string    `json:"path"`       // DIRECT / RELAY / DOWN(最近一次探测路径)
	State      string    `json:"state"`      // 状态机状态:DIRECT / FALLBACK
	Peer       string    `json:"peer"`       // 对端 overlay IP
	RTTMs      float64   `json:"rttMs"`      // 最近探测 RTT(毫秒)
	Since      time.Time `json:"since"`      // 当前状态自何时保持(= lastSwitch)
	LastSwitch time.Time `json:"lastSwitch"` // 上次切换时刻
	Nebula     string    `json:"nebula"`     // 子进程状态:RUNNING / STOPPED / FAILED
	UpdatedAt  time.Time `json:"updatedAt"`  // 本快照生成时刻
}

// Controller 跑控制循环。
type Controller struct {
	machine *fsm.Machine
	prober  prober.Prober
	neb     *nebula.Manager
	cfg     fsm.Config

	probeTimeout time.Duration
	// now 可注入,便于测试用假时钟。默认 time.Now。
	now func() time.Time

	mu     sync.RWMutex
	status Status
}

// New 构造控制器。now 传 nil 用 time.Now。
func New(cfg fsm.Config, p prober.Prober, neb *nebula.Manager, probeTimeout time.Duration, now func() time.Time) *Controller {
	if now == nil {
		now = time.Now
	}
	cfg.Validate()
	c := &Controller{
		machine:      fsm.New(cfg, now()),
		prober:       p,
		neb:          neb,
		cfg:          cfg,
		probeTimeout: probeTimeout,
		now:          now,
	}
	c.refreshStatus(prober.Result{Path: fsm.PathDown, At: now()})
	return c
}

// Run 启动 nebula 并进入控制循环,直到 ctx 取消。阻塞调用。
func (c *Controller) Run(ctx context.Context) error {
	if c.neb != nil {
		if err := c.neb.Start(ctx); err != nil {
			return err
		}
		defer func() { _ = c.neb.Stop() }()
	}

	ticker := time.NewTicker(c.cfg.Heartbeat)
	defer ticker.Stop()

	// 立即跑一拍,不等第一个 tick。
	c.tickOnce(ctx)
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
			c.tickOnce(ctx)
		}
	}
}

// tickOnce 执行一次"探测 → 喂状态机 → 处理副作用 → 刷新快照"。
func (c *Controller) tickOnce(ctx context.Context) {
	pctx := ctx
	if c.probeTimeout > 0 {
		var cancel context.CancelFunc
		pctx, cancel = context.WithTimeout(ctx, c.probeTimeout)
		defer cancel()
	}
	res := c.prober.Probe(pctx)
	now := c.now()

	tr := c.machine.Tick(now, res.ToProbe())
	c.handleTransition(ctx, tr)
	c.refreshStatus(res)
}

// handleTransition 处理状态机决策的副作用。
//
// Phase0:真正的 endpoint 切换由 nebula 自身完成(nebula 的 hostmap 会自动在
// direct/relay 间选路),connd 这里只记录/打洞重试。切换时不需要重启 nebula——
// overlay IP 不变。这正是 DESIGN_v2.md §2.1 "切换对上层透明"的体现。
//
// TODO(phase1): ShouldRetryPunch 时主动触发 nebula 重新打洞
// (如向 nebula 发信号或调用其控制接口促使 rehandshake)。
func (c *Controller) handleTransition(ctx context.Context, tr fsm.Transition) {
	if tr.Switched {
		log.Printf("connd: 路径切换 %s → %s", tr.From, tr.To)
	}
	if tr.ShouldRetryPunch {
		log.Printf("connd: 触发打洞重试(FALLBACK 周期重试 P)")
		// TODO(phase1): 在此促使 nebula 重新发起 handshake/打洞。
	}
}

// refreshStatus 用最近探测结果与状态机快照更新对外状态。
func (c *Controller) refreshStatus(res prober.Result) {
	snap := c.machine.Snapshot()
	nebStatus := "DISABLED"
	if c.neb != nil {
		s, _, _ := c.neb.Status()
		nebStatus = s.String()
	}

	c.mu.Lock()
	c.status = Status{
		Path:       res.Path.String(),
		State:      snap.State.String(),
		Peer:       c.prober.Peer(),
		RTTMs:      float64(res.RTT) / float64(time.Millisecond),
		Since:      snap.LastSwitch,
		LastSwitch: snap.LastSwitch,
		Nebula:     nebStatus,
		UpdatedAt:  c.now(),
	}
	c.mu.Unlock()
}

// Status 返回当前对外状态快照(线程安全)。
func (c *Controller) Status() Status {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.status
}
