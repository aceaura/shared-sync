package nebula

import (
	"context"
	"errors"
	"testing"
)

// 真实 list-hostmap -json 样例(取自 Phase1b 实测,见 sim-vps/README.md)。
// peer 10.88.0.3,DIRECT:currentRemote 是 peer 的 NAT 公网映射,无关 lighthouse。
const directJSON = `[
  {
    "vpnAddrs": ["10.88.0.3"],
    "remoteAddrs": ["100.64.0.20:4242", "10.10.2.2:4242"],
    "currentRemote": "100.64.0.20:4242",
    "currentRelaysToMe": [],
    "messageCounter": 21
  }
]`

// RELAY:currentRemote 空,只有 relay 入口。
const relayJSON = `[
  {
    "vpnAddrs": ["10.88.0.3"],
    "remoteAddrs": ["100.64.0.20:4242"],
    "currentRemote": "",
    "currentRelaysToMe": ["10.88.0.1"],
    "messageCounter": 5
  }
]`

// 陷阱场景:direct 收敛后仍保留备用 relay 登记。currentRemote 非空 → 必须判 DIRECT。
const directWithStaleRelayJSON = `[
  {
    "vpnAddrs": ["10.88.0.3"],
    "remoteAddrs": ["100.64.0.20:4242"],
    "currentRemote": "100.64.0.20:4242",
    "currentRelaysToMe": ["10.88.0.1"],
    "messageCounter": 206
  }
]`

func TestParseHostmapDirect(t *testing.T) {
	r, err := ParseHostmap([]byte(directJSON), "10.88.0.3", "100.64.0.1:4242")
	if err != nil {
		t.Fatal(err)
	}
	if !r.Found || r.Path != PeerDirect {
		t.Fatalf("应判 DIRECT,实际 found=%v path=%v", r.Found, r.Path)
	}
	if r.CurrentRemote != "100.64.0.20:4242" {
		t.Fatalf("currentRemote 不符: %q", r.CurrentRemote)
	}
	if r.MessageCounter != 21 {
		t.Fatalf("messageCounter 不符: %d", r.MessageCounter)
	}
}

func TestParseHostmapRelay(t *testing.T) {
	r, err := ParseHostmap([]byte(relayJSON), "10.88.0.3", "100.64.0.1:4242")
	if err != nil {
		t.Fatal(err)
	}
	if !r.Found || r.Path != PeerRelay {
		t.Fatalf("应判 RELAY,实际 found=%v path=%v", r.Found, r.Path)
	}
	if len(r.Relays) != 1 || r.Relays[0] != "10.88.0.1" {
		t.Fatalf("relays 不符: %v", r.Relays)
	}
}

// 关键:currentRelaysToMe 非空但 currentRemote 非空 → DIRECT(陷阱 1)。
func TestParseHostmapDirectWithStaleRelay(t *testing.T) {
	r, err := ParseHostmap([]byte(directWithStaleRelayJSON), "10.88.0.3", "")
	if err != nil {
		t.Fatal(err)
	}
	if r.Path != PeerDirect {
		t.Fatalf("currentRemote 非空时即使有 relay 登记也应判 DIRECT,实际 %v", r.Path)
	}
}

// currentRemote 恰好指向 lighthouse → 当作 RELAY(经 VPS)。
func TestParseHostmapCurrentRemoteIsLighthouse(t *testing.T) {
	j := `[{"vpnAddrs":["10.88.0.3"],"currentRemote":"100.64.0.1:4242","currentRelaysToMe":["10.88.0.1"]}]`
	r, err := ParseHostmap([]byte(j), "10.88.0.3", "100.64.0.1:4242")
	if err != nil {
		t.Fatal(err)
	}
	if r.Path != PeerRelay {
		t.Fatalf("currentRemote 指向 lighthouse 应判 RELAY,实际 %v", r.Path)
	}
}

func TestParseHostmapPeerAbsent(t *testing.T) {
	r, err := ParseHostmap([]byte(directJSON), "10.88.0.99", "")
	if err != nil {
		t.Fatal(err)
	}
	if r.Found || r.Path != PeerUnknown {
		t.Fatalf("peer 不在 hostmap 应 UNKNOWN/not found,实际 found=%v path=%v", r.Found, r.Path)
	}
}

func TestParseHostmapEmptyArray(t *testing.T) {
	r, err := ParseHostmap([]byte(`[]`), "10.88.0.3", "")
	if err != nil {
		t.Fatal(err)
	}
	if r.Found {
		t.Fatalf("空 hostmap 不应 found")
	}
}

func TestParseHostmapBothEmpty(t *testing.T) {
	j := `[{"vpnAddrs":["10.88.0.3"],"currentRemote":"","currentRelaysToMe":[]}]`
	r, err := ParseHostmap([]byte(j), "10.88.0.3", "")
	if err != nil {
		t.Fatal(err)
	}
	if r.Path != PeerUnknown {
		t.Fatalf("两者皆空应 UNKNOWN,实际 %v", r.Path)
	}
}

func TestParseHostmapBadJSON(t *testing.T) {
	if _, err := ParseHostmap([]byte(`not json`), "10.88.0.3", ""); err == nil {
		t.Fatalf("非法 JSON 应报错")
	}
}

func TestQueryHostmapViaFetcher(t *testing.T) {
	f := FetcherFunc(func(ctx context.Context) ([]byte, error) { return []byte(directJSON), nil })
	r, err := QueryHostmap(context.Background(), f, "10.88.0.3", "100.64.0.1:4242")
	if err != nil {
		t.Fatal(err)
	}
	if r.Path != PeerDirect {
		t.Fatalf("应 DIRECT,实际 %v", r.Path)
	}
}

func TestQueryHostmapFetchErr(t *testing.T) {
	f := FetcherFunc(func(ctx context.Context) ([]byte, error) { return nil, errors.New("ssh failed") })
	if _, err := QueryHostmap(context.Background(), f, "10.88.0.3", ""); err == nil {
		t.Fatalf("fetch 失败应传播错误")
	}
}

func TestPeerPathString(t *testing.T) {
	if PeerDirect.String() != "DIRECT" || PeerRelay.String() != "RELAY" || PeerUnknown.String() != "UNKNOWN" {
		t.Fatalf("PeerPath.String 不符")
	}
}
