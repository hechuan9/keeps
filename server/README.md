# Keeps Rust 服务

NAS 常驻服务使用 Rust、Axum 和 SQLite，负责资产查询、评分/标签/软回收站、目录追踪、增量扫描、EXIF、HEIC 预览及持久化任务。macOS/iOS 只调用业务 API。旧事件表保留为内部审计和历史迁移来源；客户端事件上传、心跳和预览上传路由已关闭。

```bash
cargo test --manifest-path server/Cargo.toml
cargo clippy --manifest-path server/Cargo.toml --all-targets -- -D warnings
docker build -f server/Dockerfile -t keeps-server:spk .
python3 deploy/spk/export_runtime.py --image keeps-server:spk --output /tmp/keeps-native-payload
python3 deploy/spk/pack.py --payload /tmp/keeps-native-payload --output /tmp/KeepsNativeProbe.spk
```

配置：

- `KEEPS_ROOT`：服务状态目录；`db/control_plane.sqlite` 保存资产，`db/jobs.sqlite` 保存扫描任务。
- `ORIGINAL_ROOT`：NAS 上已存在的原片根目录，与服务状态目录分离；显式导入需要目标目录可写，扫描继续只读原片。
- `CONTROL_PLANE_PUBLIC_BASE_URL`：客户端可达的服务地址。
- `KEEPS_ACCESS_TOKEN`：至少 32 字节的共享访问凭据。
- `CONTROL_PLANE_AUTO_CREATE_SCHEMA=1`：新空库初始化；现有库设 `0`，升级前备份并执行 `keeps-server migrate`。
- `KEEPS_LIBRARY_ID`：可选，首次启动时为该资料库追踪原片根目录；已停用目录不会因重启重新启用。
- `TZ`：无时区 EXIF 的解释时区，迁移时与旧客户端保持一致。
- `KEEPS_LISTEN_ADDR`：默认 `0.0.0.0:2283`。

业务 API 使用 Bearer token，预览下载 URL 有效期 15 分钟。共享令牌适用于受信任家庭资料库，不提供独立用户权限体系。

`GET /libraries/{library}/assets/{asset}/versions/{hash}/playback` 返回 `{playbackURL,expiresAt}`（Unix 秒）；签名播放地址有效 24 小时，支持 GET/HEAD、单段 HTTP Range 和版本 hash ETag。每次读取重新核对版本所属资产、追踪状态和原文件身份，直接按请求范围流式读取原片，不生成完整下载副本。

`GET /libraries/{library}/tags` 返回 `{tags:[String]}` 标签库；`POST` 同路径接收 `{tags:[String]}` 添加并返回完整标签库，每次 1–100 个非空标签，每个不超过 128 字节。标签去除首尾空格并去重。schema 17 迁移回填已有照片标签，后续照片标签写入自动收录；从照片移除标签不删除库条目。沿用 Bearer 鉴权与已有备份、`keeps-server migrate` 升级流程。

SQLite 使用 WAL。后台扫描只读原片，文件哈希或精确 JPEG 图像指纹可以自动归组；EXIF 匹配仅作为待视觉确认的候选。普通核对通过原片 size/mtime 与 XMP 状态签名跳过未变文件。扫描仅由用户显式触发；添加目录只登记配置，启动、文件变化和后台维护均不发起扫描。启动取消历史非人工扫描，保留人工任务断点；外部新增、修改、删除和重命名需手动扫描同步。显式导入、移动、默认版本切换与重试继续完成各自必需的索引和预览处理；详见 [架构文档](../docs/ARCHITECTURE.md)。日常媒体解码在 NAS 原生套件执行；Linux 远端 worker 仅用于显式启用的一次性批量处理（`KEEPS_REMOTE_WORKER_ENABLED=1`，默认关闭）。解码依赖 ExifTool、LibRaw、ImageMagick 与 libheif；每个外部进程有时限和内存限制。错误保留完整上下文，单文件失败不阻止处理其他文件。

SIGTERM 停止领取任务并等待当前处理阶段结束。未完成的运行任务在下次启动恢复；停止追踪仅修改数据库。数据库和文件 I/O 在阻塞线程执行，查询接口不会承担媒体解码。元数据读取使用独立 WAL 快照；交互短事务优先于排队的后台事务，照片身份写入不占数据库锁。NAS 接口保持正常 CPU/I/O 优先级；扫描、编码、导入发布、移动、回收与离线导出使用独立低优先级线程，避免把优先级带入 HTTP 线程池。

