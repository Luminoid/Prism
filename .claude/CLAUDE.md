# Prism — Claude Code Guide

> Shared camera pipeline Swift Package with targets: PrismCore, PrismUI.
> **Inherits general Swift/UIKit standards from [workspace CLAUDE.md](../../.claude/CLAUDE.md).** This file contains Prism-specific rules only.

## Targets

| Target | Dependencies | MainActor | Contents |
|--------|-------------|-----------|----------|
| PrismCore | — | No | Session, Filter, Capture, Utilities |
| PrismUI | PrismCore, SnapKit | Yes | Metal preview, camera UI components |

## Architecture

- **PRMprefix** for all public types, `prm_` for extension methods
- **No LumiKit dependency** — fully standalone package
- **Composition over inheritance** — `PRMBasicFilterRenderer` uses factory closures, not subclasses
- **No PHPhotoLibrary** — capture processors deliver data/URLs, consuming apps save
- **Platform guards** — `#if canImport(UIKit)` for UIDevice/UIInterface orientation, `#if !os(macOS)` for iOS-only AVFoundation APIs (Live Photo, subject area change, interruption reason)
- **Modern APIs** — `videoRotationAngle` not deprecated `videoOrientation`

## Source Structure

```
Sources/PrismCore/
├── Session/    — PRMCameraSessionManager, PRMCameraConfiguration, PRMCameraDelegate, PRMSessionSetupResult
├── Device/     — PRMZoomHelper (+ LensInfo, focal length), PRMTorchHelper, PRMExposureHelper,
│                 PRMWhiteBalanceHelper, PRMStabilizationHelper, PRMFrameRateHelper
├── Filter/     — PRMCameraFilter, PRMCameraFilterRenderer, PRMBasicFilterRenderer, PRMFilterPipeline, PRMBufferPoolAllocator
├── Capture/    — PRMPhotoCaptureProcessor, PRMVideoCaptureHelper, AVCapture+PRM
└── Utilities/  — PRMLogger, PRMFileHelper, PRMImageHelper

Sources/PrismUI/
├── Preview/    — PRMPreviewMetalView, Shaders/PassThrough.metal
└── Components/ — PRMCameraFocusView, PRMCameraButton
```

## Build & Test

PrismUI (UIKit + Metal) requires `xcodebuild`:

```bash
xcodebuild build -scheme Prism-Package -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO
xcodebuild test -scheme Prism-Package -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO
```

PrismCore-only (pure Swift/AVFoundation) can use `swift build` / `swift test`.

```bash
make check  # SwiftLint + SwiftFormat
```

## Test Structure

- **19 test suites**, **138 tests** (92 PrismCore + 46 PrismUI)
- Tests mirror source structure: `Tests/PrismCoreTests/{Session,Filter,Capture,Utilities}/`
- Swift Testing framework (`@Test`, `#expect`, `@Suite`)
- Mock types: `MockFilter`, `MockRenderer`, `MockCameraDelegate`

## Key Patterns

- **Threading**: Session operations on `sessionQueue`, video frames on `dataOutputQueue`, UI on `MainActor`
- **Filter pipeline**: `PRMFilterPipeline` is the `AVCaptureVideoDataOutputSampleBufferDelegate` — routes frames through active renderer
- **Buffer pools**: `PRMBufferPoolAllocator` creates CVPixelBufferPools from format descriptions — validates 32BGRA format
- **Metal preview**: `PRMPreviewMetalView` uses `Bundle.module` for shader loading (SPM resource), syncQueue for thread-safe pixel buffer updates
- **Coordinate transforms**: `texturePoint(fromViewPoint:)` / `viewPoint(fromTexturePoint:)` for tap-to-focus
- **Focal length**: `PRMZoomHelper.lensInfos(for:)` returns `[LensInfo]` with zoom factors and 35mm-equivalent focal lengths. Raw focal length from `videoFieldOfView` overestimates by ~15% on virtual devices, so `snapToStandardFocalLength` picks the **lowest** matching phone camera focal length within 20% tolerance (e.g., 13, 24, 48, 77, 120mm). Buttons show physical mm, zoom label shows multiplier (e.g., `5.0×`). `focalLength35mm(for:atZoomFactor:)` gives the raw (unsnapped) approximation

---

*Optimized for Claude Code • Last updated: 2026-03-03*
