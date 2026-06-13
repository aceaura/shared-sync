package nebula

import (
	"context"
	"testing"
)

// TestDryRunLifecycle:DryRun 下 Start/Stop/Restart 的状态语义正确且幂等。
func TestDryRunLifecycle(t *testing.T) {
	m := NewManager(Options{DryRun: true})
	if s, _, _ := m.Status(); s != StatusStopped {
		t.Fatalf("初始应 STOPPED,实际 %v", s)
	}
	if err := m.Start(context.Background()); err != nil {
		t.Fatalf("Start 失败: %v", err)
	}
	if s, _, _ := m.Status(); s != StatusRunning {
		t.Fatalf("Start 后应 RUNNING,实际 %v", s)
	}
	// 幂等:再次 Start 不报错、仍 RUNNING。
	if err := m.Start(context.Background()); err != nil {
		t.Fatalf("重复 Start 失败: %v", err)
	}
	if err := m.Restart(context.Background()); err != nil {
		t.Fatalf("Restart 失败: %v", err)
	}
	if s, _, _ := m.Status(); s != StatusRunning {
		t.Fatalf("Restart 后应 RUNNING,实际 %v", s)
	}
	if err := m.Stop(); err != nil {
		t.Fatalf("Stop 失败: %v", err)
	}
	if s, _, _ := m.Status(); s != StatusStopped {
		t.Fatalf("Stop 后应 STOPPED,实际 %v", s)
	}
	// 幂等:再次 Stop 不报错。
	if err := m.Stop(); err != nil {
		t.Fatalf("重复 Stop 失败: %v", err)
	}
}

// TestNonDryRunRequiresConfig:非 DryRun 且无 ConfigPath 应报错。
func TestNonDryRunRequiresConfig(t *testing.T) {
	m := NewManager(Options{DryRun: false})
	if err := m.Start(context.Background()); err == nil {
		t.Fatalf("缺 ConfigPath 应报错")
	}
}
