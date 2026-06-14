// hostmap.go — 解析 nebula 控制 sshd 的 `list-hostmap -json` 输出,程序式判定
// 某个 peer 当前走 DIRECT(T0)还是 RELAY(T1)。
//
// 这是 Phase1b 沉淀的权威判定法(见 v2/sim-vps/README.md「如何判定 direct vs relay」):
//
//   - Nebula 1.10 的 SIGUSR1 不再打印 hostmap,**不要用**。改用官方控制通道:
//     内置 sshd,跑 `list-hostmap -json` 拿结构化 per-peer underlay 状态。
//   - 权威字段是 `currentRemote`:nebula 当前实际把加密包发往的 underlay socket。
//   - 判定规则:
//   - currentRemote 非空 且 ≠ lighthouse 的 underlay 地址 → DIRECT(T0)
//   - currentRemote 为空,但 currentRelaysToMe 非空           → RELAY(T1)
//   - peer 不在 hostmap / 两者皆空                            → UNKNOWN(未建链)
//   - 陷阱:`currentRelaysToMe` 非空 ≠ 正在走中继(direct 收敛后仍保留备用 relay
//     登记)。一律以 currentRemote 为准。
//
// 本文件只做**纯解析**(无网络);取数据(ssh exec)在 control.go。这样解析逻辑
// 可被确定性单测(hostmap_test.go),无需真 nebula。
package nebula

import (
	"encoding/json"
	"fmt"
	"net"
	"strings"
)

// PeerPath 是对某 peer underlay 路径的判定结果。
type PeerPath int

const (
	// PeerUnknown:peer 不在 hostmap,或 currentRemote 与 relay 入口皆空(未建链)。
	PeerUnknown PeerPath = iota
	// PeerRelay:currentRemote 为空但有 relay 入口 —— 数据经中继(T1)。
	PeerRelay
	// PeerDirect:currentRemote 非空且非 lighthouse 地址 —— 打洞直连(T0)。
	PeerDirect
)

func (p PeerPath) String() string {
	switch p {
	case PeerDirect:
		return "DIRECT"
	case PeerRelay:
		return "RELAY"
	default:
		return "UNKNOWN"
	}
}

// hostmapEntry 是 `list-hostmap -json` 数组里的一个 peer 条目(只取我们关心的字段)。
type hostmapEntry struct {
	VPNAddrs          []string `json:"vpnAddrs"`
	RemoteAddrs       []string `json:"remoteAddrs"`
	CurrentRemote     string   `json:"currentRemote"`
	CurrentRelaysToMe []string `json:"currentRelaysToMe"`
	MessageCounter    int64    `json:"messageCounter"`
}

// HostmapResult 是对单个 peer 的完整判定(供 prober/诊断使用)。
type HostmapResult struct {
	Path PeerPath
	// CurrentRemote:权威字段,nebula 当前发包的 underlay 端点(DIRECT 时非空)。
	CurrentRemote string
	// Relays:currentRelaysToMe(备用/在用中继入口);RELAY 判定的依据。
	Relays []string
	// MessageCounter:活跃度(持续增长=链路在用),供诊断。
	MessageCounter int64
	// Found:peer 是否出现在 hostmap 中。
	Found bool
}

// ParseHostmap 解析 `list-hostmap -json` 的原始字节,对指定 peerOverlayIP 判定路径。
//
// lighthouseUnderlay 是 lighthouse 的 underlay 地址(host 或 host:port),用于排除
// 「currentRemote 恰好指向 lighthouse」的情况(那不是真正的直连数据中心,虽然实践中
// 数据中心 peer 的 currentRemote 几乎不会是 lighthouse;此处仅为稳健)。传空则不排除。
func ParseHostmap(raw []byte, peerOverlayIP, lighthouseUnderlay string) (HostmapResult, error) {
	var entries []hostmapEntry
	if err := json.Unmarshal(raw, &entries); err != nil {
		return HostmapResult{}, fmt.Errorf("解析 hostmap JSON 失败: %w", err)
	}
	for _, e := range entries {
		if !containsAddr(e.VPNAddrs, peerOverlayIP) {
			continue
		}
		res := HostmapResult{
			Found:          true,
			CurrentRemote:  e.CurrentRemote,
			Relays:         e.CurrentRelaysToMe,
			MessageCounter: e.MessageCounter,
		}
		cr := strings.TrimSpace(e.CurrentRemote)
		switch {
		case cr != "" && !sameUnderlayHost(cr, lighthouseUnderlay):
			res.Path = PeerDirect
		case cr != "" && sameUnderlayHost(cr, lighthouseUnderlay):
			// currentRemote 指向 lighthouse:把它当作经 VPS 的中继路径(非直连)。
			res.Path = PeerRelay
		case len(e.CurrentRelaysToMe) > 0:
			res.Path = PeerRelay
		default:
			res.Path = PeerUnknown
		}
		return res, nil
	}
	// peer 不在 hostmap:未建链。
	return HostmapResult{Found: false, Path: PeerUnknown}, nil
}

// containsAddr 判断 addrs 是否包含 want(忽略大小写/空白)。
func containsAddr(addrs []string, want string) bool {
	want = strings.TrimSpace(want)
	for _, a := range addrs {
		if strings.TrimSpace(a) == want {
			return true
		}
	}
	return false
}

// sameUnderlayHost 判断 remote(host 或 host:port)与 ref(host 或 host:port)的 host 是否相同。
// ref 为空返回 false(不排除)。
func sameUnderlayHost(remote, ref string) bool {
	ref = strings.TrimSpace(ref)
	if ref == "" {
		return false
	}
	return hostOnly(remote) == hostOnly(ref)
}

// hostOnly 从 "host:port" 或 "host" 中取 host 部分。
func hostOnly(s string) string {
	s = strings.TrimSpace(s)
	if h, _, err := net.SplitHostPort(s); err == nil {
		return h
	}
	return s
}
