# Rivet Taskboard

Rivet Taskboard 是用于学习 Rivet 原生桌面应用架构的长期维护参考项目。
[English](README.md)

自动生成的 counter 仍然负责最快速地验证工具链；这个参考项目则继续向下走：
Windows、macOS、Linux 分别使用 WinUI 3、SwiftUI、GTK4 实现真实的列表/详情
工作流，Racket 后端统一承载 Record、Enum、RPC、Event、State、资源、校验与取消。

## 从源码运行

在 Rivet 仓库根目录执行一次 link 安装，然后进入示例：

```bash
raco pkg install --auto --name rivet --link .
cd examples/taskboard
raco rivet inspect --json
raco rivet doctor
raco rivet dev
```

`doctor` 会报告当前操作系统缺少的原生开发组件；`dev` 会编译后端、重新生成
类型化客户端、构建当前平台 UI、装配精确匹配的 Racket CS runtime 并启动应用。

三个平台使用同样的信息架构：任务列表、任务详情、状态操作、样例数据重载，
以及带明确取消操作的 1000 行有界负载。控件和平台行为没有共享代码。

## 按这个顺序阅读

1. [`app/backend.rkt`](app/backend.rkt) 是产品契约。`BoardTask`、
   `ImportProgress` 是命名 Record，`TaskStatus` 是 Enum，RPC 负责输入校验与
   任务状态迁移。
2. [`rivet-schema.json`](rivet-schema.json) 是由契约生成并纳入版本管理的兼容性基线。
3. 阅读当前平台的 UI：
   - Windows：[`windows/MainWindow.xaml`](windows/MainWindow.xaml) 与
     [`windows/MainWindow.xaml.cpp`](windows/MainWindow.xaml.cpp)
   - macOS：[`macos-host/Sources/RivetHost/ContentView.swift`](macos-host/Sources/RivetHost/ContentView.swift)
     与 [`RivetHostApp.swift`](macos-host/Sources/RivetHost/RivetHostApp.swift)
   - Linux：[`linux/src/main.cpp`](linux/src/main.cpp)
4. [`tests/backend.rkt`](tests/backend.rkt) 会驱动真实 RVT1 server，验证 CRUD、
   State/Event、打包资源、输入上限、取消以及宽松的启动/1000 行性能回归预算，
   而不是模拟传输层。

公开记录使用 `BoardTask` 而不是 `Task`，是为了避免生成的 Swift 类型与并发
`Task` 冲突。公共 schema 命名是跨语言 API 设计，不只是 Racket 内部命名。

本项目也展示 Apple companion 的最小权限边界。`rivet.rktd` 只通过
`device-rpcs` 导出 `list-tasks`、`get-task` 与 `select-task`，所有修改操作仍由
手机端掌控。生成的 Swift 文件因此包含 Codable 的 `BoardTask`/`TaskStatus`、
手表端类型化 client 方法，以及手机端的
`RivetDeviceRouter.registerGeneratedBackend`。

## 完成第一次修改

打开 [`app/backend.rkt`](app/backend.rkt)，在 `initial-tasks` 中修改任意任务的
标题或说明，然后执行：

```bash
raco test tests/backend.rkt
raco rivet schema check rivet-schema.json --json
raco rivet dev
```

只改变文本行为不会破坏 schema。如果你有意新增 RPC、Record 字段、Event 或
State，请重新生成并认真检查基线：

```bash
raco rivet schema --output rivet-schema.json
git diff -- rivet-schema.json
```

不要为了消除破坏性变更报告而盲目刷新基线；Record 字段顺序具有线协议语义。

## 跟踪一次完整交互

点击 **Generate 1,000**，随后点击 **Cancel**：

1. 原生 UI 调用生成客户端的 `generate-demo-tasks` 方法。
2. Racket 校验 1000 条上限，并发送有界进度 Event。
3. 原生客户端保留 RVT1 request id，收到取消操作后发送 Cancel。
4. Rivet 停止该请求的 custodian，并返回 `request cancelled`。
5. 后端只在全部生成结束后提交新的任务 State，因此取消不会留下半成品列表。

这条路径展示了为什么取消和状态所有权应属于框架契约，而不是由三个 UI 各自临时实现。

任务进入 **Done** 后，三个原生 host 都会调用 Rivet 的通知系统服务。用户拒绝
授权、Linux 缺少 session bus 或通知服务不可用时不会把已成功的领域操作变成失败；
任务状态仍会正常显示在列表中。

## 无障碍与性能契约

三个 host 提供同一组稳定标识，包括 `task-list`、`task-title`、`advance-task`、
`generate-demo` 与 `cancel-generation`。WinUI 使用 automation ID，SwiftUI 使用
accessibility identifier，GTK4 使用稳定 widget name 和 accessible label。Tab 与
方向键导航直接采用各平台的标准焦点和列表行为，不另造跨平台键盘抽象。

[`PERFORMANCE.zh-CN.md`](PERFORMANCE.zh-CN.md) 定义了启动和 1000 行场景的预算、
计时边界与平台证据记录方法；RVT1 行为测试会在仓库测试中持续约束后端部分。

## 分享前验证

```bash
raco rivet build
raco rivet package
raco rivet verify
```

打包样例数据来自 [`assets/sample-tasks.rktd`](assets/sample-tasks.rktd)，后端通过
`resource-path` 读取，并由 [`rivet.rktd`](rivet.rktd) 中的 `resources` 声明装入
交付物。框架层说明见[快速上手](../../docs/getting-started.zh-CN.md)与
[架构文档](../../docs/architecture.md)。
