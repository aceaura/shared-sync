#!/usr/bin/env bash
# client-entrypoint.sh —— Phase3 客户端容器入口。
#
# 起两件:
#   1. frpc(STCP visitor),本地暴露 127.0.0.1:<VISITOR_PORT>(= connd t2BackendAddr)。
#      作为 sidecar 常驻;connd 经 t2BackendAddr 把它纳入 T2(无需改 connd 逻辑)。
#   2. connd run,管 nebula 子进程 + 三层阶梯 + 固定本地端点代理。
#
# 之所以 frpc 作 sidecar 而非由 connd fork:Phase3 选「能稳定跑通 e2e」的方式;
# connd 已为「connd 启停 frpc」留了清晰接口(见 v2/connd 的 frpc supervisor + config),
# 生产可二选一。这里两者解耦,便于在 e2e 里单独对 frpc/UDP 做故障注入。
set -euo pipefail

VISITOR_PORT="${VISITOR_PORT:-18418}"

echo "[client] 启动 frpc(STCP visitor;本地 127.0.0.1:$VISITOR_PORT = connd t2BackendAddr)"
frpc -c /etc/frp/frpc-visitor.toml &
FRPC_PID=$!

# 等 visitor 本地端口起来(它要先连上 frps 才会 listen)。
for i in $(seq 1 20); do
  if nc -z 127.0.0.1 "$VISITOR_PORT" 2>/dev/null; then
    echo "[client] frpc visitor 本地端口 127.0.0.1:$VISITOR_PORT 就绪"
    break
  fi
  sleep 1
done

echo "[client] 启动 connd run(管 nebula + 三层阶梯 + 代理 127.0.0.1:8418)"
exec connd run -config /etc/nebula/connd.yaml
