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

// TestLadderConfigProjection:配置正确投影为阶梯状态机参数(三层)。
func TestLadderConfigProjection(t *testing.T) {
	c := Default()
	c.TUp = Duration(30 * time.Second)
	c.N = 4
	lc := c.LadderConfig()
	if lc.TUp != 30*time.Second || lc.N != 4 || lc.NumTiers != 3 {
		t.Fatalf("投影不符: %+v", lc)
	}
}

// TestDataCenterAddr:数据中心后端地址组装正确。
func TestDataCenterAddr(t *testing.T) {
	c := Default()
	c.PeerOverlayIP = "10.77.0.2"
	c.DataCenterPort = 8418
	if got := c.DataCenterAddr(); got != "10.77.0.2:8418" {
		t.Fatalf("DataCenterAddr 不符: %q", got)
	}
}

// TestLoadPhase2Fields:Phase2 新增字段能从 YAML 加载。
func TestLoadPhase2Fields(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "p2.yaml")
	content := `
peerOverlayIP: 10.77.0.2
dataCenterPort: 8418
localProxyAddr: 127.0.0.1:8418
t2BackendAddr: 127.0.0.1:18418
lighthouseUnderlay: 54.198.93.78:4242
control:
  enabled: true
  port: 2222
  keyPath: /etc/connd/ctl_key
`
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	c, err := Load(path)
	if err != nil {
		t.Fatalf("加载失败: %v", err)
	}
	if c.LocalProxyAddr != "127.0.0.1:8418" {
		t.Fatalf("localProxyAddr 不符: %q", c.LocalProxyAddr)
	}
	if c.T2BackendAddr != "127.0.0.1:18418" {
		t.Fatalf("t2BackendAddr 不符: %q", c.T2BackendAddr)
	}
	if !c.Control.Enabled || c.Control.Port != 2222 || c.Control.KeyPath != "/etc/connd/ctl_key" {
		t.Fatalf("control 不符: %+v", c.Control)
	}
	if c.Control.User != "ctl" { // 未给取默认
		t.Fatalf("control.user 应默认 ctl,实际 %q", c.Control.User)
	}
	if c.DataCenterAddr() != "10.77.0.2:8418" {
		t.Fatalf("DataCenterAddr 不符: %q", c.DataCenterAddr())
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
