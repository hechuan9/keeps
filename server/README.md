# Keeps Rust 服务

NAS 常驻服务使用 Rust、Axum 和 SQLite，负责资产查询、评分/标签/软回收站、目录追踪、增量扫描、EXIF、HEIC 预览及持久化任务。macOS/iOS 只调用业务 API。旧事件表保留为内部审计和历史迁移来源；客户端事件上传、心跳和预览上传路由已关闭。

```bash
cargo test --manifest-path server/Cargo.toml
cargo clippy --manifest-path server/Cargo.toml --all-targets -- -D warnings
docker build -f server/Dockerfile -t keeps-server:nas-core .
KEEPS_TEST_IMAGE=keeps-server:nas-core python3 server/tests/docker_smoke.py
KEEPS_TEST_IMAGE=keeps-server:nas-core python3 server/tests/mechanisms_smoke.py
KEEPS_TEST_IMAGE=keeps-server:nas-core python3 server/tests/task_scheduler_smoke.py
KEEPS_TEST_IMAGE=keeps-server:nas-core python3 server/tests/manual_full_scan_smoke.py
```

配置：

- `KEEPS_ROOT`：服务状态目录；`db/control_plane.sqlite` 保存资产，`db/jobs.sqlite` 保存扫描任务。
- `ORIGINAL_ROOT`：容器内已存在的原片根目录，与服务状态目录分离；显式导入需要目标目录可写，扫描继续只读原片。
- `CONTROL_PLANE_PUBLIC_BASE_URL`：客户端可达的服务地址。
- `KEEPS_ACCESS_TOKEN`：至少 32 字节的共享访问凭据。
- `CONTROL_PLANE_AUTO_CREATE_SCHEMA=1`：新空库初始化；现有库设 `0`，升级前备份并执行 `keeps-server migrate`。
- `KEEPS_LIBRARY_ID`：可选，首次启动时为该资料库追踪原片根目录；已停用目录不会因重启重新启用。
- `TZ`：无时区 EXIF 的解释时区，迁移时与旧客户端保持一致。
- `KEEPS_LISTEN_ADDR`：默认 `0.0.0.0:2283`。

业务 API 使用 Bearer token，预览下载 URL 有效期 15 分钟。共享令牌适用于受信任家庭资料库，不提供独立用户权限体系。

SQLite 使用 WAL。后台扫描只读原片，文件哈希或精确 JPEG 图像指纹可以自动归组；EXIF 匹配仅作为待视觉确认的候选。普通核对通过原片 size/mtime 与 XMP 状态签名跳过未变文件。文件事件精确入队，XMP 和导入仅核对当前目录层，目录结构变化才处理子树；不再定时全库扫描。全库扫描仅由用户手动触发；启动只建立监听，事件丢失/监听错误记录告警并要求手动补扫，启动时取消遗留自动全库任务，独立 worker 持久化扫描断点，精确任务优先，运行中再次变化不会被吞掉。默认版本切换会重建预览；版本及监听机制详见 [架构文档](../docs/ARCHITECTURE.md)。日常媒体解码在 NAS 原生套件执行；Linux 远端 worker 仅用于显式启用的一次性批量处理（`KEEPS_REMOTE_WORKER_ENABLED=1`，默认关闭）。解码依赖 ExifTool、LibRaw、ImageMagick 与 libheif；每个外部进程有时限和内存限制。错误保留完整上下文，单文件失败不阻止处理其他文件。

SIGTERM 停止领取任务并等待当前处理阶段结束。未完成的运行任务在下次启动恢复；停止追踪仅修改数据库。数据库和文件 I/O 在阻塞线程执行，查询接口不会承担媒体解码。元数据读取使用独立 WAL 快照；交互短事务优先于排队的后台事务，照片身份写入不占数据库锁。NAS 接口保持正常 CPU/I/O 优先级；扫描、编码、导入发布、移动、回收与离线导出使用独立低优先级线程，避免把优先级带入 HTTP 线程池。

部署路径、迁移备份和现场验证见 [NAS 部署说明](../deploy/nas/README.md)。同一资料库只能有一个服务进程管理。

版本机制需要 catalog schema 3，迁移只增加表，不回填或重组历史照片。升级前备份两个 SQLite 数据库。`mechanisms_smoke.py` 使用一次性 Linux Docker volume 和临时样本，不访问 NAS 照片；Docker Desktop 的宿主共享目录事件不等同于 NAS 本地文件系统，因此监听验收使用原生 Linux volume。

