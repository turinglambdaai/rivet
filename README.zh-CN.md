# Rivet

用 [Racket](https://racket-lang.org/) 构建第一方原生桌面应用。Windows 使用 WinUI 3，macOS 使用 SwiftUI，把应用逻辑放在 Racket 中，最终交付的是真正的原生应用，而不是 WebView 或跨平台控件封装层。

[![CI](https://github.com/turinglambdaai/rivet/actions/workflows/ci.yml/badge.svg)](https://github.com/turinglambdaai/rivet/actions/workflows/ci.yml) ![Racket](https://img.shields.io/badge/Racket-9F1D20?logo=racket&logoColor=white) ![Windows](https://img.shields.io/badge/Windows-WinUI_3-0078D4?logo=windows11&logoColor=white) ![macOS](https://img.shields.io/badge/macOS-SwiftUI-000000?logo=apple&logoColor=white) [![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE) [![Release](https://img.shields.io/badge/release-0.2.0-C15F3C)](CHANGELOG.md)

[English](README.md) · **中文**

## 为什么选择 Rivet？

Racket 非常适合承载应用逻辑，但一直缺少一条直接连接现代第一方桌面 UI 技术栈的路径。要做产品级 Windows/macOS 应用，往往不得不在“放弃 Racket”“接受 WebView”或“换成跨平台控件库”之间做选择。

Rivet 补上的是这一层：

- **第一方原生 UI** —— Windows 使用 WinUI 3，macOS 使用 SwiftUI/AppKit
- **Racket 负责应用逻辑** —— 宏、模式匹配、并发、数据处理、业务逻辑都留在 Racket
- **一套后端契约** —— typed RPC、Event、共享 State、取消与生命周期统一走 RVT1
- **自动生成原生客户端** —— Racket 侧的声明在构建时生成 Swift/C++ 类型化 API
- **进程内嵌 Racket CS** —— 不需要额外启动后端进程，Racket runtime 直接嵌入应用
- **精确 runtime 匹配** —— 构建时使用当前安装的精确 Racket CS 版本，不会静默退回相邻版本

Rivet 刻意不做 WebView 框架，也不做统一跨平台控件层。Windows 应用仍然是 Windows 应用，macOS 应用仍然是 macOS 应用。

### Hello Rivet

两个平台共享同一份 Racket 后端：

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

`raco rivet build` 会读取 RPC 与 State schema，并生成类型化原生客户端。Swift 侧得到 `increment(value:)`、`getCounter()`、`setCounter(_:)` 等方法；C++ 侧得到对应的原生接口。

### 横向对比

| | Rivet | Glaze | Bezel | Tessera |
|---|---|---|---|---|
| UI 技术栈 | **WinUI 3 / SwiftUI** | HTML/CSS/JS + WebView | Qt 6 Widgets | 自绘 GPU UI |
| Racket 的角色 | 共享后端 | 后端 + 本地 Web 服务 | 应用 + Qt 绑定 | 应用 + 渲染器 |
| 原生控件 | **系统第一方 UI** | 否 | Qt 控件 | 否，自绘 |
| 一套 UI 跨平台 | 否 | 是 | 是 | 是 |
| 样式体系 | 平台原生 | CSS | QSS | Tessera View/Style API |
| 最适合 | 原生商业桌面应用 | Web 技术桌面应用 | 传统跨平台 GUI | 完全自定义、声明式 Racket UI |

这四个项目不是互相替代，而是在解决不同的桌面开发取舍。

## 工作原理

```text
                    Racket application
                           │
             RPC / Event / State / Cancel
                           │
                    RVT1 protocol
                   ┌───────┴───────┐
                   │               │
              C++ / C++/WinRT    Swift
                   │               │
                 WinUI 3        SwiftUI
                   │               │
                Windows          macOS
```

Racket CS 运行在独立 runtime 线程。原生 UI 代码不会直接操作 Racket/Chez 对象，Racket 指针也不会跨普通 native 线程传递。原生侧只看到 RVT1 帧和生成后的 Swift/C++ 值。

嵌入模型受到 [Noise](https://github.com/Bogdanp/Noise) 的启发，但 Rivet 把 runtime contract、协议、代码生成和生命周期都做成平台无关的统一核心，而不是以 Swift 为中心。

深入设计见 [架构](docs/architecture.md)、[协议](docs/protocol.md)、[嵌入](docs/embedding.md)、[项目配置](docs/configuration.md)、[诊断](docs/diagnostics.md)、[发布物验证](docs/package-verification.md) 与 [生产签名](docs/production-signing.md)。

## 平台支持状态

| 能力 | Windows | macOS |
|---|---|---|
| 原生宿主 | ✅ WinUI 3 + C++/WinRT | ✅ SwiftUI + Swift |
| Embedded Racket CS | ✅ | ✅ |
| RVT1 Request / Response / Error | ✅ | ✅ |
| Event | ✅ | ✅ |
| Shared State | ✅ | ✅ |
| Cancel | ✅ | ✅ |
| 类型化客户端生成 | ✅ C++ | ✅ Swift |
| `raco rivet build` | ✅ | ✅ |
| `raco rivet dev` | ✅ | ✅ |
| `raco rivet package` | ✅ 原生分发目录 | ✅ `.app` bundle |
| 发布物验证 | ✅ DLL 依赖闭包 | ✅ 签名/rpath/plist |
| 生产签名路径 | ✅ Authenticode | ✅ Developer ID + notarization |
| CI 协议覆盖 | ✅ | ✅ |

当前优先支持 Windows x64。Linux 不是 Rivet 目前的目标，因为 Rivet 的定位就是绑定各平台第一方 UI，而不是再定义一套统一跨平台控件系统。

## 环境要求

| 依赖 | 用途 |
|---|---|
| [Racket CS](https://racket-lang.org/) | 应用后端与嵌入 runtime |
| Visual Studio / Windows App SDK | Windows 原生宿主构建 |
| Xcode Command Line Tools / Swift | macOS 原生宿主构建 |

构建过程中 Rivet 会自动定位当前精确版本的 Racket CS runtime、boot files、headers 与 native libraries。

## 快速开始

### 1. 安装 Rivet

从源码 checkout 安装：

```bash
git clone https://github.com/turinglambdaai/rivet.git
cd rivet
raco pkg install --auto --name rivet --link "$(pwd)"
```

### 2. 创建项目

```bash
raco rivet new hello
cd hello
```

生成的项目同时包含共享 Racket 后端、Windows 原生宿主和 macOS 原生宿主。

### 3. 检查工具链

```bash
raco rivet doctor
```

`doctor` 会检查当前平台工具链以及 Rivet 实际要嵌入的精确 Racket CS runtime。`raco rivet doctor --json` 会把同样的诊断数据提供给 CI 和 Agent。

### 4. 开发运行

```bash
raco rivet dev
```

它会重新编译 Racket 后端、重新生成 native client、构建当前平台的原生宿主，然后直接启动应用。

### 5. 构建与打包

```bash
raco rivet build
raco rivet package
raco rivet verify
```

`build` 负责生成 native host 和 staged runtime；`package` 输出可分发的 Windows 目录或 macOS `.app`，并在成功前自动验证发布物；`verify` 可以重新检查已有发布物。

需要正式发行签名时，按 [生产签名文档](docs/production-signing.md) 配置凭据后执行 `raco rivet package --production`。

## RPC、Event、State、Cancel

### Typed RPC

```racket
(define-rpc (lookup-user [id : Int64] : String)
  (format "user-~a" id))
```

参数与返回值都会在 Racket 边界做类型校验。目前支持 `String`、`Int64`、`Bool`、`Bytes`、`Void`、`Any`、`(List T)` 和 `(Optional T)`。

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

## CLI

```text
raco rivet new <name>              创建新的 Rivet 应用
raco rivet doctor                  检查 Racket 与 native 工具链
raco rivet doctor --json           输出机器可读诊断
raco rivet clean                   删除 .rivet/build/dist 生成物
raco rivet build                   编译 backend、生成 client、构建 native host
raco rivet dev                     构建并运行当前应用
raco rivet package                 创建并验证开发发布物
raco rivet package --production    创建、签名并验证正式发布物
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
└── macos-host/
    ├── Package.swift
    └── Sources/
        └── RivetHost/
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
│   └── macos/
│       ├── Sources/          # Swift protocol/client + C embedding bridge
│       └── host/             # SwiftUI 模板
├── tests/
└── docs/
```

## 测试

```bash
raco test tests/
cmake -S runtime -B runtime/build
cmake --build runtime/build
ctest --test-dir runtime/build
swift test --package-path platform/macos
```

CI 会在 Windows、macOS、Linux 上验证协议实现；在 Windows/macOS 上执行真实 embedded Racket round-trip，并对新生成项目运行 build、package、verify、clean smoke。

## 诚实的局限

- **当前没有 Linux host** —— Rivet 的目标是 Windows/macOS 第一方 UI，而不是统一跨平台控件。
- **Windows 先支持 x64** —— runtime 打包链稳定后再扩展其他架构。
- **没有统一声明式跨平台 UI DSL** —— UI 代码仍然直接写 SwiftUI/AppKit 或 WinUI 3/C++/WinRT。
- **正式发布凭据仍属于应用自身** —— Rivet 已自动化 Authenticode、Developer ID、notarization 流程，但证书、PFX 密码、Apple notary profile 会由应用/CI 环境注入，不由 Rivet 保存。
- **Public API 仍处于 pre-1.0** —— 协议有版本控制，但高层 API 仍可能继续调整。

## 路线图

- [x] **Phase 1** —— Racket / C++ / Swift 三端 RVT1 协议
- [x] **Phase 2** —— Windows 与 macOS 嵌入 Racket CS
- [x] **Phase 3** —— Typed RPC、Event、State、Cancel、Swift/C++ codegen
- [x] **Phase 4** —— `new` / `doctor` / `build` / `dev` / `package`
- [x] **Phase 5** —— 发布物验证、生产签名/公证入口与 tag-driven release engineering
- [ ] **Phase 6** —— 更多架构、更丰富 schema/codegen 类型与长期协议兼容工具

## 许可证

基于 [MIT License](LICENSE) 发布。
