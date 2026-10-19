# 持续集成

每个第一方原生宿主都必须在拉取请求 CI 中完成编译。只运行 Racket
测试、schema 检查或打包演练，并不能证明 WinUI、SwiftUI 或 GTK 源码仍可
编译。若第一次原生编译发生在打标签后的发布任务中，普通编译错误就会变成
发布事故。

CI 应使用与发布任务相同类别的 runner 和工具链：

- Windows：用 `windows-latest` 编译 WinUI 3 宿主；
- macOS：同时使用 `macos-latest` 与 `macos-15`，分别覆盖当前 Swift 和
  固定的 Xcode 16 发布环境；
- Linux：用 `ubuntu-24.04`，安装 GTK 4.10+ 开发文件，并准备可嵌入的 Racket
  CS runtime。

`raco rivet build` 是必需的宿主编译门禁。若还要验证分发布局，可继续执行
`package` 与 `verify`。发布者证书和公证凭据不应进入拉取请求 CI；这里使用
开发打包，把 `--production` 留给受保护的发布环境。

每个持续维护的产品还应提交 `rivet-acceptance.rktd`，并在每个原生平台 job
中运行 `raco rivet acceptance --json`。这份清单是可执行的完成定义：RackUnit、
生成客户端桥接测试、原生无障碍驱动和打包产品检查仍由各自层实现；Rivet 负责
拒绝缺少的声明覆盖、超时、非零退出码和缺失证据，并应在失败时归档 JSON 报告。
格式与使用方法见 [Product acceptance evidence](product-acceptance.md)。

## 可直接使用的 GitHub Actions 工作流

下面的工作流固定到 Rivet 0.11.0。升级时，应在同一次评审中把每处 Rivet
包来源和 Linux setup action 更新到同一个标签（或完整 commit）。这里有意
使用 Git 来源：Racket Package Catalog 对每个包名只保留一个当前入口，不能
选择较旧的 Rivet 版本。

```yaml
name: Native hosts

on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  windows-host:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v7
      - uses: Bogdanp/setup-racket@v1.15
        with:
          architecture: x64
          distribution: full
          variant: CS
          version: '9.3'
      - run: raco pkg install --auto --no-docs 'https://github.com/turinglambdaai/rivet.git#v0.12.0'
      - run: raco rivet doctor
      - run: raco rivet schema check rivet-schema.json
      - run: raco rivet acceptance --json > acceptance-report.json
        shell: bash
      - uses: actions/upload-artifact@v7
        if: always()
        with:
          name: acceptance-report-windows
          path: acceptance-report.json
      - run: raco rivet build

  macos-host:
    strategy:
      fail-fast: false
      matrix:
        runner: [macos-latest, macos-15]
    runs-on: ${{ matrix.runner }}
    steps:
      - uses: actions/checkout@v7
      - uses: Bogdanp/setup-racket@v1.15
        with:
          architecture: x64
          distribution: full
          variant: CS
          version: '9.3'
      - run: raco pkg install --auto --no-docs 'https://github.com/turinglambdaai/rivet.git#v0.12.0'
      - run: raco rivet doctor
      - run: raco rivet schema check rivet-schema.json
      - run: raco rivet acceptance --json > acceptance-report.json
        shell: bash
      - uses: actions/upload-artifact@v7
        if: always()
        with:
          name: acceptance-report-macos
          path: acceptance-report.json
      - run: raco rivet build

  linux-host:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v7
      - name: Set up embeddable Racket CS
        uses: turinglambdaai/rivet/.github/actions/setup-embed-racket@v0.12.0
      - name: Install GTK4 development files
        run: |
          sudo apt-get update
          sudo apt-get install --yes libgtk-4-dev
      - name: Install the matching Rivet package and dependencies
        run: raco pkg install --auto --no-docs 'https://github.com/turinglambdaai/rivet.git#v0.12.0'
      - run: raco rivet doctor
      - run: raco rivet schema check rivet-schema.json
      - run: raco rivet acceptance --json > acceptance-report.json
        shell: bash
      - uses: actions/upload-artifact@v7
        if: always()
        with:
          name: acceptance-report-linux
          path: acceptance-report.json
      - run: raco rivet build
```

