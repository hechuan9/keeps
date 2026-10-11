# Keeps macOS

Keeps 是 NAS 照片服务的原生 SwiftUI 客户端。NAS 承担照片扫描、权威索引和元数据修改；macOS 执行导入批次的媒体计算及用户发起的无损曝光调整，持久保存尚未完成的任务。普通后台预览由 NAS 生成，导入批次的 Mac 计算租约过期后也由 NAS 接管。

在 Keeps → 设置（⌘,）的 Server 页面填写 Keeps Server 的 HTTP/HTTPS 地址、资料库名称和服务访问令牌。通过服务器鉴权和资料库查询验证后才保存并切换连接；失败时保留原来的连接。地址与资料库保留在 UserDefaults，凭据保存在 Keychain；旧连接偏好会自动迁移。NAS 不可用时显示请求错误，不切换本地数据库。

- 统一 HTTP 资料库：默认全部照片，支持精选与回收站；不依赖 SMB 挂载，也没有本地暂存资料库。
- 目录与图库之间可拖动调整宽度；目录滚动条采用自动隐藏的浮层样式。
- 图库滚动到底部自动加载下一页，加载过程中到达底部也会在当前请求完成后继续。目录当前查询少于 10,000 张时后台预取全部两级缩略图到磁盘缓存，最多四张并发；达到 10,000 张按滚动加载。目录打开不等待预取，图片仅在需要显示时解码。
- 服务器来源目录按需展开浏览，原生 NSOutlineView 目录树按需展开，包括空目录，支持键盘导航及保留展开状态的刷新；搜索、评分、颜色、标签筛选和排序。
- 多选照片，修改评分、精选、颜色和标签。
- 共享回收站与恢复，只改变服务器资产状态，不删除原片。
- 服务端目录追踪、扫描、任务状态与失败重试；路径相对于服务器原片根目录。
- 普通浏览使用 NAS 预览；照片右键“自动曝光”由 Mac 下载底片、计算曝光并生成展示大图及两级缩略图，再一起提交。右键“还原曝光调整”恢复原版展示，不改动原片。
- 照片信息的文件版本列表可右键“设为底片”。默认 Sony ARW 使用 RAW，3FR 使用已关联且非 Keeps 生成的 HEIF，其余按像素数选择；选定后不随扫描自动改变。已有曝光调整时，更换底片会重新计算曝光，全部成功后一起切换。
- 调整任务保存在 Application Support/Keeps/ExposureTasks；断网等待重连，重启自动继续，失败可查看完整错误、重试或结束任务。成功后清理本任务的下载和渲染文件；跨任务底片缓存尚未实现。

目录导航依赖服务端 `/libraries/{libraryID}/navigation` API；来源管理与手动扫描通过“设置 → 来源”访问；“任务追踪”独立显示扫描进度和失败重试，执行中的任务优先显示。目录导航失败不阻止已索引照片查询。顶栏“导入”（⌘⇧I）可递归读取用户选择的本机文件夹，把 RAW、JPG/JPEG、HEIF/HEIC/HIF 及关联 XMP 平铺上传到 NAS 追踪目录。目标目录旁的“新建文件夹…”可在当前目录下创建子文件夹，成功后自动选为导入目标；已有同名文件或目录不会被覆盖。默认关闭去重，仅扫描文件名、大小和修改时间，不预读整批照片。可勾选“跳过目标文件夹中内容完全相同的文件”，此时计算内容摘要并保留配套关系。来源文件保留；同名冲突按组改名；导入批次与来源只读授权保存在 Application Support/Keeps/ImportTasks，断网或重启恢复同一批次。上传、NAS 文件提交、元数据索引及缩略图分别显示进度，索引和两级缩略图全部完成才报告成功。Mac 每分钟续期一小时计算租约，负责该批次的媒体生成；失联超过租约后 NAS 接管缺失部分。已提交的 NAS 后台任务不因关闭面板或退出应用而取消。

```sh
swift test --package-path ../shared
swift test
bash scripts/package_app.sh
```

共享 HTTP 契约和 DTO 位于 `../shared` 的 KeepsAPI 包，macOS 与 iOS 使用同一份实现。

## TestFlight 分发

正式测试分发使用 `Keeps.xcodeproj` 的共享 `Keeps` scheme，自动签名团队为 `3TZ6RCL8NE`，Bundle ID 保持 `local.keeps`。工程直接编译现有源文件并引用 `../shared` 的 KeepsAPI，不维护第二份客户端实现。macOS 的版本号和构建号在 `Version.xcconfig` 修改，每次上传递增构建号；与 iOS 独立维护，不要求两端版本同步。发布记录使用“macOS 版本（构建号）”或“iOS 版本（构建号）”明确平台。

在仓库根目录执行：

```sh
bash scripts/testflight.sh macos archive
bash scripts/testflight.sh macos upload
```

