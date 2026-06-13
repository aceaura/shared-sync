package statussrv

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"testing"
	"time"

	"github.com/aceaura/shared-sync/v2/connd/internal/controller"
)

type fakeProvider struct{ st controller.Status }

func (f fakeProvider) Status() controller.Status { return f.st }

// TestStatusEndpoint:GET /status 返回 JSON,字段含 path/peer/rttMs/lastSwitch。
func TestStatusEndpoint(t *testing.T) {
	want := controller.Status{
		Path: "DIRECT", State: "DIRECT", Peer: "10.77.0.3",
		RTTMs: 12.5, Since: time.Unix(2_000_000, 0), LastSwitch: time.Unix(2_000_000, 0),
		Nebula: "RUNNING",
	}
	srv := New("127.0.0.1:0", fakeProvider{st: want})
	errc, err := srv.Start()
	if err != nil {
		t.Fatalf("启动失败: %v", err)
	}
	defer func() {
		_ = srv.Shutdown(context.Background())
		<-errc
	}()

	resp, err := http.Get("http://" + srv.Addr() + "/status")
	if err != nil {
		t.Fatalf("GET 失败: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("状态码应 200,实际 %d", resp.StatusCode)
	}
	body, _ := io.ReadAll(resp.Body)

	var got controller.Status
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("解析 JSON 失败: %v\n%s", err, string(body))
	}
	if got.Path != "DIRECT" || got.Peer != "10.77.0.3" || got.RTTMs != 12.5 {
		t.Fatalf("字段不符: %+v", got)
	}
	if !got.LastSwitch.Equal(want.LastSwitch) {
		t.Fatalf("lastSwitch 不符: %v vs %v", got.LastSwitch, want.LastSwitch)
	}
}

// TestStatusMethodNotAllowed:非 GET 应 405。
func TestStatusMethodNotAllowed(t *testing.T) {
	srv := New("127.0.0.1:0", fakeProvider{})
	errc, err := srv.Start()
	if err != nil {
		t.Fatalf("启动失败: %v", err)
	}
	defer func() {
		_ = srv.Shutdown(context.Background())
		<-errc
	}()

	resp, err := http.Post("http://"+srv.Addr()+"/status", "application/json", nil)
	if err != nil {
		t.Fatalf("POST 失败: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("非 GET 应 405,实际 %d", resp.StatusCode)
	}
}
