# shared-sync 服务端

基于 `alpine + nginx + fcgiwrap + git-http-backend` 的 Git smart HTTP 服务端,
只暴露单一权威快照分支 `refs/heads/current`,支持历史压缩与垃圾回收。

## 快速开始

```bash
cd server
docker compose up -d --build
```

- 服务地址:`http://<主机>:8418/shared.git`
- 数据保存在 named volume `git-data`(挂载到容器内 `/srv/git`),删除容器不丢数据。
- 首次启动自动初始化 bare 仓库 `/srv/git/shared.git`,并设置:
  - `receive.denyNonFastForwards=true`(禁止非快进 push / force push)
  - `receive.denyDeletes=true`(禁止删除引用)
  - `http.receivepack=true`(允许 HTTP push)
  - 安装 `pre-receive` 钩子(见下)
  - 仓库 `HEAD` 指向 `refs/heads/current`(clone 空仓库时默认分支即 current)

入口脚本幂等:每次容器启动都会校正以上配置与钩子,可放心重启/升级镜像。

## 认证

环境变量 `GIT_AUTH_USER` 与 `GIT_AUTH_PASSWORD` **均非空**时启用 HTTP Basic Auth:

```bash
GIT_AUTH_USER=sync GIT_AUTH_PASSWORD=secret docker compose up -d
# 客户端 URL 写法:http://sync:secret@host:8418/shared.git
```

两者任一为空则匿名读写(仅建议在可信局域网使用)。修改账号后重启容器生效。

## push 限制(pre-receive 钩子)

- 存在 `/srv/git/maintenance.lock`(维护窗口)→ 拒绝**所有** push;
- 只允许更新 `refs/heads/current`,其他分支/tag 一律拒绝;
- 拒绝删除引用;
- 非快进 push 由 `receive.denyNonFastForwards` 拒绝;
- 每次 push 尝试(时间、ref、old→new)追加记录到 `/srv/git/server.log`。

## 历史压缩

```bash
docker exec shared-sync-server compress.sh            # 默认 /srv/git/shared.git
```

流程(全程日志写入 `/srv/git/server.log`):

1. 原子创建 `/srv/git/maintenance.lock`(已存在则放弃),期间客户端 push 全部被拒;
2. 记录压缩前 `current` 的 commit 与 tree;
3. `commit-tree` 生成**同树**的新根提交(无任何父提交);
4. `update-ref refs/heads/current <new> <old>` 带旧值原子更新;
5. 自校验新旧 tree 完全一致,不一致则原子回滚并报错退出;
6. 新 commit id 写入 `/srv/git/snapshot-id`;
7. 删除 maintenance.lock。

压缩只重写历史、不改变文件内容;客户端检测到 `lastSyncedCommit` 不再是远端
祖先后走保护性重建流程(见 DESIGN.md §2 第 3 步)。

> 若压缩任务异常中断,maintenance.lock 由脚本的 EXIT trap 清理;若机器整体
> 崩溃留下残锁,容器启动时会在日志中告警,确认无压缩任务后手动删除:
> `docker exec shared-sync-server rm /srv/git/maintenance.lock`

## 垃圾回收

```bash
docker exec shared-sync-server gc.sh                       # 宽限期默认 24 小时
docker exec shared-sync-server gc.sh /srv/git/shared.git 48
```

执行 `reflog expire --expire=now --all` + `git gc --aggressive --prune="<N> hours ago"`,
并把前后 `du -sh` 仓库体积写入 `/srv/git/server.log`。宽限期保护正在 fetch
旧对象的客户端,建议压缩后等待宽限期再 GC(需求 §15)。

## 日志与运维

```bash
docker exec shared-sync-server cat /srv/git/server.log    # push/压缩/GC 记录
docker logs shared-sync-server                            # nginx 访问与错误日志
```

| 路径(容器内) | 说明 |
|---|---|
| `/srv/git/shared.git` | bare 仓库(权威数据) |
| `/srv/git/server.log` | push 记录、压缩起止、current 更新、GC 结果与体积变化 |
| `/srv/git/snapshot-id` | 最近一次压缩生成的根提交 id |
| `/srv/git/maintenance.lock` | 维护窗口标记,存在期间拒绝所有 push |

仓库文件属主为容器内 `git` 用户(fcgiwrap 运行身份)。`compress.sh`/`gc.sh`
以 root 执行时会自动降权到仓库属主,不会留下 root 属主文件;入口脚本每次
启动也会 `chown -R` 兜底修复。

## 备份

直接备份 volume 即可:

```bash
docker run --rm -v git-data:/srv/git -v "$PWD":/backup alpine \
    tar czf /backup/shared-git-backup.tgz -C /srv git
```
