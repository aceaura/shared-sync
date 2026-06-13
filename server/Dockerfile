# shared-sync 服务端镜像:nginx + fcgiwrap + git-http-backend(smart HTTP)
FROM alpine:3.22

# git-daemon 提供 /usr/libexec/git-core/git-http-backend
# gettext 提供 envsubst;su-exec 用于维护脚本以 root 身份执行时降权到仓库属主
RUN apk add --no-cache \
        bash \
        git \
        git-daemon \
        nginx \
        fcgiwrap \
        spawn-fcgi \
        apache2-utils \
        gettext \
        su-exec \
    && adduser -D -s /sbin/nologin git \
    # 容器内 root 与 git 用户都会操作 /srv/git 下的仓库,放开属主校验
    && git config --system safe.directory '*' \
    # compress.sh 的 commit-tree 需要提交者身份
    && git config --system user.name 'shared-sync-server' \
    && git config --system user.email 'server@shared-sync.invalid'

COPY hooks/pre-receive /opt/shared-sync/hooks/pre-receive
COPY scripts/compress.sh scripts/gc.sh /opt/shared-sync/scripts/
COPY nginx.conf.template /opt/shared-sync/nginx.conf.template
COPY entrypoint.sh /opt/shared-sync/entrypoint.sh

RUN chmod 0755 /opt/shared-sync/entrypoint.sh \
               /opt/shared-sync/hooks/pre-receive \
               /opt/shared-sync/scripts/compress.sh \
               /opt/shared-sync/scripts/gc.sh \
    && ln -s /opt/shared-sync/scripts/compress.sh /usr/local/bin/compress.sh \
    && ln -s /opt/shared-sync/scripts/gc.sh /usr/local/bin/gc.sh

EXPOSE 80
VOLUME /srv/git

ENTRYPOINT ["/opt/shared-sync/entrypoint.sh"]
