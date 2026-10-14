# Keeps

Keeps 是以 NAS 为核心的照片资产管理器。Rust 常驻服务负责照片索引、扫描任务、元数据整理与预览生成；macOS 和 iOS 是原生薄客户端，通过共享 HTTP 接口浏览和操作 NAS 资料库。

NAS 核心服务已于 2026-09-26 部署并迁移历史资料库，首次全库扫描在后台运行。客户端已移除本地业务数据库、ledger 回放和扫描路径；两端构建通过，iOS 界面实测尚未完成。具体证据见部署说明。

## 目录

- `server/`：唯一活跃后端，Rust/Axum、SQLite、资产查询和后台处理。
- `shared/`：两端共用的 `KeepsAPI` Swift 包，含 DTO、HTTP 客户端和连接配置。
- `macos/`：SwiftUI 三栏浏览、筛选、多选整理与 NAS 任务管理。
- `ios/`：SwiftUI 图库、详情与整理界面。
- `deploy/spk/`：NAS 唯一受支持的原生套件部署方式；Docker 不用于部署 NAS 服务。
- `control_plane/`：旧 Python 协议与迁移对照工具，不作为第二套运行后端。
- [docs/UX_DESIGN.md](docs/UX_DESIGN.md)：产品行为与能力边界；[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)：当前架构与职责。
- `feature.md`：早期需求草案，包含尚未实现或已调整的设想，不是当前架构依据。

## NAS 部署与客户端连接

NAS 部署、升级、恢复和验收步骤见 [deploy/spk/README.md](deploy/spk/README.md)。旧 NAS Docker Compose 部署已退役，仓库不再提供可启动入口。Rust 开发说明见 [server/README.md](server/README.md)。

macOS 在 Keeps → 设置（⌘,）的 Server 页面配置照片服务地址、资料库名称和服务访问令牌，验证连接成功后保存；iOS 在连接设置中配置同一服务。地址及资料库保留在 UserDefaults，凭据保存在 Keychain；原有连接偏好会迁移。客户端只保存界面状态和可丢弃的图片缓存，所有业务读写经 NAS API。

客户端不需要 SMB 挂载或本地资料库；主入口为统一照片资料库，目录仅作为服务器来源。原片与服务状态目录分开，NAS 套件按服务配置访问原片。扫描、停止追踪和图库回收站均不得删除、移动或覆盖原片。macOS 显式“删除文件夹”例外：输入完全一致的目录名后，由服务端移动到已启用的 NAS 共享目录回收站，禁止永久删除或覆盖已有文件。

## 开发与验证

共享契约和 macOS：

```sh
swift test --package-path shared
swift test --package-path macos
swift build --package-path macos
./macos/scripts/package_app.sh
open "macos/.build/app/Keeps Debug.app"
```

iOS Simulator：

```sh
xcodebuild \
  -project ios/KeepsIOS.xcodeproj \
  -scheme KeepsIOS \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Rust 服务：

```sh
cargo test --manifest-path server/Cargo.toml
cargo build --manifest-path server/Cargo.toml
```

端到端验证还需要实际 NAS、原片只读挂载、任务重启恢复，以及客户端对 NAS 的查询和整理操作。

## 客户端分发

macOS 与 iOS 以 TestFlight 内部测试为主要分发渠道，使用 ClimaMind LLC 的 Apple Developer Program（Team ID `3TZ6RCL8NE`）。本地构建保留用于开发验证；不再使用企业 IPA 导出。NAS 服务独立部署，使用[原生套件](deploy/spk/README.md)。

```sh
# 先运行上面的共享契约、macOS 测试，再分别归档。
./scripts/testflight.sh ios archive
./scripts/testflight.sh macos archive

# 上传已归档的构建到 App Store Connect，仅用于 TestFlight 内测。
./scripts/testflight.sh ios upload
./scripts/testflight.sh macos upload
```

版本统一记作 `主版本.次版本.修订号.构建号`，例如 `0.3.0.9`。Apple 工程的 `MARKETING_VERSION` / `CFBundleShortVersionString` 保持三段 `0.3.0`，`CURRENT_PROJECT_VERSION` / `CFBundleVersion` 为 `9`；文档和发布沟通使用组合后的四段版本号。每次发布递增最后一段。

归档分别位于 `ios/.build/testflight/KeepsIOS.xcarchive` 和 `macos/.build/testflight/Keeps.xcarchive`。上传支持本机加密凭据库注入的 App Store Connect API Key，未配置时使用 Xcode 已登录的团队账号与自动签名，不在仓库保存凭据。上传不会重建源码；修改后必须重新归档，每次发布前递增对应工程的 build number。Apple 完成处理并在 TestFlight 显示 `Testing` 后才算分发完成，上传成功不等于已经可安装。

App Store Connect 已创建应用记录：[Keeps 照片库（iOS）](https://appstoreconnect.apple.com/apps/6816541067/testflight)，Bundle ID `com.hechuan.Keeps`；[Keeps 照片库 for Mac](https://appstoreconnect.apple.com/apps/6816541220/testflight)，Bundle ID `local.keeps`。两端的“Keeps 内部测试”组均启用自动分发，目前仅加入账号本人。两端保留现有 bundle ID，使用独立的应用记录。macOS 发布工程启用 App Sandbox 和出站网络权限；沙盒签名版本的连接设置与 Keychain 访问需要实机验收，必要时在应用设置中重新连接 NAS。

TestFlight 构建有效期为 90 天，需要持续发布新构建。该渠道用于测试，未提交 App Store 正式上架审核。

## 历史数据迁移

旧 Python 测试和 seed 工具位于 `control_plane/` 与 `scripts/`，用于已有数据库的迁移和协议对照。新客户端不自动打开旧本地数据库，不恢复旧复制或扫描任务。同一 NAS 状态目录只能由一个后端管理。

## GitHub CI

`.github/workflows/ci.yml` 在 main push、所有 PR 和手动触发时运行。push 按上一次成功 CI 至当前提交的变化选择 Rust、Python、共享 Swift、macOS 与 iOS 检查，避免漏掉被取消或失败的提交；PR 按分支差异选择，手动触发运行全部检查。Apple 平台与共享库并行验证，SwiftPM/Xcode Debug 和 Cargo 使用工具链隔离的构建缓存；密钥扫描及发布脚本测试每次运行。CI 仅有读取权限，不持有 Apple 或 NAS 凭据；纯服务端修改不会触发 macOS TestFlight 发布。

本机 API 查询：`codex-secret run app-store-connect -- bash scripts/testflight.sh macos status`（iOS 将 `macos` 换为 `ios`）。同一入口支持 `archive` 和 `upload`，私钥由加密凭据库注入。

文档默认不新增，只在维护或使用确有必要时更新现有说明。执行记录、验证报告、截图和接口响应不入库；临时产物放 `.build/`，无需长期保留。