离线逐文件夹精确重复整理使用 [批量整理脚本](../docs/folder-merge.md)。镜像包含只读 NDJSON 媒体检查命令 `keeps-inspect`；新文件归组仅匹配同一直接父目录内的原片证据，已有路径关联保留。

## 显式删除 NAS 文件夹

`POST /libraries/{library}/directories/trash` 接收 `{path,confirmationName,requestID}`，`requestID` 必须为客户端持久化的 UUID，必须输入与目录名完全相同的确认文字。仅允许当前资料库追踪范围内的子目录；原片根、NAS 共享根、系统目录、符号链接和与其他资料库重叠的目录均拒绝。

服务读取 DSM `/etc/samba/smb.share.conf`，按最长匹配的共享路径确认 `enable recycle bin=yes`，随后通过参数数组调用 NAS 原生 `/usr/syno/bin/synorecycle --rmdir share=<共享名> rpath=<相对目录>`。回收位置、重名处理和删除时间记录由 DSM 管理；Keeps 不手工移动到 `#recycle`、不生成恢复记录，也不以 `rm` 或文件系统删除兜底。配置不可读、回收站未启用或原生程序不可用时明确失败。立即返回 `202` 任务对象 `{id,path,status,phase,error,createdAt,updatedAt,finishedAt}`（时间为 Unix 秒），不等待文件回收。`GET /libraries/{library}/directories/trash/{requestID}` 查询任务；未提交为 404。相同 ID 与参数重复提交返回原任务，参数不同或同一资料库已有其他删除任务为 409；缺少 ID 的旧客户端收到 422 升级提示。任务存于 `jobs.sqlite`，由进程级独立 worker 执行；状态查询使用独立连接，不等待目录执行锁或扫描事务。`status` 为 `pending/running/completed/failed`，真实阶段 `phase` 为 `waiting/recycling/reconciling/completed/failed`，没有推测百分比。客户端断连不取消操作。重启后 waiting 可执行，reconciling 继续对账；recycling 中断只检查原路径是否消失，已消失则继续对账，仍存在则对账并明确失败、提醒检查部分回收，绝不盲目重放原生回收。恢复使用 File Station 的标准回收站操作，保留期限由 NAS 设置决定。

扫描、身份核对与导入发布同目录移动互斥，原生删除后核对并移除已消失的原路径索引、更新修订并停用被移动的追踪根；没有其他可用原片路径的资产从普通列表和计数排除，按 ID 的资产历史保留，不加入 Keeps 软件回收站；仍有其他路径的资产保留。通过 File Station 恢复后重新扫描（若追踪根已停用则重新追踪）才恢复可用。原生程序失败也会核对已消失的路径，避免部分完成后索引不一致；错误提醒检查 NAS 回收站，不能将错误理解为文件均仍在原目录。此接口只支持可读取真实 DSM 共享配置的 NAS 原生部署；Docker 默认未挂载该配置时不可用。

## 显式回收所有弃用照片

`POST /libraries/{library}/rejected-trash/preview` 保存待确认清单，返回 `{id,count,status,phase,completedFiles,totalFiles,error,createdAt,updatedAt,finishedAt}`。按全库 `flag=rejected AND trashed=0` 且有原片路径的照片去重计数，包括隐藏目录；清单包含全部有效原片路径、关联版本及 XMP。未弃用照片共用的文件或 sidecar、跨图库和非追踪文件均拒绝。

`POST /libraries/{library}/rejected-trash/{id}` 接收 `{confirmationCount}`，必须与非零预览数量一致，并再次核对精确照片 ID、路径与文件身份；同一 ID 重复提交返回原任务，不重试失败任务。返回 202，由目录回收 worker 执行，`GET` 同路径查询。任务和逐文件进度存于 `jobs.sqlite`；实际执行前再核对清单与 DSM 回收配置，使用 `/usr/syno/bin/synorecycle --unlink share=<共享名> rpath=<相对文件>`，不存在永久删除降级路径。该参数已通过 DSM 7.3.2 的 `synorecycle --help` 只读核实。

执行与扫描、目录移动、照片标记修改及曝光提交互斥。中断的原生调用若原文件仍存在则停止并提示核实，不盲目重放；原文件消失则继续剩余清单。原生部分失败也会对账消失路径、更新图库修订与缓存；对账中断可重启继续。失败任务不自动重试，需检查 NAS 回收站后重新预览。照片历史保留，不转入 Keeps 软件回收站；恢复通过 File Station，随后扫描重新索引。客户端显示的照片数与实际文件数分别计量。

## Mac 显式导入

