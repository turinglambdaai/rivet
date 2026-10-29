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

## 可选持久化测试配置（尚非默认交互承诺）

Taskboard **默认仍只保留本次运行的数据**，直到 #347 要求的三个平台原生编辑/保存、
关闭重启以及失败恢复验收全部通过。为了用隔离目录测试持久化，在启动打包宿主或
`raco rivet dev` **之前**将 `RIVET_TASKBOARD_STORE_PATH` 设为明确的可写文件：

```bash
RIVET_TASKBOARD_STORE_PATH=/tmp/rivet-taskboard-test/tasks.rktd raco rivet dev
```

Windows PowerShell 可先设置：
`$env:RIVET_TASKBOARD_STORE_PATH = "$env:TEMP\\rivet-taskboard-test\\tasks.rktd"`。
启用后，任务修改成功时原子替换有大小上限、带版本信息的本地数据快照；使用**相同路径**
重启后端会恢复任务。磁盘写入失败会返回 RPC 错误，不会错误报告内存保存成功；
数据文件损坏或版本未知时启动会报错，不会悄悄丢弃并覆盖已有任务。
快照属于本地用户数据，不是应用安装资源；原子替换不等于断电级 fsync 保证。
应明确备份或删除隔离测试文件，不要让自动化测试碰真实用户配置。在 #347 跨平台验收完成前，
原生 UI **不能**将会话内更新宣传为持久保存。

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

生成的 Swift Record 与 Enum 统一位于 `RivetTypes` 下，因此 `Task`、`Result`
等普通领域名称不会在整个模块中遮蔽 Swift 并发或标准库类型。本例仍使用语义
更明确的 `BoardTask`，macOS 宿主通过 `RivetTypes.BoardTask` 引用它。公共
schema 命名仍是跨语言 API 设计，不只是 Racket 内部命名。

本项目也展示 Apple companion 的最小权限边界。`rivet.rktd` 只通过
`device-rpcs` 导出 `list-tasks`、`get-task` 与 `select-task`，所有修改操作仍由
手机端掌控。生成的 Swift 文件因此包含 Codable 的
`RivetTypes.BoardTask`/`RivetTypes.TaskStatus`、
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
