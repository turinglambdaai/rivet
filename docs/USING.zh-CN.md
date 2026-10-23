# Rivet 使用与支持

[English](USING.md) · **简体中文**

## 何时使用

当第一方原生交互值得维护 SwiftUI、WinUI 3、GTK4 三份界面时，选择 Rivet。共享领域逻辑归 Racket，渲染与系统交互归原生宿主。需要共享 HTML/CSS 界面时可评估 Glaze。

## 要求与成熟度

需要 Racket CS 9.0+ 和目标平台原生工具链。桌面交付有明确能力与验收分级；移动运行时或伴随端基础不等于已生成、签名和打包的应用工作流。

## 一次有效验证

在生成项目内运行 inspect 和 doctor，完成一个后端修改，并在打包原生应用中观察持久化结果。跨宿主保持一个产品交互契约，快捷键、焦点和窗口行为遵循各系统习惯。单元测试或截图本身不能证明产品一致性。

## 推荐阅读路径

1. [第一个应用](getting-started.zh-CN.md)
2. [文档地图](README.md)
3. [API 稳定性](api-stability.zh-CN.md)
4. [产品验收](product-acceptance.md)
5. [发行与更新](release-and-updates.md)

技术规范保持一个权威版本；链接目标为英文时，它仍是对应行为的定义，不是第二份中文协议。

## 升级、数据与支持

固定并记录应用实际测试的包版本和平台。升级前阅读 CHANGELOG 与兼容契约，在副本上测试用户数据迁移，并保留可恢复版本。框架或库不替产品提供数据库备份、发布证书、退款、账号恢复或隐私政策。不要把示例夹具中的客户、商品和金额当成真实 offer。

在 [Issues](https://github.com/turinglambdaai/rivet/issues) 反馈，中文或英文均可。包含包版本/提交、Racket 版本、系统架构、最小复现和已脱敏的首条错误。不要附带真实密钥、客户凭据、支付原始数据或私密文档。社区支持不承诺响应时限。

[敏感漏洞报告流程](../SECURITY.md)。

[现行许可证](../LICENSE) · [CHANGELOG](../CHANGELOG.md)