`POST /libraries/{library}/directories` 接收 `{parentPath,name}`，在当前资料库已追踪的父目录中创建单层子目录，返回 `201 {path}`。名称不能是隐藏或系统目录、多层路径或包含控制字符；重名返回 409，不覆盖现有文件或目录。

`POST /libraries/{library}/imports` 接收 `{id,targetPath,deduplicate,preserveStructure,workerID?,files:[{id,relativePath,size,sha256?}]}`。提供 `workerID` 时为该批次目标文件保存一小时计算租约；`POST /libraries/{library}/imports/{batch}/heartbeat` 接收 `{workerID}` 续期。有效租约阻止 NAS 对关联照片编码，到期后 NAS 接管缺失媒体。`POST /libraries/{library}/worker/claim` 接收 `{workerID,importID}`，仅领取归属该批次且租约有效的任务，无需开启全库远端 worker。Mac 上传 thumbnail、browse 及必要 standard 后提交 complete，NAS 校验来源与任务状态。`deduplicate` 默认 false，此时不要求源文件 SHA256，不按内容跳过文件。批次和文件 ID 为 UUID；提供 SHA256 时使用小写十六进制。目标必须是活跃追踪范围内的已存在目录；来源路径仅用于识别同源配对，所有文件平铺在目标目录。每批最多 10000 项，单文件 1 字节至 8 GiB。允许 RAW、HEIF/HEIC/HIF 及关联 XMP；不接受独立 XMP。响应包含每项 `fileName`、`uploaded`，以及批次 `finished`、`jobId`。

启用 `deduplicate` 时每项必须提供 SHA256；仅比较目标目录这一层已有文件，不比较画面相似度，也不处理来源批次内部的重复组。以内容一致的 RAW/HEIF 为配对依据；所有重叠配套文件都一致时跳过已有项并补齐缺失项，响应 `skipped:true`。已有 XMP 或其他配套文件冲突时整组另名。目标摘要计算不持有任务数据库锁，提交时再次验证跳过的文件。

服务端按来源父目录和不区分大小写的 stem 为 RAW/HEIF/XMP 分组。目标已有相同 stem（包括不同扩展）时，全组使用 `IMG (1)` 等共同后缀，保留配对。大小写不同的 XMP 以原片 stem 和扩展规范化命名。分配名称持久化在 jobs.sqlite，同一批次 ID 和 manifest 可重复提交恢复状态；不同批次即使内容相同也作为一次新导入。

`PUT /libraries/{library}/imports/{batch}/files/{file}` 流式上传二进制，不在内存保存完整文件。流式检查大小并计算接收摘要；如提供了源 SHA256 则额外比较。验证成功后保存到目标目录内隐藏的 `.keeps-import-*` 暂存文件，响应 `{uploaded:true}`。扫描和监听跳过暂存文件。单文件失败可以重新上传；成功项重试不会重复写入。

`POST /libraries/{library}/imports/{batch}/finish?async=true` 要求全部文件已上传，持久提交 NAS 后台收尾任务，立即返回 `{id,status,completedFiles,totalFiles,publicationComplete,indexedFiles,indexTotal,thumbnailTotal,thumbnailCompleted,error?,job?}`；`GET` 同一路径查询进度，服务重启后继续已提交任务。状态为 `uploading`、`publishing`、`indexing`、`thumbnails`、`failed` 或 `finished`，失败后可对同一批次重新提交。`finished` 要求索引任务完成且相关照片的两级缩略图版本正确并就绪；原片发布完成单独用 `publicationComplete` 表示。元数据进度按照片文件计数（不含 XMP），媒体进度按归组后的照片计数。后台先检查目标冲突，再以不覆盖的硬链接发布全部 XMP 和原片，分批持久保存进度，不在文件操作期间占用任务数据库锁；同组文件发布进度落盘后，索引器才可写入身份元数据。最后复用扫描队列处理身份、版本与预览。省略 `async=true` 时仍等待原片发布并返回 `{job:...}`，供已发布客户端使用。完成原片发布后移除的是隐藏暂存链接；现有原片、来源照片不删除、不移动、不覆盖。发布中失败可重试，已发布项保留；批次不是目录级原子事务。若准备之后目标出现外部同名文件，返回 409 并保留该文件。

批次及完成上传的暂存文件跨服务重启保留，首版没有自动过期或取消清理；未完成导入需要通过原批次继续。服务端必须运行在支持硬链接的本地 NAS 文件系统，部署及真实照片整理效果仍需 NAS 验收。

导入计算租约使用 catalog schema 13。升级 schema 12 前停止服务、备份 SQLite，再执行现有 `keeps-server migrate`；迁移只增加租约表及索引，不改照片文件。
