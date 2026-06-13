// Package nebula 管理 nebula 子进程的生命周期(启动/停止/重启,传 -config)。
//
// connd 作为 sidecar,把 nebula 当作受管子进程:负责拉起、监督、优雅停止与重启。
// 真实运行需要 nebula 二进制在 PATH 或显式指定路径;无二进制时(如 CI/单测)
// 用 DryRun 跳过真正 exec,仅维护状态机所需的"进程存活"语义。
package nebula

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"sync"
	"syscall"
	"time"
)

// Status 是子进程的生命周期状态。
type Status int

const (
	StatusStopped Status = iota
	StatusRunning
	StatusFailed
)

func (s Status) String() string {
	switch s {
	case StatusRunning:
		return "RUNNING"
	case StatusFailed:
		return "FAILED"
	default:
		return "STOPPED"
	}
}

// Options 配置 nebula 子进程。
type Options struct {
	// BinPath:nebula 二进制路径(默认 "nebula",从 PATH 查找)。
	BinPath string
	// ConfigPath:传给 nebula 的 -config 文件路径(必填,除非 DryRun)。
	ConfigPath string
	// DryRun:不真正 exec,仅模拟"已启动"。用于无 nebula 的环境跑通控制链路/单测。
	DryRun bool
	// StopTimeout:优雅停止(SIGTERM)后等待退出的时限,超时则 SIGKILL。
	StopTimeout time.Duration
	// Stdout/Stderr:子进程输出去向;nil 则继承当前进程。
	Stdout, Stderr *os.File
}

// Manager 监督单个 nebula 子进程。并发安全。
type Manager struct {
	opt Options

	mu      sync.Mutex
	cmd     *exec.Cmd
	status  Status
	started time.Time
	lastErr error
	// done 在进程退出后关闭;每次启动重建。
	done chan struct{}
}

// NewManager 构造监督器。
func NewManager(opt Options) *Manager {
	if opt.BinPath == "" {
		opt.BinPath = "nebula"
	}
	if opt.StopTimeout <= 0 {
		opt.StopTimeout = 5 * time.Second
	}
	return &Manager{opt: opt, status: StatusStopped}
}

// Start 启动 nebula 子进程(传 -config)。已在运行则返回 nil(幂等)。
func (m *Manager) Start(ctx context.Context) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.status == StatusRunning {
		return nil
	}
	if m.opt.DryRun {
		m.status = StatusRunning
		m.started = time.Now()
		m.lastErr = nil
		m.done = make(chan struct{})
		// DryRun 下进程"永不自然退出",由 Stop 关闭 done。
		return nil
	}
	if m.opt.ConfigPath == "" {
		return errors.New("nebula: ConfigPath 必填(非 DryRun)")
	}

	cmd := exec.Command(m.opt.BinPath, "-config", m.opt.ConfigPath)
	cmd.Stdout = m.opt.Stdout
	cmd.Stderr = m.opt.Stderr
	if err := cmd.Start(); err != nil {
		m.status = StatusFailed
		m.lastErr = err
		return fmt.Errorf("nebula: 启动失败: %w", err)
	}
	m.cmd = cmd
	m.status = StatusRunning
	m.started = time.Now()
	m.lastErr = nil
	done := make(chan struct{})
	m.done = done

	// 监督协程:等待子进程退出并记录结果。
	go func() {
		err := cmd.Wait()
		m.mu.Lock()
		if m.status == StatusRunning { // 非主动 Stop 触发的退出 = 异常
			if err != nil {
				m.status = StatusFailed
				m.lastErr = err
			} else {
				m.status = StatusStopped
			}
		}
		m.mu.Unlock()
		close(done)
	}()
	return nil
}

// Stop 优雅停止子进程:SIGTERM,超时后 SIGKILL。幂等。
func (m *Manager) Stop() error {
	m.mu.Lock()
	if m.status != StatusRunning {
		m.mu.Unlock()
		return nil
	}
	if m.opt.DryRun {
		m.status = StatusStopped
		if m.done != nil {
			close(m.done)
			m.done = nil
		}
		m.mu.Unlock()
		return nil
	}
	cmd := m.cmd
	done := m.done
	m.status = StatusStopped // 标记为主动停止,避免监督协程误判为 FAILED
	m.mu.Unlock()

	if cmd == nil || cmd.Process == nil {
		return nil
	}
	_ = cmd.Process.Signal(syscall.SIGTERM)
	select {
	case <-done:
		return nil
	case <-time.After(m.opt.StopTimeout):
		_ = cmd.Process.Kill()
		<-done
		return nil
	}
}

// Restart 重启子进程(停止后重新启动)。
func (m *Manager) Restart(ctx context.Context) error {
	if err := m.Stop(); err != nil {
		return err
	}
	return m.Start(ctx)
}

// Status 返回当前生命周期状态与上次错误。
func (m *Manager) Status() (Status, time.Time, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.status, m.started, m.lastErr
}
