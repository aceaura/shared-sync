// Command connd 是 shared-sync v2 的连接管理 sidecar。
//
// 子命令:
//
//	connd run    [-config FILE]                启动:管 nebula 子进程 + 跑状态机 + 起状态 HTTP 端点
//	connd status [-addr 127.0.0.1:4243] [-json] 查询本地 connd 的当前连接状态
//	connd version                               打印版本
//
// 详见 v2/connd/README.md。
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/aceaura/shared-sync/v2/connd/internal/config"
	"github.com/aceaura/shared-sync/v2/connd/internal/controller"
	"github.com/aceaura/shared-sync/v2/connd/internal/nebula"
	"github.com/aceaura/shared-sync/v2/connd/internal/prober"
	"github.com/aceaura/shared-sync/v2/connd/internal/statussrv"
)

// version 由构建时 -ldflags 注入;默认 dev。
var version = "dev"

func main() {
	log.SetFlags(log.LstdFlags | log.Lmsgprefix)
	log.SetPrefix("")

	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	switch os.Args[1] {
	case "run":
		os.Exit(cmdRun(os.Args[2:]))
	case "status":
		os.Exit(cmdStatus(os.Args[2:]))
	case "version", "-v", "--version":
		fmt.Printf("connd %s\n", version)
	case "help", "-h", "--help":
		usage()
	default:
		fmt.Fprintf(os.Stderr, "未知子命令: %s\n\n", os.Args[1])
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Fprint(os.Stderr, `connd —— shared-sync v2 连接管理 sidecar

用法:
  connd run    [-config FILE]                  启动控制循环(管 nebula + 状态机 + 状态端点)
  connd status [-addr 127.0.0.1:4243] [-json]  查询本地 connd 当前连接状态
  connd version                                打印版本

run 的 -config 指向 YAML 配置(见 README)。未提供时使用内置默认 + DryRun nebula。
`)
}

func cmdRun(args []string) int {
	fs := flag.NewFlagSet("run", flag.ExitOnError)
	cfgPath := fs.String("config", "", "YAML 配置文件路径(留空用默认值,nebula 走 DryRun)")
	_ = fs.Parse(args)

	var cfg config.Config
	if *cfgPath != "" {
		c, err := config.Load(*cfgPath)
		if err != nil {
			log.Printf("connd: %v", err)
			return 1
		}
		cfg = c
	} else {
		cfg = config.Default()
		cfg.Nebula.DryRun = true // 无配置时不真正起 nebula,便于本地跑通链路
		log.Printf("connd: 未指定 -config,使用默认配置 + nebula DryRun")
	}

	// 探测器:Phase0 占位 nebula 探测器。peer 为空则退化为始终 DOWN 的探测(仍可跑)。
	p := prober.NewNebulaProber(cfg.PeerOverlayIP, cfg.ProbePort, cfg.RelayUnderlayIP, cfg.ProbeTimeout.D())

	neb := nebula.NewManager(nebula.Options{
		BinPath:    cfg.Nebula.BinPath,
		ConfigPath: cfg.Nebula.ConfigPath,
		DryRun:     cfg.Nebula.DryRun,
		Stdout:     os.Stdout,
		Stderr:     os.Stderr,
	})

	ctrl := controller.New(cfg.FSMConfig(), p, neb, cfg.ProbeTimeout.D(), nil)

	srv := statussrv.New(cfg.StatusAddr, ctrl)
	srvErr, err := srv.Start()
	if err != nil {
		log.Printf("connd: 状态端点监听失败 %s: %v", cfg.StatusAddr, err)
		return 1
	}
	log.Printf("connd: 状态端点 http://%s/status", srv.Addr())

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	runErr := make(chan error, 1)
	go func() { runErr <- ctrl.Run(ctx) }()

	log.Printf("connd %s: 控制循环启动(peer=%q heartbeat=%s T_up=%s N=%d P=%s)",
		version, cfg.PeerOverlayIP, cfg.Heartbeat.D(), cfg.TUp.D(), cfg.N, cfg.P.D())

	select {
	case <-ctx.Done():
		log.Printf("connd: 收到退出信号,正在关闭...")
	case err := <-srvErr:
		if err != nil && err != http.ErrServerClosed {
			log.Printf("connd: 状态端点异常退出: %v", err)
		}
	case err := <-runErr:
		if err != nil && err != context.Canceled {
			log.Printf("connd: 控制循环异常退出: %v", err)
		}
	}

	shutCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutCtx)
	return 0
}

func cmdStatus(args []string) int {
	fs := flag.NewFlagSet("status", flag.ExitOnError)
	addr := fs.String("addr", "127.0.0.1:4243", "connd 状态端点地址")
	asJSON := fs.Bool("json", false, "原样打印 JSON")
	_ = fs.Parse(args)

	url := fmt.Sprintf("http://%s/status", *addr)
	client := &http.Client{Timeout: 3 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		fmt.Fprintf(os.Stderr, "connd: 无法连接 %s: %v\n(connd run 是否在运行?)\n", url, err)
		return 1
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		fmt.Fprintf(os.Stderr, "connd: 状态端点返回 %d: %s\n", resp.StatusCode, string(body))
		return 1
	}

	if *asJSON {
		fmt.Println(string(body))
		return 0
	}

	var st controller.Status
	if err := json.Unmarshal(body, &st); err != nil {
		fmt.Fprintf(os.Stderr, "connd: 解析状态失败: %v\n原始: %s\n", err, string(body))
		return 1
	}
	printStatus(st)
	return 0
}

func printStatus(st controller.Status) {
	fmt.Printf("状态机   : %s\n", st.State)
	fmt.Printf("当前路径 : %s\n", st.Path)
	fmt.Printf("对端     : %s\n", emptyDash(st.Peer))
	fmt.Printf("RTT      : %.1f ms\n", st.RTTMs)
	fmt.Printf("Nebula   : %s\n", st.Nebula)
	fmt.Printf("保持自   : %s\n", fmtTime(st.Since))
	fmt.Printf("上次切换 : %s\n", fmtTime(st.LastSwitch))
	fmt.Printf("更新于   : %s\n", fmtTime(st.UpdatedAt))
}

func emptyDash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}

func fmtTime(t time.Time) string {
	if t.IsZero() {
		return "-"
	}
	return t.Format(time.RFC3339)
}
