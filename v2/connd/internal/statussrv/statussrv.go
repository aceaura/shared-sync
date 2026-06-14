// Package statussrv 暴露 connd 状态的本地 HTTP 端点。
//
// 默认监听 127.0.0.1:4243,GET /status 返回 JSON(controller.Status):
//
//	{tier, viaVps, peer, upstream, localEndpoint, rttMs, currentRemote,
//	 since, lastSwitch, tiersHealth, reconnecting, nebula, updatedAt,
//	 path, state}
//
// 仅绑本地回环,不对外。
package statussrv

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"time"

	"github.com/aceaura/shared-sync/v2/connd/internal/controller"
)

// StatusProvider 提供当前状态快照(由 controller 实现)。
type StatusProvider interface {
	Status() controller.Status
}

// Server 包装 http.Server。
type Server struct {
	addr string
	srv  *http.Server
	ln   net.Listener
}

// New 构造状态服务器。addr 为空用 127.0.0.1:4243。
func New(addr string, p StatusProvider) *Server {
	if addr == "" {
		addr = "127.0.0.1:4243"
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/status", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		enc := json.NewEncoder(w)
		enc.SetIndent("", "  ")
		_ = enc.Encode(p.Status())
	})
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok\n"))
	})
	return &Server{
		addr: addr,
		srv: &http.Server{
			Handler:           mux,
			ReadHeaderTimeout: 5 * time.Second,
		},
	}
}

// Start 开始监听(非阻塞)。返回后即可接受请求;监听错误通过 channel 返回。
func (s *Server) Start() (<-chan error, error) {
	ln, err := net.Listen("tcp", s.addr)
	if err != nil {
		return nil, err
	}
	s.ln = ln
	errc := make(chan error, 1)
	go func() {
		errc <- s.srv.Serve(ln)
	}()
	return errc, nil
}

// Addr 返回实际监听地址(便于 :0 随机端口测试)。
func (s *Server) Addr() string {
	if s.ln != nil {
		return s.ln.Addr().String()
	}
	return s.addr
}

// Shutdown 优雅关闭。
func (s *Server) Shutdown(ctx context.Context) error {
	return s.srv.Shutdown(ctx)
}
