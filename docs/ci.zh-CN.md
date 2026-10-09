# 持续集成

每个第一方原生宿主都必须在拉取请求 CI 中完成编译。只运行 Racket
测试、schema 检查或打包演练，并不能证明 WinUI、SwiftUI 或 GTK 源码仍可
编译。若第一次原生编译发生在打标签后的发布任务中，普通编译错误就会变成
发布事故。

CI 应使用与发布任务相同类别的 runner 和工具链：

- Windows：用 `windows-latest` 编译 WinUI 3 宿主；
- macOS：同时使用 `macos-latest` 与 `macos-15`，分别覆盖当前 Swift 和
  固定的 Xcode 16 发布环境；
- Linux：用 `ubuntu-latest`，安装 GTK4 开发文件，并准备可嵌入的 Racket
  CS runtime。

`raco rivet build` 是必需的宿主编译门禁。若还要验证分发布局，可继续执行
`package` 与 `verify`。发布者证书和公证凭据不应进入拉取请求 CI；这里使用
开发打包，把 `--production` 留给受保护的发布环境。

## 可直接使用的 GitHub Actions 工作流

下面的工作流假设应用从 Racket Package Catalog 安装已发布的 `rivet` 包。
生产项目应固定 Racket 与 Rivet 版本，不能让 CI 和发布任务各自漂移。

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
      - run: raco pkg install --auto --no-docs rivet
      - run: raco rivet doctor
      - run: raco rivet schema check rivet-schema.json
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
      - run: raco pkg install --auto --no-docs rivet
      - run: raco rivet doctor
      - run: raco rivet schema check rivet-schema.json
      - run: raco rivet build

  linux-host:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - name: Set up embeddable Racket CS
        uses: turinglambdaai/rivet/.github/actions/setup-embed-racket@main
      - name: Install GTK4 development files
        run: |
          sudo apt-get update
          sudo apt-get install --yes libgtk-4-dev
      - run: raco pkg install --auto --no-docs rivet
      - run: raco rivet doctor
      - run: raco rivet schema check rivet-schema.json
      - run: raco rivet build
```

对安全要求高的产品，应把 `@main` 改成应用使用的 Rivet 标签或完整 commit
SHA。该 action 会下载官方 minimal Racket CS 源码归档、校验 SHA-256、按
版本/系统/架构构建并缓存静态嵌入 runtime，然后导出
`RIVET_RACKET_INCLUDE`、`RIVET_RACKET_LIB_DIR`、
`RIVET_RACKET_LIBRARY` 和 `RIVET_RACKET_BOOT_DIR`。产品工作流不应再复制
这套探测脚本。

若应用安装的是 link 或 Git checkout 版本的 Rivet，应让 checkout 与 setup
action 固定到同一 revision。用一个 Rivet revision 编译宿主、再用另一个
revision 发布，不构成有效门禁。

## 发布门禁

推送标签前，应要求上述所有原生宿主任务和产品自己的 Racket 测试通过。
受保护的发布任务再负责正式打包、签名、公证、更新 manifest 签名与产物发布；
它不应该是第一次调用原生编译器的任务。

如果发布流程有意固定旧 runner 或 Xcode 镜像，就在拉取请求矩阵中保留同一
镜像，直到发布环境升级。runner 标签会随时间变化；真正的契约是与产品实际
发布工作流保持一致。
