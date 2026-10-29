# Apple 发布就绪：按分发渠道检查

**[English](apple-release-readiness.md)** · 简体中文

Rivet 不能承诺苹果审核通过，也不能保证审核速度。本指南定义框架的预检能力、
证据边界和应用方的审核职责。正式提交前，必须重新核对
[苹果最新审核指南](https://developer.apple.com/app-store/review/guidelines/)。

## 先确定分发渠道

| 渠道 | Rivet 当前能力 | 尚需完成的发布验收 |
| --- | --- | --- |
| macOS 官网下载（Developer ID） | 已有 Developer ID 签名、公证、stapling 和 Gatekeeper 验证流程 | 使用正式发布凭据的 canary、真机干净安装、升级与恢复 |
| Mac App Store | 已有 SwiftUI/AppKit 桌面宿主，**尚无通过验收的商店归档/提交流程** | Xcode/商店签名、App Sandbox、商店更新、必要的 StoreKit 和实际商店安装 |
| iOS/iPadOS App Store | 已有 companion 与可移植 runtime 基础，**尚不能生成和签署独立 iOS 应用** | 无受限 JIT 的 Release 真机嵌入、预打包业务代码、签名、沙盒、生命周期和商店提交 |
| watchOS | 已有 WatchConnectivity relay 与 SwiftUI 基础 | 产品 Watch 应用、设备配对、打包、签名和审核 |

整个产品组合目前的 Mac 首选发布路径为 Developer ID 官网直接分发，
而不是自动转入 Mac App Store。参见
[全局分发政策](https://github.com/turlamai/turlamai.github.io/blob/master/docs/DISTRIBUTION.md)
与 Rivet [生产签名说明](production-signing.md)。

## 运行构建产物预检

在 Rivet 仓库中，对**实际生成的 macOS .app** 执行：

```bash
python3 .github/scripts/apple-review-preflight.py --channel developer-id --app dist/MyApp.app --json
# Mac App Store 仅是风险分类，不会产生可上架的商店归档：
python3 .github/scripts/apple-review-preflight.py --channel mac-app-store --app dist/MyApp.app --json
python3 .github/scripts/test-apple-review-preflight.py
```

这个只读脚本不需要开发者密钥。它检查 Info.plist、应用主可执行文件、
Bundle ID、隐私清单的基本结构；在 macOS 上还检查真实代码签名、
签名后的 entitlements、沙盒、调试权限与有风险的 hardened runtime 例外。
它**不能**替代 SDK/API 使用理由审查、隐私声明、商业方案、真机行为、商店
上传或用户体验验收。

JSON 协议版本是 `rivet.apple-review-preflight.v1`，包含 `blockers`、
`warnings`、`unverified`、`manual_review` 和 `status`。退出码 0
仅代表机器可执行的检查通过；1 表示发现阻塞；2 表示缺少关键平台证据。
任何一种结果均不表示苹果已经批准应用。正式 Developer ID 产物还应执行
`raco rivet verify --production` 检查公证票据与 Gatekeeper。

## 已知且必须验证的运行时例外

Rivet 当前 macOS 打包器会统一写入
`com.apple.security.cs.allow-unsigned-executable-memory=true`。
这不是假设风险，而是真实存在、需要最小权限审查的配置。新增预检会根据
实际签名后的 entitlement 提醒开发者，但调整默认值前，必须在 Apple
Silicon 与 Intel 的已打包应用上验证 Racket CS 启动及 RVT1 行为，
不能为了避免审核问题而未经测试直接禁用；Developer ID 公证不等于
Mac App Store 合规。

## Rivet 框架应承担

- 编译并打包全部可执行业务模块与签名依赖，禁止在审核后下载 Racket
  源码、字节码或插件来增加新功能；参考
  [2.5.2 条款](https://developer.apple.com/app-store/review/guidelines/#software-requirements)。
- 在**真实 iOS 设备的 Release 版本**验证嵌入式 Racket 不依赖受限 JIT
  或非法可执行内存。macOS 编译通过、iOS companion 测试通过都不算此项验收。
- 区分 Developer ID、Mac App Store 与 iOS 的签名、更新和发布渠道。
  不可把官网自动更新器或 Permit 自有授权码界面原样带入 Mac App Store。
- 向产品验收暴露 entitlements、沙盒数据目录、权限错误、隐私资源、
  打包依赖、原生无障碍和生命周期，并默认使用最小必要系统权限。

## 应用开发者必须承担

产品方需要核查 API/SDK 清单与隐私用途理由，提供真实的 App Privacy 信息、
隐私政策链接，测试权限请求、数据删除、更新恢复、账号、语言本地化，
以及适用时的 IAP 与购买恢复。
提交到 App Store Connect 时，提供能使用的审核账号或演示模式、
正常运转的服务、真实截图、测试设备与系统版本、功能说明；
依赖硬件的应用可能还需要真机演示视频。详见
[苹果审核材料指南](https://developer.apple.com/help/app-review/before-submitting-for-review/complete-review/)。

数字功能解锁应按[苹果支付规则及适用例外](https://developer.apple.com/app-store/review/guidelines/#business)
实施。Rivet 不负责选择产品的商业方案，也不代替 StoreKit。
如果没有真机和商店交付证据，状态必须仍为**未就绪**。
后续里程碑见[桌面收尾与移动端计划](desktop-closeout-mobile-plan.md)。