NAS 唯一受支持的部署方式是原生 SPK；部署、升级、恢复和现场验收见 [套件说明](../deploy/spk/README.md)。旧 Docker Compose 部署已退役，不得用于启动 NAS 服务。同一资料库只能有一个服务进程管理。

版本机制需要 catalog schema 3，迁移只增加表，不回填或重组历史照片。升级前备份两个 SQLite 数据库。`mechanisms_smoke.py` 使用一次性 Linux Docker volume 和临时样本，不访问 NAS 照片；验收覆盖新增文件等待手动扫描、重启不自动补扫及显式扫描后的索引更新。Docker smoke 脚本仅用于隔离测试，不是 NAS 部署入口。

离线逐文件夹精确重复整理使用 [批量整理脚本](../docs/folder-merge.md)。镜像包含只读 NDJSON 媒体检查命令 `keeps-inspect`；新文件归组仅匹配同一直接父目录内的原片证据，已有路径关联保留。

## 显式删除 NAS 文件夹

`POST /libraries/{library}/directories/trash` 接收 `{path,confirmationName,requestID}`，`requestID` 必须为客户端持久化的 UUID，必须输入与目录名完全相同的确认文字。仅允许当前资料库追踪范围内的子目录；原片根、NAS 共享根、系统目录、符号链接和与其他资料库重叠的目录均拒绝。

服务读取 DSM `/etc/samba/smb.share.conf`，按最长匹配的共享路径确认 `enable recycle bin=yes`，随后通过参数数组调用 NAS 原生 `/usr/syno/bin/synorecycle --rmdir share=<共享名> rpath=<相对目录>`。回收位置、重名处理和删除时间记录由 DSM 管理；Keeps 不手工移动到 `#recycle`、不生成恢复记录，也不以 `rm` 或文件系统删除兜底。配置不可读、回收站未启用或原生程序不可用时明确失败。立即返回 `202` 任务对象 `{id,path,status,phase,error,createdAt,updatedAt,finishedAt}`（时间为 Unix 秒），不等待文件回收。`GET /libraries/{library}/directories/trash/{requestID}` 查询任务；未提交为 404。相同 ID 与参数重复提交返回原任务，参数不同或同一资料库已有其他删除任务为 409；缺少 ID 的旧客户端收到 422 升级提示。任务存于 `jobs.sqlite`，由进程级独立 worker 执行；状态查询使用独立连接，不等待目录执行锁或扫描事务。`status` 为 `pending/running/completed/failed`，真实阶段 `phase` 为 `waiting/recycling/reconciling/completed/failed`，没有推测百分比。客户端断连不取消操作。重启后 waiting 可执行，reconciling 继续对账；recycling 中断只检查原路径是否消失，已消失则继续对账，仍存在则对账并明确失败、提醒检查部分回收，绝不盲目重放原生回收。恢复使用 File Station 的标准回收站操作，保留期限由 NAS 设置决定。

扫描、身份核对与导入发布同目录移动互斥，原生删除后核对并移除已消失的原路径索引、更新修订并停用被移动的追踪根；没有其他可用原片路径的资产从普通列表和计数排除，按 ID 的资产历史保留，不加入 Keeps 软件回收站；仍有其他路径的资产保留。通过 File Station 恢复后重新扫描（若追踪根已停用则重新追踪）才恢复可用。原生程序失败也会核对已消失的路径，避免部分完成后索引不一致；错误提醒检查 NAS 回收站，不能将错误理解为文件均仍在原目录。此接口只支持可读取真实 DSM 共享配置的 NAS 原生部署；配置不可读时会明确失败。

## 显式回收所有弃用照片

`POST /libraries/{library}/rejected-trash/preview` 保存全库待删除的弃用照片清单，包括隐藏目录；`POST /libraries/{library}/rejected-trash/{id}` 接收 `{confirmationCount}`，数量须与非零预览相同。NAS 持久任务只将照片移入 Keeps 回收站，原片及关联文件保持原位。单张 `assets/{id}/trash` 与恢复使用相同的入站计时。

