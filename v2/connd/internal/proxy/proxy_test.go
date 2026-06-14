package proxy

import (
	"bufio"
	"context"
	"fmt"
	"net"
	"sync"
	"testing"
	"time"
)

// echoBackend 起一个本地 TCP 后端:对每行输入回 "<tag>:<line>"。
// 返回监听地址与关闭函数。
func echoBackend(t *testing.T, tag string) (string, func()) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("起后端失败: %v", err)
	}
	var wg sync.WaitGroup
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			wg.Add(1)
			go func(c net.Conn) {
				defer wg.Done()
				defer c.Close()
				sc := bufio.NewScanner(c)
				for sc.Scan() {
					fmt.Fprintf(c, "%s:%s\n", tag, sc.Text())
				}
			}(c)
		}
	}()
	return ln.Addr().String(), func() { _ = ln.Close(); wg.Wait() }
}

// roundtrip 通过代理发一行,读一行回应。
func roundtrip(t *testing.T, proxyAddr, line string) string {
	t.Helper()
	c, err := net.DialTimeout("tcp", proxyAddr, 2*time.Second)
	if err != nil {
		t.Fatalf("连代理失败: %v", err)
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(2 * time.Second))
	fmt.Fprintf(c, "%s\n", line)
	sc := bufio.NewScanner(c)
	if !sc.Scan() {
		t.Fatalf("代理无回应: %v", sc.Err())
	}
	return sc.Text()
}

// startProxy 起代理并等待监听就绪。
func startProxy(t *testing.T, upstream string) (*Proxy, func()) {
	t.Helper()
	p := New("127.0.0.1:0", time.Second)
	if upstream != "" {
		p.SetUpstream(upstream)
	}
	ctx, cancel := context.WithCancel(context.Background())
	ready := make(chan struct{})
	go func() {
		// 先 Listen 再进 Accept;用一个临时 listener 探测端口已就绪不可行,
		// 这里改为:Start 内部已先 Listen,我们轮询 Addr 直到非 :0。
		_ = p.Start(ctx)
	}()
	// 等待 Addr 就绪。
	for i := 0; i < 200; i++ {
		if a := p.Addr(); a != "127.0.0.1:0" && a != "" {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	close(ready)
	<-ready
	return p, func() { cancel(); _ = p.Close() }
}

// TestProxyForwards:代理把连接转发到上游后端。
func TestProxyForwards(t *testing.T) {
	backAddr, stopBack := echoBackend(t, "A")
	defer stopBack()

	p, stop := startProxy(t, backAddr)
	defer stop()

	got := roundtrip(t, p.Addr(), "hello")
	if got != "A:hello" {
		t.Fatalf("应转发到后端 A,实际回应 %q", got)
	}
	if p.Accepted() < 1 {
		t.Fatalf("应记录已接受连接")
	}
}

// TestProxySwitchUpstream:切上游后,新连接走新后端(原子切换)。
func TestProxySwitchUpstream(t *testing.T) {
	addrA, stopA := echoBackend(t, "A")
	defer stopA()
	addrB, stopB := echoBackend(t, "B")
	defer stopB()

	p, stop := startProxy(t, addrA)
	defer stop()

	if got := roundtrip(t, p.Addr(), "x"); got != "A:x" {
		t.Fatalf("切换前应走 A,实际 %q", got)
	}

	// 原子切上游到 B。
	p.SetUpstream(addrB)
	if got := roundtrip(t, p.Addr(), "y"); got != "B:y" {
		t.Fatalf("切换后新连接应走 B,实际 %q", got)
	}
	if p.Switches() < 1 {
		t.Fatalf("应记录切上游次数")
	}
}

// TestProxyNoUpstreamRejects:无上游(RECONNECTING)时新连接被立即关闭。
func TestProxyNoUpstreamRejects(t *testing.T) {
	p, stop := startProxy(t, "") // 不设上游
	defer stop()

	c, err := net.DialTimeout("tcp", p.Addr(), time.Second)
	if err != nil {
		t.Fatalf("连代理失败: %v", err)
	}
	defer c.Close()
	_ = c.SetReadDeadline(time.Now().Add(time.Second))
	buf := make([]byte, 16)
	// 无上游:代理应直接关闭连接,读到 EOF(n==0,err!=nil)。
	n, err := c.Read(buf)
	if n != 0 || err == nil {
		t.Fatalf("无上游时连接应被关闭,实际 n=%d err=%v", n, err)
	}
}

// TestProxyExistingConnUnaffectedBySwitch:切上游不影响已建立的连接(走旧上游直到结束)。
func TestProxyExistingConnUnaffectedBySwitch(t *testing.T) {
	addrA, stopA := echoBackend(t, "A")
	defer stopA()
	addrB, stopB := echoBackend(t, "B")
	defer stopB()

	p, stop := startProxy(t, addrA)
	defer stop()

	// 建立一条长连接,先发一行确认走 A。
	c, err := net.DialTimeout("tcp", p.Addr(), time.Second)
	if err != nil {
		t.Fatalf("连代理失败: %v", err)
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(2 * time.Second))
	sc := bufio.NewScanner(c)
	fmt.Fprintf(c, "one\n")
	if !sc.Scan() || sc.Text() != "A:one" {
		t.Fatalf("旧连接首行应走 A,实际 %q", sc.Text())
	}

	// 切上游到 B。
	p.SetUpstream(addrB)

	// 同一条旧连接继续发:仍走 A(连接已绑定旧上游)。
	fmt.Fprintf(c, "two\n")
	if !sc.Scan() || sc.Text() != "A:two" {
		t.Fatalf("切上游后旧连接仍应走 A,实际 %q", sc.Text())
	}

	// 新连接走 B。
	if got := roundtrip(t, p.Addr(), "three"); got != "B:three" {
		t.Fatalf("新连接应走 B,实际 %q", got)
	}
}

// TestProxyUpstreamGetterSetter:Upstream/SetUpstream 基本语义。
func TestProxyUpstreamGetterSetter(t *testing.T) {
	p := New("127.0.0.1:0", time.Second)
	if p.Upstream() != "" {
		t.Fatalf("初始上游应为空")
	}
	p.SetUpstream("10.0.0.1:8418")
	if p.Upstream() != "10.0.0.1:8418" {
		t.Fatalf("SetUpstream 未生效")
	}
	// 相同地址不增加切换计数。
	before := p.Switches()
	p.SetUpstream("10.0.0.1:8418")
	if p.Switches() != before {
		t.Fatalf("相同上游不应计为切换")
	}
}
