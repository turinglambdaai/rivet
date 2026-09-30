# Rivet 快速上手

这份教程的目标很明确：从一台刚装好开发环境的电脑开始，尽快跑起第一个 Rivet 原生应用，并最终得到可以分发的构建结果。脚手架保持最小化：共享的 Racket 后端 + Windows 的 WinUI 3 宿主 + macOS 的 SwiftUI 宿主。

## 1. 安装 Rivet

请使用你希望 Rivet 最终嵌入的那套 Racket CS 自带的 `raco`，从 Racket Package Catalog 安装：

```bash
raco pkg install --auto rivet
```

只有在开发 Rivet 框架本身时，才需要使用源码 link 安装：

```bash
git clone https://github.com/turinglambdaai/rivet.git
cd rivet
raco pkg install --auto --name rivet --link "$(pwd)"
```

确认 CLI 已安装：

```bash
raco rivet help
```

## 2. 创建第一个应用

```bash
raco rivet new hello-rivet
cd hello-rivet
```

新项目包含：

```text
hello-rivet/
├── rivet.rktd              # 应用标识、后端入口、最低系统版本
├── app/backend.rkt         # 两个平台共享的 Racket 业务逻辑
├── windows/                # WinUI 3 应用
└── macos-host/             # SwiftUI 应用
```

原生 UI 源码属于你的应用；Rivet 负责嵌入式 runtime bridge、RVT1 协议、native client 生成、构建编排、打包和验证。

## 3. 先让 `doctor` 检查环境

执行：

```bash
raco rivet doctor
```

环境完整时最后会看到：

```text
rivet: toolchain looks usable
```

如果缺少必要组件，`doctor` 会输出 **Fix next**，直接告诉你下一步应该安装或修复什么。处理完之后再次执行 `raco rivet doctor` 即可。

常见环境要求：

- **Windows：** Racket CS、Visual Studio 2022 或 Build Tools、Desktop development with C++ 和 Windows SDK。Windows App SDK 作为项目依赖由 Rivet 在原生构建时自动恢复。
- **macOS：** Racket CS 和 Apple/Xcode 开发工具链。

CI 或 Agent 需要结构化结果时：

```bash
raco rivet doctor --json
```

## 4. 直接运行脚手架应用

```bash
raco rivet dev
```

Rivet 会自动完成：编译 Racket 后端、生成 native client、构建当前平台宿主、部署精确匹配的 Racket CS runtime，然后启动应用。

默认窗口里有一个 Counter。点击 **Increment in Racket** 后，计数值会通过嵌入式 Racket 后端的共享 State 更新。这个简单操作实际上验证了整条链路：

```text
原生 UI → 生成的 client → RVT1 → Embedded Racket CS → State → 原生 UI
```

## 5. 修改第一段 Racket 后端代码

打开：

```text
app/backend.rkt
```

脚手架已经包含 Event 和 State：

```racket
(define-event notification : String)
(define-state counter : Int64 0)
```

可以加入一个类型化 RPC：

```racket
(define-rpc (greet [name : String] : String)
  (format "Hello, ~a!" name))
```

保存后再次运行：

```bash
raco rivet dev
```

构建阶段 Rivet 会读取后端 schema，并重新生成 Swift/C++ 类型化 API。你不需要自己拼 RVT1 帧，也不需要把 Racket/Chez 对象跨 UI 线程传递。

## 6. UI 应该从哪里改

### Windows

先看这两个文件：

```text
windows/MainWindow.xaml
windows/MainWindow.xaml.cpp
```

`MainWindow.xaml` 就是普通 WinUI 3 XAML。`MainWindow.xaml.cpp` 已经演示了如何启动 Embedded Racket backend，并用 completion-driven 的方式调用生成的 State API，避免阻塞 UI 线程。

### macOS

先看：

```text
macos-host/Sources/RivetHost/ContentView.swift
macos-host/Sources/RivetHost/RivetHostApp.swift
```

`ContentView.swift` 是正常 SwiftUI。脚手架中的 `AppModel` 负责 Embedded backend，并演示异步访问生成的 State API。

Rivet **不会**再定义一套跨平台 UI DSL。WinUI 3 和 SwiftUI 按各自平台的正常方式开发，真正需要共享的业务逻辑放在 Racket 中。

图片、模板、本地化文件等应用数据可以统一声明在 `rivet.rktd` 中，并由 Racket 通过 `resource-path` 读取。Rivet 会在开发和打包布局之间保持相同的相对路径，详见[项目配置](configuration.md#application-resources-and-icons)。

## 7. 构建、打包、验证

开发完成后：

```bash
raco rivet build
raco rivet package
raco rivet verify
```

`package` 在成功返回之前会先验证开发发布物；`verify` 可以稍后再次审计已经生成的发布物。

需要正式可信的发行包时：

```bash
raco rivet package --production
raco rivet verify --production
```

生产模式使用应用发布者自己的签名凭据。在 CI 中配置证书/Apple 凭据之前，请先阅读 [生产签名](production-signing.md)。

完整产品发布还需要单独配置 Ed25519 更新签名密钥并执行 `raco rivet release`。它会继续生成 MSI/DMG、签名 channel manifest、SBOM 和第三方许可声明，详见[发布与更新](release-and-updates.md)。

## 8. 日常真正需要记住的命令

通常只需要四条：

```bash
raco rivet doctor     # 新机器或环境异常时
raco rivet dev        # 日常编辑 / 构建 / 运行
raco rivet package    # 生成分发物
raco rivet verify     # 验证已有分发物
raco rivet release    # 生成完整签名发布物
```

其他文档按需阅读：

- [架构](architecture.md)
- [项目配置](configuration.md)
- [诊断](diagnostics.md)
- [协议](protocol.md)
- [嵌入模型](embedding.md)
- [发布物验证](package-verification.md)
- [生产签名](production-signing.md)
- [发布与更新](release-and-updates.md)
- [系统服务](system-services.md)

## 排查问题的第一原则

先运行 `raco rivet doctor`。如果工具链正常但 `dev`、`build` 或 `package` 失败，优先保留第一条 `rivet: error:` 以及它附近的 native compiler 输出。Rivet 的目标是尽可能在最早、最可操作的边界失败，而不是把原生构建错误隐藏成模糊提示。
