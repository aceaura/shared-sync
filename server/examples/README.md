# 前置反向代理示例

把 shared-sync 服务端(容器默认监听 `8418`,根路径提供 Git Smart HTTP)放到一层
外部 nginx 后面,用于 HTTPS 终止、域名、按路径分流多个服务。

通讯协议是 **Git Smart HTTP**(普通 HTTP/1.1,跑在 TCP 上),因此任何 HTTP 反向代理
(nginx / Caddy / Traefik)都能代理。

## 示例

| 文件 | 用途 | 客户端地址 |
|---|---|---|
| [nginx-tls-frontend.conf](nginx-tls-frontend.conf) | 根路径 + HTTPS 终止 | `https://sync.example.com/shared.git` |
| [nginx-subpath.conf](nginx-subpath.conf) | 子路径分流(同域名多服务) | `https://example.com/sync/shared.git` |

## 四条通用铁律(代理 Git over HTTP 必看)

1. **`client_max_body_size 0;`** —— git push 的 pack 可能很大,默认 1MB 会让 push 报 413 失败。
2. **`proxy_request_buffering off;` + `proxy_http_version 1.1;`** —— 支持 git 的流式/分块传输。
3. **透传 `Authorization` 头** —— 容器启用了 `GIT_AUTH_USER`/`GIT_AUTH_PASSWORD` 时,
   `proxy_set_header Authorization $http_authorization;` 不可少。
   (也可改为在前置 nginx 用 `auth_basic` 接管认证,容器内保持匿名。)
4. **超时给足** —— `proxy_read_timeout 600s;`,大仓库 clone/push 不被中途掐断。

## 子路径部署的关键

`git-http-backend` 用 `GIT_PROJECT_ROOT` + `PATH_INFO` 定位仓库,**转发到容器的路径里
绝不能带路由前缀**,否则会去找 `/srv/git/sync/shared.git` 而 404。

- 子路径方案(nginx-subpath.conf)靠 `proxy_pass http://127.0.0.1:8418/;` **末尾的 `/`**
  把 `/sync/` 前缀剥掉后再转发,容器配置无需改动。
- 若想让容器自身就挂在子路径下,则改容器内 `nginx.conf.template` 的 `location` 正则,
  把前缀从 `PATH_INFO` 中摘掉(`fastcgi_param PATH_INFO /$1;`)。一般不需要,优先用前置剥前缀。
