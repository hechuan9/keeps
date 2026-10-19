# Synology 原生套件

Keeps 在 NAS 原生运行，这是唯一受支持的 NAS 服务部署方式。Docker 不用于部署 NAS 服务；仓库中的 Docker 流程只构建 SPK 运行时、运行隔离测试或执行明确安排的一次性 Linux worker。旧 NAS Docker Compose 方案已退役，不得重新启用。当前支持 DS1520+ 的 geminilake 架构及 DSM 7；尚未取得 Synology 官方套件审核。

## 构建与安装

```sh
docker build -f server/Dockerfile -t keeps-server:spk .
python3 deploy/spk/export_runtime.py --image keeps-server:spk --output /tmp/keeps-native-payload
python3 deploy/spk/pack.py --payload /tmp/keeps-native-payload --output /tmp/KeepsNativeProbe.spk
python3 -m unittest discover -s deploy/spk -p 'test_*.py'
```

在 NAS 管理员终端使用 `synopkg install <绝对路径.spk>` 安装，`synopkg start KeepsNativeProbe` / `synopkg stop KeepsNativeProbe` 启停。状态使用 `sudo synopkg status KeepsNativeProbe` 查询；普通 SSH 账号无法正确查询套件用户服务，可能误报停止。套件以 DSM 创建的专用账号运行，不绑 CPU 核心，使用 `Nice=10` 和 best-effort I/O 优先级 7，空闲时可使用可用 CPU，争用时让出资源。没有整个套件的 2 GiB 硬内存上限，媒体子进程另有地址空间和超时限制；编码并发仍受后台任务配置约束。

运行时使用私有动态加载器，不全局设置 `LD_LIBRARY_PATH`。导出器针对 Debian trixie、Perl 5.40、ImageMagick 7 的布局；随包保留依赖版权资料。

## 配置

配置位于 `/var/packages/KeepsNativeProbe/var/`，由套件账号持有，权限 0600；升级保留已有配置。

- `original-root`：原片目录的绝对路径。
- `server-url`：客户端可达的服务地址，也用于签名预览链接。
- `access-token`：随机访问令牌，不提交 Git。
- `server-overrides`：启动脚本白名单内的逐行 `KEY=value`，不执行 shell 文本。

正式资料库为 `local-library`，局域网地址 `http://192.168.0.50:2283`，原片 `/volume2/photo`，状态 `/volume2/@appdata/KeepsNativeProbe/production-state`。新安装的原型默认使用独立测试共享目录、`spk-probe` 和 2285，不能将其当作正式配置。

日常本地编码开启（`KEEPS_LOCAL_CACHE_ENCODING_ENABLED=1`），远端派发关闭（`KEEPS_REMOTE_WORKER_ENABLED=0`）。Linux 仅用于显式安排的[一次性批量处理](../linux-worker/README.md)。

## 升级与恢复

1. 暂停独立维护进程，停止服务；使用 SQLite backup API 一致备份状态目录的 `db/control_plane.sqlite`、`db/jobs.sqlite`，检查备份，并保留当前套件与配置。
2. 安装新包，保留 library ID、token、原片和状态路径。禁止同时启动两个写入同一状态目录的服务。 若 schema 升级，安装后保持停服，以套件账号设置当前 KEEPS_ROOT 并执行 target/bin/keeps-server migrate；确认迁移成功后再启动，不依赖生产配置自动迁移。
3. 启动后核对 `/healthz`、鉴权、资产计数、缩略图下载及后台状态，再恢复维护进程。可用性与全库处理完成是两回事。
4. 回退前另存最新数据库。使用与数据库 schema 匹配的套件和配置；恢复旧数据库会丢失备份之后的整理修改，不能直接覆盖最新状态。

长期备份使用 Hyper Backup 的应用备份，选择 `Keeps Native Probe`。备份目标、计划和版本保留由 Hyper Backup 任务管理；套件通过 `scripts/backup` 导出双库、四个配置文件及存在时的 `maintenance` 状态，不包含原片或可重建预览。原片共享文件夹须单独纳入任务。备份期间需要停服以保证双库一致，导出会校验 SQLite 完整性并生成校验和；临时目录应位于数据卷，不能使用空间有限的 DSM 系统分区。

当前 NAS 使用独立的 `Keeps` Hyper Backup 任务，目标为 S3 `chuan.backup/keeps-native`，每天 NAS 时间（America/Los_Angeles）01:00 运行，智能保留最多 256 个版本。原片由原有 `Amazon S3` 任务备份；两者分开调度，避免应用状态备份排在大批照片传输之后。

恢复只写 Keeps 状态和配置，保留当前 `KEEPS_ROOT`，恢复前状态保存在该目录的 `backups/restore-before-*`。恢复后须核对服务健康、资料库及整理数据。尚未完成 Hyper Backup 备份和恢复验证前，不删除旧数据库备份。

`/volume2/docker/keeps/releases/` 是历史部署目录，不作为长期备份位置；其中还混有 RAW、照片和修复前副本，禁止整目录删除。旧 Docker 服务 `keeps-control-plane` 已退役并保持停止；它保存的是迁移时点的旧状态，不能启动、恢复或替代当前服务。NAS 服务只能通过本说明中的 SPK 流程部署。原片始终保留原位，不参与套件清理。

接口线程保持正常 CPU/I/O 优先级，扫描、编码、导入发布、移动、回收及离线导出在线程级使用 `Nice=10` 和 best-effort I/O 优先级 7，避免整个套件降级拖慢元数据同步。
