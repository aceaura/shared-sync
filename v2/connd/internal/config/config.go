// Package config 定义 connd 的配置(YAML)与加载/校验。
package config

import (
	"fmt"
	"os"
	"time"

	"github.com/aceaura/shared-sync/v2/connd/internal/fsm"
	"gopkg.in/yaml.v3"
)

// Config 是 connd 的完整配置。时长字段用 Go duration 字符串(如 "25s")。
type Config struct {
	// PeerOverlayIP:对端的 overlay 虚拟 IP(被探测对象)。
	PeerOverlayIP string `yaml:"peerOverlayIP"`
	// RelayUnderlayIP:relay 的 underlay/公网 IP(将来用于判定路径是否经中继)。
	RelayUnderlayIP string `yaml:"relayUnderlayIP"`
	// ProbePort:overlay 内探测端口(占位)。
	ProbePort string `yaml:"probePort"`

	// Nebula 子进程相关。
	Nebula NebulaConfig `yaml:"nebula"`

	// StatusAddr:本地状态 HTTP 监听地址(默认 127.0.0.1:4243)。
	StatusAddr string `yaml:"statusAddr"`

	// 状态机参数(DESIGN_v2.md §4)。
	TUp       Duration `yaml:"tUp"`       // 升级滞后窗口
	N         int      `yaml:"n"`         // 降级阈值(连续失败次数)
	P         Duration `yaml:"p"`         // 打洞重试周期
	Heartbeat Duration `yaml:"heartbeat"` // 心跳/探测间隔

	// ProbeTimeout:单次探测超时。
	ProbeTimeout Duration `yaml:"probeTimeout"`
}

// NebulaConfig 是 nebula 子进程配置。
type NebulaConfig struct {
	BinPath    string `yaml:"binPath"`    // nebula 二进制(默认 "nebula")
	ConfigPath string `yaml:"configPath"` // 传给 nebula 的 -config
	DryRun     bool   `yaml:"dryRun"`     // 不真正 exec(无 nebula 环境/CI)
}

// Duration 是支持 YAML 字符串("25s")解析的 time.Duration 包装。
type Duration time.Duration

func (d *Duration) UnmarshalYAML(value *yaml.Node) error {
	var s string
	if err := value.Decode(&s); err != nil {
		return err
	}
	if s == "" {
		*d = 0
		return nil
	}
	parsed, err := time.ParseDuration(s)
	if err != nil {
		return fmt.Errorf("非法时长 %q: %w", s, err)
	}
	*d = Duration(parsed)
	return nil
}

func (d Duration) D() time.Duration { return time.Duration(d) }

// Default 返回带合理默认值的配置(DESIGN_v2.md §4 建议值)。
func Default() Config {
	dc := fsm.DefaultConfig()
	return Config{
		ProbePort:    "4242",
		StatusAddr:   "127.0.0.1:4243",
		TUp:          Duration(dc.TUp),
		N:            dc.N,
		P:            Duration(dc.P),
		Heartbeat:    Duration(dc.Heartbeat),
		ProbeTimeout: Duration(2 * time.Second),
		Nebula:       NebulaConfig{BinPath: "nebula"},
	}
}

// Load 读取 YAML 文件并叠加到默认值之上;未提供的字段保留默认。
func Load(path string) (Config, error) {
	c := Default()
	raw, err := os.ReadFile(path)
	if err != nil {
		return c, fmt.Errorf("读取配置 %s 失败: %w", path, err)
	}
	if err := yaml.Unmarshal(raw, &c); err != nil {
		return c, fmt.Errorf("解析配置 %s 失败: %w", path, err)
	}
	c.applyDefaults()
	return c, nil
}

// applyDefaults 对零值字段回填默认。
func (c *Config) applyDefaults() {
	d := Default()
	if c.ProbePort == "" {
		c.ProbePort = d.ProbePort
	}
	if c.StatusAddr == "" {
		c.StatusAddr = d.StatusAddr
	}
	if c.Nebula.BinPath == "" {
		c.Nebula.BinPath = d.Nebula.BinPath
	}
	if c.TUp <= 0 {
		c.TUp = d.TUp
	}
	if c.N <= 0 {
		c.N = d.N
	}
	if c.P <= 0 {
		c.P = d.P
	}
	if c.Heartbeat <= 0 {
		c.Heartbeat = d.Heartbeat
	}
	if c.ProbeTimeout <= 0 {
		c.ProbeTimeout = d.ProbeTimeout
	}
}

// FSMConfig 把配置投影成状态机参数。
func (c Config) FSMConfig() fsm.Config {
	return fsm.Config{
		TUp:       c.TUp.D(),
		N:         c.N,
		P:         c.P.D(),
		Heartbeat: c.Heartbeat.D(),
	}
}
