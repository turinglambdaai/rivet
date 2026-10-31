# Rivet adoption and support

**English** · [简体中文](USING.zh-CN.md)

## When to use it

Choose Rivet when first-party native interaction is worth maintaining separate SwiftUI, WinUI 3 and GTK4 UIs. Racket owns shared domain logic; native hosts own rendering and OS interaction. For a shared HTML/CSS interface, evaluate Glaze instead.

## Requirements and maturity

Racket CS 9.0+ and the target platform’s native toolchain. Desktop delivery has explicit capability/acceptance classes; mobile runtime or companion foundations are not a generated, signed and packaged app workflow.

## One useful verification

Run inspect and doctor in the generated project, complete one backend mutation and observe its persisted result in the packaged native app. Keep one product interaction contract across hosts and adapt shortcuts, focus and window behavior to each OS. A unit test or screenshot alone does not establish product parity.

## Reading path

1. [First application](getting-started.md)
2. [Documentation map](README.md)
3. [API stability](api-stability.md)
4. [Product acceptance](product-acceptance.md)
5. [Release and updates](release-and-updates.md)

Technical references retain one normative meaning. Chinese onboarding explains and links to that reference rather than creating a second protocol.

## Upgrades, data and support

Record the package versions and platforms your application actually tests. Read CHANGELOG and compatibility contracts before upgrading, test user-data migration on copies and retain a recoverable version. A library does not supply your product’s database backup, publisher identity, refunds, account recovery or privacy policy. Example customer/offer identifiers and amounts are fixtures, not live offers.

Use [Issues](https://github.com/turlamai/rivet/issues) in English or Chinese. Include package/commit, Racket version, OS/architecture, a minimal reproduction and the first redacted error. Never attach real keys, customer credentials, raw payment data or private documents. Community support has no guaranteed response time.

[Private vulnerability reporting](../SECURITY.md).

[Current licence](../LICENSE) · [CHANGELOG](../CHANGELOG.md)
