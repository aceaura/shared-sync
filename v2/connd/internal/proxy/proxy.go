// Package proxy 实现 connd 的「固定本地端点」TCP 代理(DESIGN_v2.md §2.1)。
//
// connd 在 127.0.0.1:<本地端口>(默认 8418)起一个 TCP 代理,把每条进来的连接
// 转发到「当前激活层」对应的数据中心后端上游。shared-sync 引擎只连这个固定端点
// (server_url=http://127.0.0.1:8418/...),永远不变;切层时 connd 只是原子地把
// 上游目标换到新层后端。
//
// 关键语义:
//   - 上游地址用 atomic.Pointer 保存,切层 = 原子换指针。**新连接走新上游;
//     已建立的旧连接保持连到旧上游直到自然结束**(允许旧连接断开重连)——
//     这对应 §2.1「切换瞬间最多一次 TCP 连接重置」,引擎每周期幂等+重试,无损。
//   - 上游为空(""):RECONNECTING 态,拒绝新连接(让引擎本轮重试,不空转)。
//
// 代理本身只搬字节,不解析协议(git over HTTP / smart HTTP 都透明转发)。
package proxy

import (
	"context"
	"errors"
	"io"
	"log"
	"net"
	"sync"
	"sync/atomic"
	"time"
)

// Proxy 是固定本地端点 TCP 代理。
type Proxy struct {
	// listenAddr:本地监听地址(如 127.0.0.1:8418)。
	listenAddr string
	// upstream:当前上游 "host:port";空串表示无可用上游(RECONNECTING)。
	upstream atomic.Pointer[string]
	// dialTimeout:连上游的拨号超时。
	dialTimeout time.Duration

	ln net.Listener

	mu       sync.Mutex
	closed   bool
	conns    map[*proxyConn]struct{} // 在途连接,Close 时一并关闭
	switches atomic.Int64            // 切上游次数(诊断)
	accepted atomic.Int64            // 累计接受连接数(诊断)
}

type proxyConn struct {
	client net.Conn
}

// New 构造代理。listenAddr 为空用 127.0.0.1:8418;dialTimeout<=0 用 5s。
func New(listenAddr string, dialTimeout time.Duration) *Proxy {
	if listenAddr == "" {
		listenAddr = "127.0.0.1:8418"
	}
	if dialTimeout <= 0 {
		dialTimeout = 5 * time.Second
	}
	p := &Proxy{
		listenAddr:  listenAddr,
		dialTimeout: dialTimeout,
		conns:       make(map[*proxyConn]struct{}),
	}
	empty := ""
	p.upstream.Store(&empty)
	return p
}

// SetUpstream 原子切换上游目标。addr 为 "host:port";空串表示无上游(拒绝新连接)。
// 只影响**新**连接;已建立的连接不受影响(允许其自然结束/由引擎重试)。
func (p *Proxy) SetUpstream(addr string) {
	old := p.Upstream()
	if old == addr {
		return
	}
	a := addr
	p.upstream.Store(&a)
	p.switches.Add(1)
	log.Printf("connd/proxy: 上游切换 %q → %q", dash(old), dash(addr))
}

// Upstream 返回当前上游地址(可能为空串)。
func (p *Proxy) Upstream() string {
	if v := p.upstream.Load(); v != nil {
		return *v
	}
	return ""
}

// Switches 返回累计切上游次数(诊断)。
func (p *Proxy) Switches() int64 { return p.switches.Load() }

// Accepted 返回累计接受连接数(诊断)。
func (p *Proxy) Accepted() int64 { return p.accepted.Load() }

// Addr 返回实际监听地址(便于 :0 随机端口测试)。
func (p *Proxy) Addr() string {
	if p.ln != nil {
		return p.ln.Addr().String()
	}
	return p.listenAddr
}

// Start 开始监听(阻塞接受循环,直到 ctx 取消或 Close)。
// 通常由调用方在 goroutine 里跑。返回时监听已关闭。
func (p *Proxy) Start(ctx context.Context) error {
	ln, err := net.Listen("tcp", p.listenAddr)
	if err != nil {
		return err
	}
	p.ln = ln

	// ctx 取消时关闭监听,解除 Accept 阻塞。
	go func() {
		<-ctx.Done()
		_ = p.Close()
	}()

	for {
		conn, err := ln.Accept()
		if err != nil {
			p.mu.Lock()
			closed := p.closed
			p.mu.Unlock()
			if closed || errors.Is(err, net.ErrClosed) {
				return nil
			}
			// 瞬时错误:稍歇再继续。
			log.Printf("connd/proxy: accept 错误: %v", err)
			time.Sleep(20 * time.Millisecond)
			continue
		}
		p.accepted.Add(1)
		go p.handle(conn)
	}
}

// handle 处理一条客户端连接:拨当前上游,双向拷贝。
func (p *Proxy) handle(client net.Conn) {
	pc := &proxyConn{client: client}
	p.track(pc)
	defer func() {
		p.untrack(pc)
		_ = client.Close()
	}()

	up := p.Upstream()
	if up == "" {
		// 无上游(RECONNECTING):直接关闭,让引擎本轮重试。
		return
	}

	d := net.Dialer{Timeout: p.dialTimeout}
	server, err := d.Dial("tcp", up)
	if err != nil {
		log.Printf("connd/proxy: 连上游 %s 失败: %v", up, err)
		return
	}
	defer func() { _ = server.Close() }()

	// 双向拷贝;任一方向结束即收尾(半关另一方向以尽快释放)。
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		_, _ = io.Copy(server, client)
		halfClose(server)
	}()
	go func() {
		defer wg.Done()
		_, _ = io.Copy(client, server)
		halfClose(client)
	}()
	wg.Wait()
}

// halfClose 尽力对支持的连接做写半关(CloseWrite),促使对端读到 EOF。
func halfClose(c net.Conn) {
	if cw, ok := c.(interface{ CloseWrite() error }); ok {
		_ = cw.CloseWrite()
	}
}

func (p *Proxy) track(pc *proxyConn) {
	p.mu.Lock()
	if !p.closed {
		p.conns[pc] = struct{}{}
	}
	p.mu.Unlock()
}

func (p *Proxy) untrack(pc *proxyConn) {
	p.mu.Lock()
	delete(p.conns, pc)
	p.mu.Unlock()
}

// Close 关闭监听与所有在途连接。幂等。
func (p *Proxy) Close() error {
	p.mu.Lock()
	if p.closed {
		p.mu.Unlock()
		return nil
	}
	p.closed = true
	conns := make([]*proxyConn, 0, len(p.conns))
	for pc := range p.conns {
		conns = append(conns, pc)
	}
	p.conns = make(map[*proxyConn]struct{})
	ln := p.ln
	p.mu.Unlock()

	for _, pc := range conns {
		_ = pc.client.Close()
	}
	if ln != nil {
		return ln.Close()
	}
	return nil
}

func dash(s string) string {
	if s == "" {
		return "(none)"
	}
	return s
}