可通过团队 App Store Connect API Key 程序化归档、上传及读取最新构建状态。`codex-secret` 的 `app-store-connect` 条目注入 `ASC_KEY_ID`、`ASC_ISSUER_ID`、`ASC_PRIVATE_KEY`（完整、多行 PKCS8 PEM），不将私钥放入仓库或命令参数：

```sh
codex-secret run app-store-connect -- bash scripts/testflight.sh macos archive
codex-secret run app-store-connect -- bash scripts/testflight.sh macos upload
codex-secret run app-store-connect -- bash scripts/testflight.sh macos status
```

`ios` 使用同一入口，但只有明确需要发布 iOS 时才运行其 archive/upload。状态查询只读，返回最新上传构建的处理状态及 TestFlight 内外部测试状态；没有构建时返回空列表，未返回的关系显示 null。该命令需要 `uv`，脚本通过 PEP 723 声明 `PyJWT[crypto]>=2.10,<3` 依赖，首次执行会下载依赖。

归档和上传将私钥短暂写入权限 0600 的临时文件，退出时清理。三个变量必须同时配置；全部未配置时，归档和上传继续使用现有 Xcode 账号，status 则要求 API Key。API Key 需具有对应 App 的发布权限；配置密钥不代表自动创建证书或保证上传成功。

实现依据：[Apple JWT 文档](https://developer.apple.com/documentation/appstoreconnectapi/generating-tokens-for-api-requests)、[Builds API](https://developer.apple.com/documentation/appstoreconnectapi/get-v1-builds) 及本机 `xcodebuild -help` 的 authenticationKey 参数。

归档保存在 `macos/.build/testflight/Keeps.xcarchive`，仅包含 Apple Silicon（arm64）架构，不支持 Intel Mac。上传需要 Xcode 已登录具有团队发布权限的账号，以及 App Store Connect 中对应的 macOS App 记录。归档成功不代表 TestFlight 已处理完成。

发行版开启 App Sandbox、Hardened Runtime 和出站网络权限；客户端通过 HTTP/HTTPS 访问 NAS；导入使用用户选择文件夹的只读沙盒权限，仅读取显式选择的来源。Keychain 仅保存当前应用凭据，不启用跨应用 Keychain sharing。首次切换到沙盒版本需在设置中确认服务地址、资料库与令牌；本地开发版的偏好和旧签名凭据不保证自动迁移。

`bash scripts/package_app.sh` 用于本机调试，生成 ad hoc 签名的 `Keeps Debug.app`，Bundle ID 为 `local.keeps.debug`；Xcode Debug 使用相同名称与身份。正式 Release/TestFlight 保持 `Keeps.app` / `local.keeps`，两者可并存，调试版不得覆盖正式版。SwiftPM 测试入口保持不变。

隐藏目录：目录右键选择“设为隐藏目录”或“取消隐藏目录”；子目录继承父目录的隐藏设置。“显示 → 过滤隐藏目录内容”默认开启，全库、精选、回收站和搜索均由服务端排除隐藏照片。进入隐藏目录或其子目录后可查看，独立标记的隐藏后代仍需进入后查看。目录入口保留，菜单可关闭过滤。此功能不加密原片、不提供密码锁。

导入内存回归：`python3 macos/scripts/test_import_memory.py` 使用独立 2 GiB 稀疏文件，分别验证默认扫描和可选哈希峰值常驻内存小于 128 MiB。

目录右键“删除文件夹…”需要输入完全一致的目录名，将文件夹及内容移入 NAS 回收站；恢复请使用 File Station 的标准回收站操作。此操作区别于仅修改记录的图库回收站和停止追踪。服务端必须支持目录回收接口，且共享目录已启用回收站。目录名称过长时截断，数量始终保留在右侧。

目录回收以后台任务执行。确认后暂停主窗口、照片快捷键、设置和任务窗口操作，显示等待、NAS 回收、索引更新阶段及经过时间；网络中断时持续查询，不把超时当作删除失败。任务 ID 与目标服务器、目录保存在本机（不保存凭据），重启继续查询同一任务。服务器已接受但记录丢失时明确提示并等待确认，不再次删除；成功后刷新图库，失败时展示服务器错误。退出应用不取消后台回收。

“照片 → 删除所有弃用照片…”统计整个资料库中标记为“排除”的照片（包括隐藏目录，不含 Keeps 图库回收站）。确认窗口按照片去重显示数量，输入完全一致的总数后，NAS 将清单中的原片、关联版本及 sidecar 移入 DSM 回收站；在 File Station 恢复。数量为零时不能提交；标记、照片清单或文件变化时要求重新确认。已确认任务与连接持久保存在本机，断网或重启查询同一个任务，执行时暂停其他整理操作；原生回收中断不盲目重放，失败可能已部分完成。