每个 job 都把 `acceptance --json` 报告写入文件，并以
`acceptance-report-<platform>` 为名、`if: always()` 归档——失败的腿也要交出
证据。这些名字正是
[`raco rivet verify-remote`](product-acceptance.md#orchestrate-remote-verification-from-one-host)
的默认约定：在任一编辑主机上触发各平台腿、等待运行、下载归档报告并折叠成
验证矩阵。

Linux 中的顺序是必要条件：必须在 `setup-embed-racket` **之后**安装 Rivet。
该 action 准备的是刻意不附带任何包的 minimal Racket；此时再安装 Rivet，
`cext-lib`、`crypto-lib`、`keel` 等完整依赖才会进入嵌入式 runtime 实际读取的
包目录。如果先在 full Racket 下安装，这些依赖可能在那里显示为已满足，却没有
进入 minimal runtime；之后制作 backend bundle 就会失败，例如 `raco ctool`
实际由 `cext-lib` 提供。

若明确需要随开发分支移动，可把 Git 来源换回 catalog 包名 `rivet`，并把 setup
action 改为 `@main`。不要把这组配置当作发布版本固定：catalog 安装跟随当前
checksum，也不存在 `raco pkg install rivet@<version>` 这种历史版本选择器。
标准的版本保留方式就是上面带标签的 Git 来源；Racket 会把片段解释为 Git
revision，同时照常解析依赖。

绝不要让片段留空。`...rivet.git#` 这种裸 `#` 不会让安装失败：Racket 会把它
解析到默认分支，CI 于是对着移动的 `main` 编译，而工作流却以为自己在用固定
版本——曾经有过未定义的工作流变量产生空片段、并以此发版的事故。`#` 之后
永远固定到标签或 commit SHA，并在发布前运行 `raco rivet doctor --release`；
发布门禁会对空片段、与已安装 rivet 版本不符的标签片段、过期的生成文件、
以及用已安装 rivet 不接受的关键字调用更新 API 的宿主源码报错。

对安全要求高的产品，应把 action 标签换成该标签对应的完整 commit SHA，并在
包 URL 片段中使用同一个 commit。该 action 会下载官方 minimal Racket CS
源码归档、校验 SHA-256、按
版本/系统/架构构建并缓存静态嵌入 runtime，然后导出
`RIVET_RACKET_INCLUDE`、`RIVET_RACKET_LIB_DIR`、
`RIVET_RACKET_LIBRARY` 和 `RIVET_RACKET_BOOT_DIR`。产品工作流不应再复制
这套探测脚本。

本地开发 Rivet 时仍适合使用 link checkout；在 CI 中应让 checkout 与 setup
action 固定到同一 revision。用一个 Rivet revision 编译宿主、再用另一个
revision 发布，不构成有效门禁。

仓库中的 `Native UI End-to-End` 工作流还会打包维护中的 Taskboard，并分别
通过 WinUI 3 的 UI Automation、SwiftUI/AppKit 的 AXUIElement 和 GTK4 的
AT-SPI 检查真实原生界面。门禁覆盖窗口激活、一次 RPC 变更、一次 Event、
State 渲染与有序关闭；失败时保留有界的无障碍快照、交互轨迹、截图和日志。
应用如何复用这套模式，见[原生 UI 端到端测试](native-ui-testing.md)。

Rivet 自己的 Ubuntu 任务会通过 `.github/scripts/apt-retry.sh` 执行环境准备阶段的
`apt-get`。每次尝试都使用非交互模式、APT 网络与锁重试，并设有三分钟墙钟时间
上限；失败后只允许再换一次新尝试。产品 CI 也应采用同样的有界原则，避免软件源
卡住后耗尽整个原生构建预算。安装器生命周期测试仍直接执行原始包管理器事务，
因为事务结果本身就是这些测试要验证的行为。

## 发布门禁

推送标签前，应要求上述所有原生宿主任务和产品自己的 Racket 测试通过。
受保护的发布任务再负责正式打包、签名、公证、更新 manifest 签名与产物发布；
它不应该是第一次调用原生编译器的任务。

如果发布流程有意固定旧 runner 或 Xcode 镜像，就在拉取请求矩阵中保留同一
镜像，直到发布环境升级。runner 标签会随时间变化；真正的契约是与产品实际
发布工作流保持一致。
