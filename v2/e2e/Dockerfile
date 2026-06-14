# =============================================================================
# v2/e2e/Dockerfile —— Phase5 e2e 自洽世界镜像(--privileged 跑)
#
# 把整套 netns 实验台 + 真 connd + 真 nebula/frpc/frps + git 打进一个 Linux 镜像,
# 便于在 macOS(Docker)或将来 CI 上一键复现,无需污染宿主网络。
#
# 构建上下文由 run-in-docker.sh 准备(把以下二进制/源拷进 build dir):
#   bin/nebula bin/nebula-cert  —— 从 nebulaoss/nebula 镜像提取(ELF,linux)
#   bin/frpc bin/frps           —— 从 frp release tar 提取(linux)
#   bin/connd                   —— GOOS=linux 交叉编译 v2/connd
#   lib.sh run.sh               —— e2e 脚本
# =============================================================================
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        iproute2 iptables conntrack python3 git \
        openssh-client procps iputils-ping tcpdump ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# 用 legacy iptables(netns 内 nat/DNAT 行为与 sim-vps 一致,避免 nft 后端差异)。
RUN update-alternatives --set iptables /usr/sbin/iptables-legacy 2>/dev/null || true

COPY bin/nebula      /usr/local/bin/nebula
COPY bin/nebula-cert /usr/local/bin/nebula-cert
COPY bin/frpc        /usr/local/bin/frpc
COPY bin/frps        /usr/local/bin/frps
COPY bin/connd       /usr/local/bin/connd
RUN chmod +x /usr/local/bin/nebula /usr/local/bin/nebula-cert \
             /usr/local/bin/frpc /usr/local/bin/frps /usr/local/bin/connd

WORKDIR /e2e
COPY lib.sh run.sh /e2e/

ENTRYPOINT ["bash", "/e2e/run.sh"]
