// Package config 定义 connd 的配置(YAML)与加载/校验。
package config

import (
	"fmt"
	"net"
	"os"
	"strconv"
	"time"

	"github.com/aceaura/shared-sync/v2/connd/internal/ladder"
	"gopkg.in/yaml.v3"
)

// Config 是 connd 的完整配置。时长字段用 Go duration 字符串(如 "25s")。
type Config struct {
	// PeerOverlayIP:数据中心的 overlay 虚拟 IP(被探测/连接对象,如 10.77.0.2)。
	PeerOverlayIP string `yaml:"peerOverlayIP"`
	// DataCenterPort:数据中心 shared-sync 服务端口(overlay 内,默认 8418)。
	// T0/T1 上游 = PeerOverlayIP:DataCenterPort;心跳也打它。
	DataCenterPort int `yaml:"dataCenterPort"`

	// LighthouseUnderlay:lighthouse 的 underlay 地址(host 或 host:port)。
	// 用于 hostmap 判定时排除「currentRemote 指向 lighthouse」的情况(稳健性)。
	LighthouseUnderlay string `yaml:"lighthouseUnderlay"`

	// RelayUnderlayIP:relay 的 underlay/公网 IP(诊断/兼容旧字段)。
	RelayUnderlayIP string `yaml:"relayUnderlayIP"`
	// ProbePort:overlay 内探测端口(兼容旧字段;Phase2 心跳用 DataCenterPort)。
	ProbePort string `yaml:"probePort"`

	// LocalProxyAddr:connd 固定本地端点监听地址(引擎连它,DESIGN_v2 §2.1)。
	// 默认 127.0.0.1:8418。
	LocalProxyAddr string `yaml:"localProxyAddr"`

	// T2BackendAddr:T2(TCP 兜底)上游后端地址 = 本地 frpc 转发端口(Phase3 接入)。
	// 留空表示 T2 未接入(探测恒 DOWN,代理不会切到 T2)。
	T2BackendAddr string `yaml:"t2BackendAddr"`

	// Control:nebula 控制 sshd 连接参数(查 hostmap 用,DESIGN_v2 §5)。
	Control ControlConfig `yaml:"control"`

	// Nebula 子进程相关。
	Nebula NebulaConfig `yaml:"nebula"`

	// StatusAddr:本地状态 HTTP 监听地址(默认 127.0.0.1:4243)。
	StatusAddr string `yaml:"statusAddr"`

	// 阶梯状态机参数(DESIGN_v2.md §4)。
	TUp       Duration `yaml:"tUp"`       // 升级滞后窗口
	N         int      `yaml:"n"`         // 降级阈值(连续失败次数)
	P         Duration `yaml:"p"`         // 上层探测/重试周期
	Heartbeat Duration `yaml:"heartbeat"` // 心跳/探测间隔

	// ProbeTimeout:单次探测超时。
	ProbeTimeout Duration `yaml:"probeTimeout"`
}

// ControlConfig 是 nebula 控制 sshd 连接参数。
type ControlConfig struct {
	// Enabled:是否启用 hostmap 探测(查控制 sshd 判 direct/relay)。
	// 关闭时仅靠 overlay 心跳,保守归为 T1(无法判直连)。
	Enabled bool `yaml:"enabled"`
	// Host/Port:sshd 监听地址(默认 127.0.0.1:2222)。
	Host string `yaml:"host"`
	Port int    `yaml:"port"`
	// User:authorized_users 用户名(默认 ctl)。
	User string `yaml:"user"`
	// KeyPath:connd 持有的私钥路径(对应 sshd 登记的公钥)。
	KeyPath string `yaml:"keyPath"`
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
	dc := ladder.DefaultConfig()
	return Config{
		ProbePort:      "4242",
		DataCenterPort: 8418,
		LocalProxyAddr: "127.0.0.1:8418",
		StatusAddr:     "127.0.0.1:4243",
		TUp:            Duration(dc.TUp),
		N:              dc.N,
		P:              Duration(dc.P),
		Heartbeat:      Duration(dc.Heartbeat),
		ProbeTimeout:   Duration(2 * time.Second),
		Control: ControlConfig{
			Enabled: false,
			Host:    "127.0.0.1",
			Port:    2222,
			User:    "ctl",
		},
		Nebula: NebulaConfig{BinPath: "nebula"},
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
	if c.DataCenterPort <= 0 {
		c.DataCenterPort = d.DataCenterPort
	}
	if c.LocalProxyAddr == "" {
		c.LocalProxyAddr = d.LocalProxyAddr
	}
	if c.StatusAddr == "" {
		c.StatusAddr = d.StatusAddr
	}
	if c.Control.Host == "" {
		c.Control.Host = d.Control.Host
	}
	if c.Control.Port <= 0 {
		c.Control.Port = d.Control.Port
	}
	if c.Control.User == "" {
		c.Control.User = d.Control.User
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

// DataCenterAddr 返回数据中心 overlay 后端 "host:port"(T0/T1 上游 + 心跳目标)。
func (c Config) DataCenterAddr() string {
	return net.JoinHostPort(c.PeerOverlayIP, strconv.Itoa(c.DataCenterPort))
}

// LadderConfig 把配置投影成阶梯状态机参数(三层)。
func (c Config) LadderConfig() ladder.Config {
	return ladder.Config{
		NumTiers:  3,
		TUp:       c.TUp.D(),
		N:         c.N,
		P:         c.P.D(),
		Heartbeat: c.Heartbeat.D(),
	}
}
