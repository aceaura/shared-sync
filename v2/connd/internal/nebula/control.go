// control.go — nebula 控制通道客户端:通过内置 sshd 跑控制命令
// (主用 `list-hostmap -json`,见 Phase1b handoff)。
//
// connd 与 nebula 同机,sshd 仅监听 127.0.0.1:<port>(默认 2222)。connd 持有
// authorized_users 里登记的私钥,用一次性 ssh exec 跑命令。
//
// 取数据(exec ssh)与解析(hostmap.go)分离:Fetcher 是可注入的函数类型,
// 测试/无 nebula 环境可注入假实现;真实环境用 SSHControl。
package nebula

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
)

// Fetcher 取一次 `list-hostmap -json` 的原始输出。可注入(测试用假实现)。
type Fetcher interface {
	// FetchHostmap 返回 nebula 控制 sshd `list-hostmap -json` 的原始 JSON 字节。
	FetchHostmap(ctx context.Context) ([]byte, error)
}

// SSHControl 通过 ssh exec 到本机 nebula 控制 sshd 跑命令。
type SSHControl struct {
	// Host:sshd 监听地址(默认 127.0.0.1)。
	Host string
	// Port:sshd 端口(默认 2222)。
	Port int
	// User:authorized_users 里的用户名(默认 ctl)。
	User string
	// KeyPath:connd 持有的私钥路径(对应 sshd 登记的公钥)。
	KeyPath string
	// SSHBin:ssh 二进制(默认 "ssh",从 PATH 查找)。
	SSHBin string
}

// NewSSHControl 构造控制客户端,补默认值。
func NewSSHControl(host string, port int, user, keyPath string) *SSHControl {
	if host == "" {
		host = "127.0.0.1"
	}
	if port <= 0 {
		port = 2222
	}
	if user == "" {
		user = "ctl"
	}
	return &SSHControl{Host: host, Port: port, User: user, KeyPath: keyPath, SSHBin: "ssh"}
}

// args 组装 ssh 命令行(与 sim-vps lib.sh 的 ctl() 对齐)。
func (s *SSHControl) args(cmd ...string) []string {
	a := []string{
		"-p", strconv.Itoa(s.Port),
		"-o", "StrictHostKeyChecking=no",
		"-o", "UserKnownHostsFile=/dev/null",
		"-o", "ConnectTimeout=5",
		"-o", "LogLevel=ERROR",
		"-o", "BatchMode=yes",
	}
	if s.KeyPath != "" {
		a = append(a, "-i", s.KeyPath)
	}
	a = append(a, fmt.Sprintf("%s@%s", s.User, s.Host))
	a = append(a, cmd...)
	return a
}

// run 执行一条控制命令并返回 stdout。
func (s *SSHControl) run(ctx context.Context, cmd ...string) ([]byte, error) {
	bin := s.SSHBin
	if bin == "" {
		bin = "ssh"
	}
	c := exec.CommandContext(ctx, bin, s.args(cmd...)...)
	var out, errb bytes.Buffer
	c.Stdout = &out
	c.Stderr = &errb
	if err := c.Run(); err != nil {
		return nil, fmt.Errorf("nebula 控制命令失败 (%s): %w; stderr=%s",
			strings.Join(cmd, " "), err, strings.TrimSpace(errb.String()))
	}
	return out.Bytes(), nil
}

// FetchHostmap 实现 Fetcher:跑 `list-hostmap -json`。
func (s *SSHControl) FetchHostmap(ctx context.Context) ([]byte, error) {
	return s.run(ctx, "list-hostmap", "-json")
}

// FetchRelays 跑 `print-relays -json`(可观测中继负载,DESIGN_v2 §5「relay 容量意识」)。
func (s *SSHControl) FetchRelays(ctx context.Context) ([]byte, error) {
	return s.run(ctx, "print-relays", "-json")
}

// QueryHostmap 取 + 解析,对 peerOverlayIP 给出判定。便捷封装。
func QueryHostmap(ctx context.Context, f Fetcher, peerOverlayIP, lighthouseUnderlay string) (HostmapResult, error) {
	raw, err := f.FetchHostmap(ctx)
	if err != nil {
		return HostmapResult{}, err
	}
	return ParseHostmap(raw, peerOverlayIP, lighthouseUnderlay)
}

// FetcherFunc 把普通函数适配成 Fetcher(测试便利)。
type FetcherFunc func(ctx context.Context) ([]byte, error)

// FetchHostmap 实现 Fetcher。
func (fn FetcherFunc) FetchHostmap(ctx context.Context) ([]byte, error) { return fn(ctx) }
