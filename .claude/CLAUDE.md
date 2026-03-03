# Prism — Claude Code Guide

> Swift Package with targets: PrismCore, PrismUI.
> **Inherits general Swift/UIKit standards from [workspace CLAUDE.md](../../.claude/CLAUDE.md).** This file contains Prism-specific rules only.

## Targets

| Target | Dependencies | MainActor |
|--------|-------------|-----------|
| PrismCore | — | No |
| PrismUI | PrismCore, SnapKit | Yes |

---

## Build & Test

Targets with MainActor isolation (UIKit) require `xcodebuild`:

```bash
xcodebuild build -scheme Prism -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO
xcodebuild test -scheme Prism -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO
```

Foundation-only targets can use `swift build` / `swift test`.

```bash
make check  # SwiftLint + SwiftFormat
```

---

*Optimized for Claude Code \u{2022} Last updated: 2026-03-03*
