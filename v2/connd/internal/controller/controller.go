// Package controller 把阶梯状态机(ladder)、三层探测器(tierprobe)、本地代理
// (proxy)与 nebula 子进程监督(nebula)粘合成 connd 的控制循环,并对外提供
// 线程安全的状态快照(DESIGN_v2.md §4/§5/§2.1)。
//
// 控制循环每 heartbeat 一拍:
//
//	tierprobe.ProbeTiers → 各层健康向量 → ladder.Machine.Tick → Transition
//	    → 若切层:把 proxy 上游原子切到「当前激活层后端」
//	    → 若 RetryProbe:(由 nebula 心跳/灌包驱动 promote;此处记录)
//	    → 刷新对外 Status 快照
package controller

import (
	"context"
	"log"
	"sync"
	"time"

	"github.com/aceaura/shared-sync/v2/connd/internal/ladder"
	"github.com/aceaura/shared-sync/v2/connd/internal/nebula"
	"github.com/aceaura/shared-sync/v2/connd/internal/proxy"
	"github.com/aceaura/shared-sync/v2/connd/internal/tierprobe"
)

// Status 是对外暴露的状态快照(HTTP /status、CLI 都消费它)。
// JSON 字段对齐 DESIGN_v2.md §6 / Phase2 任务要求:
//
//	{tier, viaVps, peer, rttMs, since, lastSwitch, tiersHealth, ...}
type Status struct {
	// Tier:当前激活层名(T0 / T1 / T2 / RECONNECTING)。
	Tier string `json:"tier"`
	// ViaVps:当前层是否经过 VPS(T1/T2 是;T0 直连不经)。
	ViaVps bool `json:"viaVps"`
	// Peer:数据中心 overlay IP。
	Peer string `json:"peer"`
	// Upstream:本地代理当前上游 "host:port"(引擎流量实际去向)。
	Upstream string `json:"upstream"`
	// LocalEndpoint:固定本地端点地址(引擎连它)。
	LocalEndpoint string `json:"localEndpoint"`
	// RTTMs:当前层最近探测 RTT(毫秒)。
	RTTMs float64 `json:"rttMs"`
	// CurrentRemote:hostmap 报告的 underlay 端点(direct 时非空,诊断用)。
	CurrentRemote string `json:"currentRemote"`
	// Since:当前层自何时保持(= lastSwitch)。
	Since time.Time `json:"since"`
	// LastSwitch:上次切层时刻。
	LastSwitch time.Time `json:"lastSwitch"`
	// TiersHealth:各层健康(键 T0/T1/T2 → UP/DOWN),便于 GUI 与运维观测。
	TiersHealth map[string]string `json:"tiersHealth"`
	// Reconnecting:是否处于「全层皆挂」的重连态(数据中心离线/VPS 故障)。
	Reconnecting bool `json:"reconnecting"`
	// Nebula:子进程状态:RUNNING / STOPPED / FAILED / DISABLED。
	Nebula string `json:"nebula"`
	// UpdatedAt:本快照生成时刻。
	UpdatedAt time.Time `json:"updatedAt"`

	// ---- 兼容 Phase0 字段(GUI/旧消费方)----
	// Path:最近探测的当前层归类(DIRECT/RELAY/DOWN),近似旧语义。
	Path string `json:"path"`
	// State:状态机状态(= Tier),兼容旧字段名。
	State string `json:"state"`
}

// UpstreamFunc 给定激活层索引,返回该层应连的上游后端 "host:port";
// 返回空串表示该层无后端(代理拒绝新连接)。
type UpstreamFunc func(tier int) string

// Controller 跑控制循环。
type Controller struct {
	machine *ladder.Machine
	prober  tierprobe.TierProber
	proxy   *proxy.Proxy
	neb     *nebula.Manager
	cfg     ladder.Config

	upstreamOf   UpstreamFunc
	probeTimeout time.Duration
	// now 可注入,便于测试用假时钟。默认 time.Now。
	now func() time.Time

	mu     sync.RWMutex
	status Status
}

// Options 构造 Controller。
type Options struct {
	Cfg           ladder.Config
	Prober        tierprobe.TierProber
	Proxy         *proxy.Proxy
	Nebula        *nebula.Manager
	UpstreamOf    UpstreamFunc // 层→上游后端;必填
	ProbeTimeout  time.Duration
	LocalEndpoint string // 固定本地端点地址(展示用)
	Now           func() time.Time
}

// New 构造控制器。
func New(opt Options) *Controller {
	now := opt.Now
	if now == nil {
		now = time.Now
	}
	opt.Cfg.Validate()
	c := &Controller{
		machine:      ladder.New(opt.Cfg, now()),
		prober:       opt.Prober,
		proxy:        opt.Proxy,
		neb:          opt.Nebula,
		cfg:          opt.Cfg,
		upstreamOf:   opt.UpstreamOf,
		probeTimeout: opt.ProbeTimeout,
		now:          now,
	}
	// 初始上游 = 启动激活层(最低优先层)的后端,先让代理可用(兜底优先)。
	c.applyUpstream(c.machine.Active())
	c.mu.Lock()
	c.status.LocalEndpoint = opt.LocalEndpoint
	c.mu.Unlock()
	c.refreshStatusWith(tierprobe.Result{At: now()}, opt.LocalEndpoint)
	return c
}

