# Rivet API 稳定性

Rivet 尚未到 1.0，但它的公开接口必须是有意设计的。`rivet`、
`rivet/app-info`、`rivet/backend`、`rivet/keel`、`rivet/protocol`、
`rivet/resources`、`rivet/system`、`rivet/distribution` 与 `rivet/testing`
的全部 phase-0 导出都由 `rivet/tests/public-api.rkt` 固定。

因此，API 变更必须是显式行为：

1. 同时修改实现与文档；
2. 有意更新公开导出快照；
3. 在 `CHANGELOG.md` 记录迁移方式；
4. 使用最低支持的 Racket 版本和当前开发基线运行完整 Racket 测试套件。

在 1.0 之前，如果不兼容变更能够消除设计陷阱或建立明显更清晰的长期契约，
则可以接受。1.0 之后，删除或改变公开绑定需要发布 major 版本；新增兼容 API
属于 minor 版本，兼容修复属于 patch 版本。

`String`、`Int64`、`Bool`、`(List T)` 等 Schema 类型标识符，是 Rivet
声明形式接受的语法，并不是导出的运行时值。工具应检查规范的 Keel
`app-schema`。
