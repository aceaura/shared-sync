package config

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// TestLoadOverlaysDefaults:YAML 只给部分字段,其余保留默认。
func TestLoadOverlaysDefaults(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "connd.yaml")
	content := `
peerOverlayIP: 10.77.0.3
tUp: 30s
n: 5
nebula:
  configPath: /etc/nebula/node.yml
`
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	c, err := Load(path)
	if err != nil {
		t.Fatalf("加载失败: %v", err)
	}
	if c.PeerOverlayIP != "10.77.0.3" {
		t.Fatalf("peerOverlayIP 不符: %q", c.PeerOverlayIP)
	}
	if c.TUp.D() != 30*time.Second {
		t.Fatalf("tUp 不符: %v", c.TUp.D())
	}
	if c.N != 5 {
		t.Fatalf("n 不符: %d", c.N)
	}
	// 未提供的字段应取默认。
	if c.StatusAddr != "127.0.0.1:4243" {
		t.Fatalf("statusAddr 应为默认,实际 %q", c.StatusAddr)
	}
	if c.P.D() != DefaultP() {
		t.Fatalf("p 应为默认 %v,实际 %v", DefaultP(), c.P.D())
	}
	if c.Nebula.BinPath != "nebula" {
		t.Fatalf("nebula.binPath 应为默认 nebula,实际 %q", c.Nebula.BinPath)
	}
	if c.Nebula.ConfigPath != "/etc/nebula/node.yml" {
		t.Fatalf("nebula.configPath 不符: %q", c.Nebula.ConfigPath)
	}
}

// DefaultP 暴露默认 P 给测试断言。
func DefaultP() time.Duration { return Default().P.D() }

// TestFSMConfigProjection:配置正确投影为状态机参数。
func TestFSMConfigProjection(t *testing.T) {
	c := Default()
	c.TUp = Duration(30 * time.Second)
	c.N = 4
	fc := c.FSMConfig()
	if fc.TUp != 30*time.Second || fc.N != 4 {
		t.Fatalf("投影不符: %+v", fc)
	}
}

// TestLoadBadDuration:非法时长字符串应报错。
func TestLoadBadDuration(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "bad.yaml")
	if err := os.WriteFile(path, []byte("tUp: notaduration\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(path); err == nil {
		t.Fatalf("非法时长应报错")
	}
}