// Run 启动 nebula + 代理,进入控制循环,直到 ctx 取消。阻塞调用。
func (c *Controller) Run(ctx context.Context) error {
	if c.neb != nil {
		if err := c.neb.Start(ctx); err != nil {
			return err
		}
		defer func() { _ = c.neb.Stop() }()
	}
	if c.proxy != nil {
		go func() {
			if err := c.proxy.Start(ctx); err != nil {
				log.Printf("connd: 本地代理退出: %v", err)
			}
		}()
		defer func() { _ = c.proxy.Close() }()
	}

	ticker := time.NewTicker(c.cfg.Heartbeat)
	defer ticker.Stop()

	c.tickOnce(ctx) // 立即一拍
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
			c.tickOnce(ctx)
		}
	}
}

// tickOnce 执行一次「探测 → 喂状态机 → 切上游 → 刷新快照」。
func (c *Controller) tickOnce(ctx context.Context) {
	pctx := ctx
	if c.probeTimeout > 0 {
		var cancel context.CancelFunc
		pctx, cancel = context.WithTimeout(ctx, c.probeTimeout)
		defer cancel()
	}
	res := c.prober.ProbeTiers(pctx)
	now := c.now()

	tr := c.machine.Tick(now, res.Health())
	c.handleTransition(tr)
	c.refreshStatus(res)
}

// handleTransition 处理状态机决策的副作用:切层时原子切代理上游。
func (c *Controller) handleTransition(tr ladder.Transition) {
	if tr.Switched {
		if tr.To == ladder.NoTier {
			log.Printf("connd: 进入重连态(所有层不可用),代理暂拒新连接")
		} else {
			log.Printf("connd: 激活层切换 %s → %s", tierName(tr.From), tierName(tr.To))
		}
		c.applyUpstream(tr.To)
	}
	if tr.RetryProbe {
		// 上层重试:overlay 心跳本身已产生 overlay 流量驱动 nebula try_promote
		// (灌包→秒级切回直连,见 Phase1b handoff)。此处记录;如需更激进可在此
		// 触发额外 overlay 流量。
		log.Printf("connd: 上层探测/重试节拍(驱动 nebula promote)")
	}
}

// applyUpstream 把代理上游切到指定层的后端(NoTier → 空,拒绝新连接)。
func (c *Controller) applyUpstream(tier int) {
	if c.proxy == nil {
		return
	}
	up := ""
	if tier != ladder.NoTier && c.upstreamOf != nil {
		up = c.upstreamOf(tier)
	}
	c.proxy.SetUpstream(up)
}

// refreshStatus 用最近探测结果与状态机快照更新对外状态(保留已设 LocalEndpoint)。
func (c *Controller) refreshStatus(res tierprobe.Result) {
	c.mu.RLock()
	local := c.status.LocalEndpoint
	c.mu.RUnlock()
	c.refreshStatusWith(res, local)
}

func (c *Controller) refreshStatusWith(res tierprobe.Result, local string) {
	snap := c.machine.Snapshot()
	nebStatus := "DISABLED"
	if c.neb != nil {
		s, _, _ := c.neb.Status()
		nebStatus = s.String()
	}

	active := snap.Active
	tier := "RECONNECTING"
	viaVps := false
	rtt := 0.0
	if active != ladder.NoTier {
		tier = tierprobe.TierName(active)
		viaVps = active != tierprobe.TierDirect // T1/T2 经 VPS;T0 不经
		rtt = float64(res.RTT(active)) / float64(time.Millisecond)
	}

	health := map[string]string{}
	for i, st := range snap.TiersHealth {
		health[tierprobe.TierName(i)] = st.String()
	}

	upstream := ""
	if c.proxy != nil {
		upstream = c.proxy.Upstream()
	}

	c.mu.Lock()
	c.status = Status{
		Tier:          tier,
		ViaVps:        viaVps,
		Peer:          c.prober.Peer(),
		Upstream:      upstream,
		LocalEndpoint: local,
		RTTMs:         rtt,
		CurrentRemote: res.CurrentRemote,
		Since:         snap.LastSwitch,
		LastSwitch:    snap.LastSwitch,
		TiersHealth:   health,
		Reconnecting:  snap.Reconnecting,
		Nebula:        nebStatus,
		UpdatedAt:     c.now(),
		Path:          legacyPath(snap),
		State:         tier,
	}
	c.mu.Unlock()
}

// legacyPath 把激活层映射成 Phase0 的 Path 语义(DIRECT/RELAY/DOWN),兼容旧消费方。
func legacyPath(s ladder.Snapshot) string {
	switch {
	case s.Reconnecting:
		return "DOWN"
	case s.Active == tierprobe.TierDirect:
		return "DIRECT"
	default:
		return "RELAY"
	}
}

func tierName(i int) string {
	if i == ladder.NoTier {
		return "RECONNECTING"
	}
	return tierprobe.TierName(i)
}

// Status 返回当前对外状态快照(线程安全)。
func (c *Controller) Status() Status {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.status
}
