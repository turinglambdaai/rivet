# Rivet

用 [Racket](https://racket-lang.org/) 构建第一方原生桌面应用。Windows 使用 WinUI 3，macOS 使用 SwiftUI，Linux 使用 GTK4；把应用逻辑放在 Racket 中，最终交付的是真正原生应用，而不是 WebView 或跨平台控件封装层。

**Human-first. Agent-native. Local by design. —— 为人而生，为 Agent 原生设计，本地优先。**

[![CI](https://github.com/turinglambdaai/rivet/actions/workflows/ci.yml/badge.svg)](https://github.com/turinglambdaai/rivet/actions/workflows/ci.yml) ![Racket](https://img.shields.io/badge/Racket-9F1D20?logo=racket&logoColor=white) ![Windows](https://img.shields.io/badge/Windows-WinUI_3-0078D4?logo=windows11&logoColor=white) ![macOS](https://img.shields.io/badge/macOS-SwiftUI-000000?logo=apple&logoColor=white) ![Linux](https://img.shields.io/badge/Linux-GTK4-FCC624?logo=linux&logoColor=111111) [![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE) [![Version](https://img.shields.io/github/v/release/turinglambdaai/rivet?label=version)](https://github.com/turinglambdaai/rivet/releases/latest)

[English](README.md) · **中文**

## 使用入口

当第一方原生交互值得维护 SwiftUI、WinUI 3、GTK4 三份界面时，选择 Rivet。共享领域逻辑归 Racket，渲染与系统交互归原生宿主。需要共享 HTML/CSS 界面时可评估 Glaze。

[使用选择、成熟度、升级与支持](docs/USING.zh-CN.md) · [English](docs/USING.md)

## 快速开始

请使用你希望 Rivet 最终嵌入的那套 Racket CS 自带的 `raco`，从 Racket Package Catalog 安装：

```bash
raco pkg install --auto rivet
raco rivet new hello
cd hello
raco rivet inspect --json
raco rivet doctor
raco rivet dev
```

这就是普通用户的主路径。`doctor` 会检查原生工具链，并在缺少必要组件时直接给出下一步修复建议；`dev` 会构建并启动当前平台的一等原生宿主。

每个新项目都会生成 `AGENTS.md`、初始 `rivet-schema.json` 兼容性基线和
`rivet-acceptance.rktd` 可执行完成定义；`inspect --json` 则提供带版本号的机器
可读项目地图，包括项目身份、Racket 后端与各端原生 UI 编辑入口、schema 与验收
检查、目标成熟度、生成目录和安全生命周期命令。详见 [Agent-native
开发](docs/agent-native.md)和[产品验收证据](docs/product-acceptance.md)。

需要完整引导时直接看 **[Rivet 快速上手教程](docs/getting-started.zh-CN.md)**；产品发布前请采用[原生宿主 CI 契约](docs/ci.zh-CN.md)。安装后的包也提供可搜索的 Scribble 文档。只有开发 Rivet 框架本身时，才需要使用教程里的源码 link 安装方式。

跑通 counter 后，继续学习长期维护的 **[Rivet Taskboard 参考应用](examples/taskboard/README.zh-CN.md)**：三个平台分别使用 WinUI 3、SwiftUI、GTK4，在同一份经过测试的 Racket 契约之上实现列表/详情工作流。

## 为什么选择 Rivet？

Racket 非常适合承载应用逻辑，但一直缺少一条直接连接现代第一方桌面 UI 技术栈的路径。要做产品级 Windows、macOS 或 Linux 应用，往往不得不在“放弃 Racket”“接受 WebView”或“换成跨平台控件库”之间做选择。

Rivet 补上的是这一层：

- **第一方原生 UI** —— Windows 使用 WinUI 3，macOS 使用 SwiftUI/AppKit，Linux 使用 GTK4
- **Racket 负责应用逻辑** —— 宏、模式匹配、并发、数据处理、业务逻辑都留在 Racket
- **一套后端契约** —— typed RPC、Event、共享 State、取消与生命周期统一走 RVT1
- **共享应用模型** —— 将后端 schema 投影到与 Glaze 共用的传输无关契约 [Keel](https://github.com/turinglambdaai/keel)，但 RVT1 与原生 UI 所有权仍留在 Rivet
- **自动生成原生客户端** —— Racket 侧的声明在构建时生成 Swift/C++/Kotlin 类型化 API
- **实时图表** —— 三桌面宿主统一的滚动时间序列控件走同一套类型化数据面（`rivet/chart` 环形缓冲 + 带间隙检测的二进制批次）；见 [docs/chart-series.md](docs/chart-series.md)
- **进程内嵌 Racket CS** —— 不需要额外启动后端进程，Racket runtime 直接嵌入应用
- **精确 runtime 匹配** —— 构建时使用当前安装的精确 Racket CS 版本，不会静默退回相邻版本
- **明确的生态扩展路径** —— 新项目的 Agent 指南和 `inspect --json` 会说明何时选择 Racket 包、原生宿主 API、FFI、外部 CLI 或隔离 sidecar，并列出每种选择必须完成的安全与发布检查

Rivet 刻意不做 WebView 框架，也不做统一跨平台控件层。Windows、macOS 与 Linux 都保留各自第一方原生 UI 和平台行为。

### Hello Rivet

三个桌面平台共享同一份 Racket 后端：

```racket
#lang racket/base

(require rivet/backend)

(provide start)

(define-event progress)
(define-state counter : Int64 0)

(define-rpc (greet [name : String] : String)
  (format "Hello, ~a!" name))

(define-rpc (increment [value : Int64] : Int64)
  (add1 value))

(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))
```

`raco rivet build` 会读取 RPC、Event、State、Record 与 Enum schema，并生成类型化原生客户端。Swift 侧得到 `increment(value:)`、`get_counter()`、`set_counter(_:)` 等方法；C++ 侧得到对应的原生接口；Kotlin 侧在 `.rivet/generated/kotlin/dev/rivet/generated/GeneratedBackend.kt` 得到 `increment(value)` 等 suspend 方法。

### 横向对比

| | Rivet | Glaze |
|---|---|---|
| UI 技术栈 | **WinUI 3 / SwiftUI / GTK4** | HTML/CSS/JS + WebView |
| Racket 的角色 | 共享后端 | 后端 + 本地 Web 服务 |
| 原生控件 | **系统第一方 UI** | 否 |
| 一套 UI 跨平台 | 否 | 是 |
| 样式体系 | 平台原生 | CSS |
| 最适合 | 原生商业桌面应用 | Web 技术桌面应用 |

这两个项目不是互相替代，而是在解决不同的桌面开发取舍。

## 工作原理

```text
                    Racket application
                           │
             RPC / Event / State / Cancel
                           │
                    RVT1 protocol
                ┌────────┬────────┐
                │        │        │
           C++/WinRT   Swift     C++
                │        │        │
             WinUI 3  SwiftUI   GTK4
                │        │        │
             Windows   macOS    Linux
```

Racket CS 运行在独立 runtime 线程。原生 UI 代码不会直接操作 Racket/Chez 对象，Racket 指针也不会跨普通 native 线程传递。原生侧只看到 RVT1 帧和生成后的 Swift/C++/Kotlin 值。

嵌入模型受到 [Noise](https://github.com/Bogdanp/Noise) 的启发，但 Rivet 把 runtime contract、协议、代码生成和生命周期都做成平台无关的统一核心，而不是以 Swift 为中心。

架构、协议、平台集成、诊断和发布资料统一从[文档导航](docs/README.md)进入，每个主题只保留一个规范入口。

## 平台支持状态

| 能力 | Windows | macOS | Linux |
|---|---|---|---|
| 原生宿主 | ✅ WinUI 3 + C++/WinRT | ✅ SwiftUI + Swift | ✅ GTK4 + C++ / Wayland |
| Embedded Racket CS | ✅ | ✅ | ✅ 静态 runtime |
| RVT1 / Event / State / Cancel | ✅ | ✅ | ✅ |
| 类型化客户端生成 | ✅ C++ | ✅ Swift | ✅ C++ |
| `new` / `doctor` / `build` / `dev` | ✅ | ✅ | ✅ |
| `package` / `verify` | ✅ DLL 依赖审计 | ✅ 签名/rpath/plist | ✅ 目录 + `ldd` 审计 |
| 生产签名 / 安装包 | ✅ Authenticode + MSI | ✅ Developer ID + DMG | ✅ 签名 tarball + deb/rpm/AppImage |
| 系统服务 / 安全存储 | ✅ | ✅ | ✅ Linux 适配器 + Portal 全局快捷键 + StatusNotifierItem 托盘 |
| 真实嵌入运行时 CI | ✅ | ✅ | ✅ |

Windows、macOS 与 Linux 都是生产发布目标。Linux 资格门禁使用原生
Wayland，并通过真实 deb/rpm 包管理器事务验证安装、失败升级恢复、升级、
拒绝隐式降级、启动与卸载；AppImage 还会在构建目录外独立启动验证。
X11/XWayland 仅保留 GTK 尽力兼容，不是发布目标。

### Apple 移动端基础

| 能力 | iPhone / iPad | Apple Watch |
|---|---|---|
| 可移植 Swift 协议/runtime | ✅ iOS/iPadOS 16+ | ✅ watchOS 9+ |
| 类型安全跨设备请求/响应 | ✅ 生成式白名单与 router | ✅ 生成式客户端 |
| WatchConnectivity 适配 | ✅ 手机端 | ✅ 手表端 |
| Embedded Racket CS 应用宿主 | 计划采用 portable-bytecode runtime | 默认 companion 模式 |
| `raco rivet new/build/package` 应用链 | 尚未完成 | 尚未完成 |

共享 Racket schema 现在可以生成默认拒绝的 Codable companion API，CI 会把这份生成代码分别交叉编译到 iOS 与 watchOS。这些仍是移动端基础能力，不代表完整应用交付已经完成：下一阶段是手机/平板 embedded runtime 和原生 SwiftUI 脚手架；watchOS 则有意从连接手机后端的类型安全 companion 模式开始。

### Android 基础

| 能力 | Android 手机 / 平板 |
|---|---|
| Kotlin RVT1 codec | ✅ 共享 golden vectors |
| 协程 runtime 客户端 | ✅ Request/Event/State/Cancel |
| 类型化客户端生成 | ✅ 从共享 schema 生成并在 CI 编译 |
| 原生 UI 宿主 | 计划采用 Jetpack Compose |
| Embedded Racket CS / JNI | 尚未完成 |
| `raco rivet new/build/package` 应用链 | 尚未完成 |

仓库内的 Gradle wrapper 固定了版本并校验下载摘要。Android 目前具备经过测试的协议、协程客户端与类型化客户端生成基础；JNI runtime 宿主、Compose 脚手架、打包签名和设备/模拟器 round-trip 完成后，才能进入开发者预览。详见架构文档中的 [Android foundation](docs/architecture.md#android-foundation)。

## 环境要求

| 依赖 | 用途 |
|---|---|
| [Racket CS](https://racket-lang.org/) | 应用后端与嵌入 runtime |
| Visual Studio 2022 / Build Tools + Windows SDK | Windows 原生宿主构建；Windows App SDK 作为项目依赖在构建时自动恢复 |
| Xcode Command Line Tools / Swift | macOS 原生宿主构建 |
| CMake、C++20、pkg-config、GTK 4.10+ 开发文件 | Linux 原生宿主构建 |

构建过程中 Rivet 会自动定位当前精确版本的 Racket CS runtime、boot files、headers 与 native libraries。第一次执行 `dev` 之前先运行 `raco rivet doctor`；环境不完整时，它会给出明确的 remediation，而不只是显示 `not found`。

## 日常开发流程

创建项目并进入正常的编辑/运行循环：

```bash
raco rivet new hello
cd hello
raco rivet doctor
raco rivet dev
```

生成的项目同时包含共享 Racket 后端以及 Windows、macOS、Linux 原生宿主。项目自己的 `README.md` 会直接告诉你最常编辑哪些文件。

准备发布时：

```bash
raco rivet build
raco rivet package
raco rivet verify
raco rivet release
```

`build` 负责生成 native host 和 staged runtime；`package` 输出可分发的 Windows/Linux 目录或 macOS `.app`，并在成功前自动验证发布物；`verify` 可以重新检查已有发布物。

需要正式发行签名时，按 [生产签名文档](docs/production-signing.md) 配置凭据后执行 `raco rivet package --production`。

`release` 会继续生成正式 installer、独立 Ed25519 签名的更新 manifest、SBOM 与第三方许可声明。共用 updater 负责可信检查与下载，并覆盖 macOS bundle 换装、Windows MSI 交接和 Linux AppImage 原子替换；产品只需要提供策略与本地化 UI，不再重复实现安全关键流程。更新私钥和平台发布证书彼此独立，详见[发布与更新](docs/release-and-updates.md)。

### 产品权益授权

商业权益有意放在 Rivet 框架边界之外。需要离线可验证权益的产品可以将 Rivet 与
[Permit](https://github.com/turinglambdaai/permit/blob/main/docs/framework-integration.md)
或其他独立权益库组合使用；Rivet 本身不依赖它。产品可以使用 Rivet 的通用安全存储
保存凭证状态。需要在线结账、支付事件处理或凭证领取时，产品还可以接入
[Commerce](https://github.com/turinglambdaai/commerce)；Commerce 是产品/服务层依赖，
绝不进入 Rivet。手工交付或完全离线销售的产品不需要 Commerce。支付渠道密钥、
Commerce 密钥、产品权益签名、更新签名和平台代码签名必须保持独立密钥与信任策略。

## RPC、Event、State、Cancel

### Typed RPC

```racket
(define-rpc (lookup-user [id : Int64] : String)
  (format "user-~a" id))
```

参数与返回值都会在 Racket 边界做类型校验。目前支持 `String`、`Int64`、`Bool`、`Bytes`、`Void`、`Any`、`(List T)`、`(Optional T)`、通过 `define-record` 声明的具名 Record，以及通过 `define-enum` 声明的封闭取值。Record 会生成位于 `RivetTypes` 下的 Swift struct、C++ struct 与 Kotlin data class；Enum 会生成位于 `RivetTypes` 下的 Swift raw-value enum、C++ `enum class` 与 Kotlin `enum class`。Swift 命名空间可避免 `Task`、`Result` 等领域名称在整个应用模块中遮蔽标准库类型。

这些类型名属于 Rivet 的声明语法，并不是 Racket 运行时值。运行时工具应检查 `current-backend-app-schema` 返回的不可变 Keel schema，而不是依赖第二套 descriptor API。

### Event

```racket
(define-event download-progress)
(download-progress 75)
```

Event 和 RPC Response 共享同一条 RVT1 连接，不需要额外开启 server 或端口。

### Shared State

```racket
(define-state counter : Int64 0)
(state-set! counter 42)
```

native client 可以通过生成的类型化 getter/setter 读取和更新 State。State 更新时还会发出 `$state` event，因此 UI 不需要轮询。

### Cancel

长时间 RPC 使用 RVT1 request id。native client 可以取消尚未完成的请求，Racket server 会关闭对应 request custodian 并返回取消错误，而不会终止整个 backend。

### Schema 兼容性

每个新项目都包含带版本、语言无关的公开 backend JSON 基线。把它提交到版本库，并在 CI 中执行兼容性门禁：

```bash
raco rivet schema --output rivet-schema.json
raco rivet schema check rivet-schema.json --json
```

新增 RPC、Event、State、Record 和 Enum 类型属于兼容扩展。删除接口、修改 RPC 签名或值类型、修改 RVT1 协议版本、修改 Record 字段/顺序，或修改已有 Enum 的 case/顺序，都会被报告为破坏性变化并返回失败状态。只有在版本策略明确允许破坏兼容时，才应重新生成基线。

当项目根目录存在 `rivet-schema.json` 时，`raco rivet build` 以及所有经由它执行构建的命令都会在生成原生客户端前自动运行相同的兼容性检查。CI 中仍应保留显式的 `schema check` 步骤，以便得到聚焦且机器可读的失败信息；没有基线的项目仍可构建，但 `doctor` 和 `inspect` 会将其标记为尚未达到发布就绪状态。

## CLI

```text
raco rivet new <name>              创建新的 Rivet 应用
raco rivet doctor                  检查 Racket 与 native 工具链
raco rivet doctor --json           输出机器可读诊断
raco rivet inspect                 显示项目编辑点与验证路径
raco rivet inspect --json          输出 Agent 可读的项目契约
raco rivet schema --json           输出当前带版本的 API schema
raco rivet schema --output <file>  写入 schema 兼容性基线
raco rivet schema check <file>     拒绝相对基线的破坏性变化
raco rivet schema check <file> --json  输出机器可读的兼容性报告
raco rivet clean                   删除 .rivet/build/dist 生成物
raco rivet build                   编译 backend、生成 client、构建 native host
raco rivet dev                     构建并运行当前应用
raco rivet package                 创建并验证开发发布物
raco rivet package --production    创建、签名并验证正式发布物
raco rivet release                 构建 installer、签名更新 manifest、SBOM 与许可声明
raco rivet release --development   不做平台正式签名，演练完整 release 流程
raco rivet release --without-updates  构建不含更新 manifest 的完整发布物
raco rivet compliance              生成 SBOM/许可声明并执行 license audit
raco rivet verify                  重新验证当前发布物
raco rivet verify --production     验证生产签名/公证信任状态
raco rivet help                    显示帮助
```

## 项目结构

新生成的应用保持尽量简单：

```text
hello/
├── rivet.rktd
├── app/
│   └── backend.rkt
├── windows/
│   ├── App.xaml
│   ├── MainWindow.xaml
│   └── RivetHost.vcxproj
├── macos-host/
    ├── Package.swift
    └── Sources/
        └── RivetHost/
└── linux/
    ├── CMakeLists.txt
    └── src/main.cpp
```

原生 UI 源码属于应用本身；Rivet 负责 runtime bridge、协议、codegen 和构建编排。

`rivet.rktd` 同时是应用 identity、版本/build number、Windows/macOS 最低系统版本的唯一应用级配置源。具体字段见 [docs/configuration.md](docs/configuration.md)。

## 仓库结构

```text
rivet/
├── rivet/                    # Racket backend、协议、State/RPC 定义
├── rivet-cli/                # new / doctor / clean / build / dev / package / verify / codegen
├── runtime/                  # 共享 C++ RVT1 codec 与测试
├── platform/
│   ├── windows/
│   │   ├── runtime/          # Racket CS bridge + native client
│   │   └── host/             # WinUI 3 模板
│   ├── macos/
│       ├── Sources/          # Swift protocol/client + C embedding bridge
│       └── host/             # SwiftUI 模板
│   └── android/              # Kotlin RVT1 协议/runtime 与 Gradle 构建
├── rivet/tests/
└── docs/
```

## 测试

```bash
raco test rivet/tests/
cmake -S runtime -B runtime/build
cmake --build runtime/build
ctest --test-dir runtime/build
racket_include="$(racket -e '(require setup/dirs) (display (path->string (find-include-dir)))')"
swift test --package-path platform/macos -Xcc "-I${racket_include}"
platform/android/gradlew -p platform/android test
```

CI 会验证 Racket、C++、Swift 与 Kotlin 协议实现，在三个桌面平台执行真实 embedded Racket round-trip，通过无头原生 Wayland compositor 启动打包后的 GTK4 宿主，为 iOS/watchOS 交叉编译可移植 Swift 层，编译生成的 Kotlin 客户端，并对新生成的桌面应用运行 build、package、verify smoke；Windows ARM64、macOS Intel 与 Linux ARM64 由独立的干净 runner 架构矩阵覆盖。

## 诚实的局限

- **Linux 桌面资格验证有明确边界** —— 发布矩阵会在仍受维护的发行版上验证原生 Wayland、包管理器生命周期、AppImage 启动与系统适配器行为；GPU、Portal、缩放、输入、GNOME、KDE 等产品特定行为仍应由各应用自己的发布证据覆盖。X11/XWayland 是尽力兼容路径，不是发布门禁。
- **Apple 移动端仍是基础阶段** —— 可移植 Swift 与类型安全 WatchConnectivity 层已经存在，但 iOS/iPadOS/watchOS 项目生成、runtime 打包、签名和商店交付还未完成。
- **Android 仍处于基础阶段** —— Kotlin RVT1 codec、协程 runtime 客户端、类型化客户端生成与固定版本的 Gradle 构建已经过测试，但 Jetpack Compose、JNI、portable Racket CS 打包、签名和设备交付尚未完成。
- **架构证据覆盖构建/打包/验证，尚不覆盖生产发布** —— 干净 runner 门禁覆盖 Windows x64/ARM64、macOS Apple Silicon/Intel 与 Linux x64/ARM64，但生产发布产物仍由标签驱动的发布流程按应用生成。
- **没有统一声明式跨平台 UI DSL** —— UI 代码仍然直接写 SwiftUI/AppKit 或 WinUI 3/C++/WinRT。
- **正式发布凭据仍属于应用自身** —— Rivet 已自动化 Authenticode、Developer ID、notarization 流程，但证书、PFX 密码、Apple notary profile 会由应用/CI 环境注入，不由 Rivet 保存。
- **Public API 仍处于 pre-1.0** —— 协议有版本控制，但高层 API 仍可能继续调整。

维护者应遵循 [API 稳定性策略](docs/api-stability.zh-CN.md)：仓库会快照全部公开导出，并使用最低支持的 Racket 版本运行完整 Racket 测试套件。

## 路线图

- [x] **Phase 1** —— Racket / C++ / Swift 三端 RVT1 协议
- [x] **Phase 2** —— Windows 与 macOS 嵌入 Racket CS
- [x] **Phase 3** —— Typed RPC、Event、State、Cancel、Swift/C++ codegen
- [x] **Phase 4** —— `new` / `doctor` / `build` / `dev` / `package`
- [x] **Phase 5** —— 发布物验证、生产签名/公证入口与 tag-driven release engineering
- [x] **Phase 6 —— Schema 演进与桌面架构加固**
  - [x] 具名 Record schema、Swift/C++ 代码生成与边界校验
  - [x] 带版本的 schema 快照与机器可读的破坏性变更门禁
  - [x] Windows x64/ARM64 构建选择
  - [x] 具名 Enum schema、Swift/C++ 代码生成与兼容性检查
  - [x] Kotlin 类型客户端生成
  - [x] 覆盖每个受支持桌面架构的干净 runner 构建/打包/验证证据
- [x] **Phase 7 —— 桌面生产晋级** —— 真实 Linux 安装/升级证据、一方更新安装适配器、原生 UI 端到端门禁，以及由特征测试保护的可维护性改造
- [ ] **Phase 8 —— 1.0 契约稳定化** —— 生成客户端统一以 Keel 为规范 Schema；Float64、map、结构化 error 等 RVT1 扩展只有在跨 runtime golden 与 fuzz 证据齐备时才引入；对齐可移植分发元数据，但平台安装器策略不进入 Keel
- [ ] **Phase 9 —— 一等设备应用交付** —— Windows/macOS/Linux 1.0 主线稳定之后，再提供生成式 iOS/iPadOS/tvOS/visionOS/watchOS 与 Android 项目，明确 embedded-runtime 或 companion 角色，并补齐签名、打包和真机验证

当前执行顺序与退出条件见[桌面收尾与移动端启动计划](docs/desktop-closeout-mobile-plan.md)。

## 许可证

基于 [MIT License](LICENSE) 发布。