`POST /libraries/{library}/trash/preview` 预览 Keeps 回收站全量清单，`POST /libraries/{library}/trash/{id}` 以相同数量确认协议提交清空；`GET` 同路径查询。实际清空通过 DSM 原生 `/usr/syno/bin/synorecycle --unlink` 将所有有效原片版本和关联 XMP 移入 NAS 回收站，不永久删除、不使用文件操作兜底。提交和执行均复核照片状态、文件身份、追踪范围及共享文件归属；未进入 Keeps 回收站的照片共用文件会阻止回收。

`GET` / `PUT /libraries/{library}/trash/settings` 读取或保存 `{enabled,retentionDays}`。默认启用，保留 30 天，可设为 1–3650 天或关闭；从进入 Keeps 回收站起计时，恢复即取消计时，再入站重新计时。schema 16 迁移时已有回收站照片从迁移当天起计时。NAS 后台每小时检查到期清单，客户端关闭不影响执行；任务开始前再次检查当前保留期限和启用状态。

任务与逐文件断点保存在 `jobs.sqlite`，API 返回 `{id,count,status,phase,completedFiles,totalFiles,error,createdAt,updatedAt,finishedAt}`。回收与扫描、目录移动、照片状态修改及曝光提交互斥。中断原生调用不盲目重放；原文件消失则继续剩余清单。失败对账消失路径，未回收文件和照片资料保留；失败任务不重试，需核实 NAS 回收站后重新预览。全部文件确认回收后，清除照片图库资料及编辑记录，专属生成缓存进入现有安全 GC 队列；NAS 回收站恢复后需重新扫描索引。

## Mac 显式导入

`POST /libraries/{library}/directories` 接收 `{parentPath,name}`，在当前资料库已追踪的父目录中创建单层子目录，返回 `201 {path}`。名称不能是隐藏或系统目录、多层路径或包含控制字符；重名返回 409，不覆盖现有文件或目录。

`POST /libraries/{library}/imports` 接收 `{id,targetPath,deduplicate,preserveStructure,workerID?,files:[{id,relativePath,size,sha256?}]}`。提供 `workerID` 时为该批次目标文件保存一小时计算租约；`POST /libraries/{library}/imports/{batch}/heartbeat` 接收 `{workerID}` 续期。有效租约阻止 NAS 对关联照片编码，到期后 NAS 接管缺失媒体。`POST /libraries/{library}/worker/claim` 接收 `{workerID,importID}`，仅领取归属该批次且租约有效的任务，无需开启全库远端 worker。Mac 上传 thumbnail、browse 及必要 standard 后提交 complete，NAS 校验来源与任务状态。`deduplicate` 默认 false，此时不要求源文件 SHA256，不按内容跳过文件。批次和文件 ID 为 UUID；提供 SHA256 时使用小写十六进制。目标必须是活跃追踪范围内的已存在目录；来源路径仅用于识别同源配对，所有文件平铺在目标目录。每批最多 10000 项，单文件 1 字节至 8 GiB。允许 RAW、HEIF/HEIC/HIF 及关联 XMP；不接受独立 XMP。响应包含每项 `fileName`、`uploaded`，以及批次 `finished`、`jobId`。

开启 `deduplicate` 后，创建批次仅登记清单和暂定名称，不读取整批源文件或目标文件摘要。客户端按来源照片组逐组调用 `POST /libraries/{library}/imports/{batch}/files/{file}/match`，请求 `{files:[{id,relativePath,size,sha256}]}` 必须包含该组全部文件和 SHA256；响应沿用批次结构，`files` 仅包含该组的最终名称、`matched`、`skipped` 和上传状态。匹配结果持久化，断线后恢复同一批次；随后上传该组，再匹配下一组。只比较该组实际目标目录这一层的文件，保留目录结构时不跨目标子目录或扫描全库；不比较画面相似度。以内容一致的 RAW/JPEG/HEIF 为配对依据；所有重叠配套文件都一致时跳过已有项并补齐缺失项，响应 `skipped:true`。已有 XMP 或其他配套文件冲突时整组另名。目标摘要计算不持有任务数据库锁，提交时再次验证跳过的文件。

服务端按来源父目录和不区分大小写的 stem 为 RAW/HEIF/XMP 分组。目标已有相同 stem（包括不同扩展）时，全组使用 `IMG (1)` 等共同后缀，保留配对。大小写不同的 XMP 以原片 stem 和扩展规范化命名。分配名称持久化在 jobs.sqlite，同一批次 ID 和 manifest 可重复提交恢复状态；不同批次即使内容相同也作为一次新导入。

`PUT /libraries/{library}/imports/{batch}/files/{file}` 流式上传二进制，不在内存保存完整文件。流式检查大小并计算接收摘要；如提供了源 SHA256 则额外比较。验证成功后保存到目标目录内隐藏的 `.keeps-import-*` 暂存文件，响应 `{uploaded:true}`。扫描跳过暂存文件。单文件失败可以重新上传；成功项重试不会重复写入。

`POST /libraries/{library}/imports/{batch}/finish?async=true` 要求全部文件已上传，持久提交 NAS 后台收尾任务，立即返回 `{id,status,completedFiles,totalFiles,publicationComplete,indexedFiles,indexTotal,thumbnailTotal,thumbnailCompleted,error?,job?}`；`GET` 同一路径查询进度，服务重启后继续已提交任务。状态为 `uploading`、`publishing`、`indexing`、`thumbnails`、`failed` 或 `finished`，失败后可对同一批次重新提交。`finished` 要求索引任务完成且相关照片的两级缩略图版本正确并就绪；原片发布完成单独用 `publicationComplete` 表示。元数据进度按照片文件计数（不含 XMP），媒体进度按归组后的照片计数。后台先检查目标冲突，再以不覆盖的硬链接发布全部 XMP 和原片，分批持久保存进度，不在文件操作期间占用任务数据库锁；同组文件发布进度落盘后，索引器才可写入身份元数据。最后复用扫描队列处理身份、版本与预览。省略 `async=true` 时仍等待原片发布并返回 `{job:...}`，供已发布客户端使用。完成原片发布后移除的是隐藏暂存链接；现有原片、来源照片不删除、不移动、不覆盖。发布中失败可重试，已发布项保留；批次不是目录级原子事务。若准备之后目标出现外部同名文件，返回 409 并保留该文件。

批次及完成上传的暂存文件跨服务重启保留，首版没有自动过期或取消清理；未完成导入需要通过原批次继续。服务端必须运行在支持硬链接的本地 NAS 文件系统，部署及真实照片整理效果仍需 NAS 验收。

导入计算租约与既有编辑状态统一使用 catalog schema 15；该版本为跨目录 HEIF/3FR 匹配添加原始拍摄时间索引。升级旧 schema 前停止服务、备份 SQLite，再执行现有 `keeps-server migrate`；迁移保留既有编辑状态、配方、决定和展示对象，不改照片文件。


已发布调色历史通过 `GET /libraries/{library}/assets/{asset}/edit/versions` 查询；每项包含独立 `versionID`、`previousVersionID`、`sourceContentHash`、`available` 和带签名 URL 的可用媒体。`GET .../edit` 返回稳定 `rootID` 与 `currentVersionID`。照片 UUID 与文件摘要分离，替换或重置当前调色保留已发布历史，旧版本已丢失的媒体不会标为可用。

## 视频时长裁剪

`POST /libraries/{library}/assets/{asset}/video-trims` 接收 `{id,contentHash,startSeconds,endSeconds}`，返回 `202` 持久任务；同一 UUID 和参数幂等，参数冲突返回 409。同一原资产同时只能有一个活动裁剪。`GET .../video-trims/{id}` 查询 `{id,assetID,contentHash,startSeconds,endSeconds,status,error?,newAssetID?,outputPath?}`，状态依次为 `pending`、`processing`、`indexing`、`completed`，操作失败为 `failed`。客户端关闭不取消任务，NAS 重启后继续。

NAS 先用 ffprobe 校验实际时长，再以单线程 FFmpeg 重编码 H.264/AAC MP4，保留音频、应用视频旋转及可传递的容器元数据。同目录的新文件使用独立身份和 UUID 文件名，无覆盖发布并复用索引队列。新视频确认作为独立资产入库后才把原资产标为 Keeps 回收站；原文件不移动、不删除、不覆盖。失败保留原资产；若发布后索引失败，已生成的新文件保留并在任务中返回路径。SPK 运行时必须包含 ffmpeg、ffprobe 和现有 exiftool。
