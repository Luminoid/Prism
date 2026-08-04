# Prism — Claude Code Guide

> Shared camera pipeline Swift Package with targets PrismCore and PrismUI.
> AVFoundation, CoreMedia, Metal, CoreImage. Swift 6.2, iOS 18+.

## Targets

| Target | Dependencies | MainActor | Contents |
|--------|-------------|-----------|----------|
| PrismCore | — | No (mix of `@PRMCameraActor`, `@MainActor`, and free types) | Camera (actor + facade), Capture, Device extensions, Filter pipeline, Utilities |
| PrismUI | PrismCore | Yes (`defaultIsolation(MainActor)`) | Metal preview view + UIKit camera components |

**No external SPM dependencies.** The package was previously dependent on SnapKit; PrismUI's three components that used it (`PRMSettingsDrawerView`, `PRMSettingsRow`, `PRMLevelIndicatorView`'s docstring example) were converted to raw `NSLayoutConstraint`. The Example app continues to use SnapKit for its own layout — that's a private demo dependency, not a library one.

## Concurrency model

- `@globalActor PRMCameraActor` (in `Sources/PrismCore/Camera/PRMCameraActor.swift`) serializes every `AVCaptureSession` mutation.
- `PRMCameraSession` is annotated `@PRMCameraActor` and owns the AVCaptureSession + outputs.
- `PRMCamera` is the `@MainActor` facade. UI code calls `await camera.start()`, `await camera.setZoom(...)`, etc., and subscribes to `camera.stateStream()` / `errorStream()` / `interruptionStream()` (all `AsyncStream`).
- AVCaptureSession property access from arbitrary actors uses `nonisolated(unsafe) let session = AVCaptureSession()` plus `@preconcurrency import AVFoundation` — AVCaptureSession is internally thread-safe but not declared `Sendable`.
- Frame delivery: `PRMFilterPipeline` is the `AVCaptureVideoDataOutputSampleBufferDelegate`. Frames come in on `PRMCameraSession.dataOutputQueue` (a dedicated serial queue). Pipeline exposes both callback (`onFrame`) and `AsyncStream<PRMVideoFrame>` delivery.
- Preview view (`PRMPreviewView`) uses a lock-protected `latestPixelBuffer`. `MTKView` polls it via its built-in display link — no per-frame Task hop.

## Architecture conventions

- **`PRM` prefix** for all public types, **`prm_`** for AVFoundation extension methods.
- **No LumiKit dependency** — fully standalone package.
- **Value-type filters** — `PRMFilter` is a `Sendable` protocol with no `AnyObject` requirement; all 18 built-in filters are structs (17 generic + `PRMPortraitBokehFilter`).
- **Composition over inheritance** — `PRMBasicFilterRenderer(context:description:filterFactory:)`, no per-filter subclasses.
- **No `PHPhotoLibrary`** in the library — capture helpers deliver data/URLs and consuming apps save.
- **One CIContext per pipeline** — `PRMRenderContext` wraps a shared Metal-backed `CIContext` with `.cacheIntermediates: false` (per WWDC '20).
- **Modern rotation** — `PRMRotationCoordinator` wraps `AVCaptureDevice.RotationCoordinator` (iOS 17+); the old `UIDeviceOrientation`-based mapping in `AVCapture+PRM` is gone.
- **iOS 17/18 photo features** — `enableResponsiveCapture`, `enableAutoDeferredPhotoDelivery`, `enableZeroShutterLag` on `PRMCameraConfiguration`.

## Source Structure

```
Sources/PrismCore/
├── Camera/      PRMCameraActor, PRMCamera, PRMCamera+Observers, PRMCameraSession,
│                PRMCameraSession+Format, PRMCameraConfiguration, PRMCameraDevice,
│                PRMCameraState, PRMRotationCoordinator, PRMPermissions, PRMSessionError
├── Capture/     PRMPhotoCapture (still / Live Photo / Portrait / burst),
│                PRMPhotoSettings, PRMPhoto, PRMLivePhoto, PRMPortraitPhoto,
│                PRMNightModeCapture, PRMVideoRecorder, PRMRecording, PRMDepthCapture
├── Device/      AVCaptureDevice+Zoom/Torch/Exposure/WhiteBalance/FrameRate/ISO/Lens/HDR,
│                AVCaptureConnection+Stabilization, PRMLens
├── Filter/      PRMFilter, PRMFilterRenderer, PRMBasicFilterRenderer,
│                PRMFilterChain, PRMFilterPipeline, PRMBufferPoolAllocator,
│                PRMRenderContext, PRMVideoFrame,
│                Filters/{Color,Blur,Stylize,Distortion,PortraitBokeh}
└── Utilities/   PRMLogger, PRMStreamRegistry, PRMTempFile, PRMImage

Sources/PrismUI/
├── Preview/     PRMPreviewView, Shaders/PassThrough.metal
└── Components/  PRMShutterButton, PRMFocusIndicatorView, PRMGridView,
                 PRMLevelIndicatorView, PRMAspectRatioMaskView, PRMCaptureEventHelper,
                 PRMSettingsDrawerView, PRMSettingsRow
```

**File-organization notes:**
- `PRMCamera+Observers.swift` owns the four KVO + NotificationCenter wirings (session.isRunning, device-commit, runtime error, interruption). Split off the main facade to keep `PRMCamera.swift` focused on device-mutation public methods.
- `PRMCameraSession+Format.swift` owns the high-res / Live-Photo-compatible / depth-capable format-selection logic (the 48MP promotion path + Live-Photo restore + auxiliary-flag reconciliation). Pulled out so the session file stays focused on lifecycle.
- `PRMStreamRegistry<T>` consolidates the UUID-keyed continuation dictionary + `onTermination` cleanup pattern used by ``PRMCamera`` (state / error / interruption), ``PRMRotationCoordinator`` (preview / capture angles), and ``PRMFilterPipeline`` (frames).

## Build & Test

PrismUI (UIKit + Metal) requires `xcodebuild`:

```bash
xcodebuild build -scheme Prism-Package -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2' CODE_SIGNING_ALLOWED=NO
xcodebuild test  -scheme Prism-Package -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2' CODE_SIGNING_ALLOWED=NO
```

```bash
make check   # SwiftLint + SwiftFormat
```

> The scheme is `Prism-Package` (auto-generated from Package.swift), not `Prism`. Don't simplify or restructure Package.swift: past simplification attempts made the scheme disappear.

## Test Structure

- **142 tests / 44 suites at v0.1.0 (release figure)** — Swift Testing (`@Test`, `#expect`, `@Suite`)
- Tests mirror source structure exactly
- The intensity-blend correctness fix is verified with golden pixel-comparison tests in `PRMFilterChainTests`
- Device-touching paths (`AVCaptureDevice` extensions, `PRMPhotoCapture`/`PRMVideoRecorder`/`PRMDepthCapture` start/stop) can't run on simulator — `AVCaptureDevice.default(for:)` returns `nil`. Those modules are covered via **value-type tests** (enums, structs, presets), **API surface locks** (`KeyPath` lookups that fail to compile on signature drift), and **Sendable conformance checks** (`Task.detached` round-trips). Full hardware paths are exercised via the example app + manual test plan.

## Critical lessons / non-obvious details

- **`@preconcurrency import AVFoundation`** is required in files that need to pass non-`Sendable` AVFoundation types across actor boundaries (PRMCameraSession, PRMCamera, PRMPhotoCapture, and the example app's StudioViewController).
- **AVCaptureSession is not Sendable**, but its internal queue serializes access. Use `nonisolated(unsafe) let session = AVCaptureSession()` on `@PRMCameraActor` classes.
- **The filter chain intensity bug** in the prior implementation: it called `composited(over:)` then `applyingFilter("CISourceOverCompositing", parameters: [:])` (no-op without `inputBackgroundImage`), then re-composited onto the **original source image** instead of the previous step's output. The fix uses `CIBlendWithMask` with a constant-color mask against the previous step's output for a correct `mix(prev, filtered, intensity)`.
- **`isEmpty` SwiftFormat rule**: the `--enable isEmpty` rule auto-rewrites `count == 0` to `.isEmpty`. Any custom collection-like type used in tests needs an `isEmpty` property to satisfy this. `PRMFilterChain` exposes both `count` and `isEmpty`.
- **iOS only** — Mac Catalyst was dropped at v0.1.0: Catalyst is API_UNAVAILABLE on `AVCaptureDeferredPhotoProxy`, Live Photo, and `AVCapturePhotoOutput.captureReadiness`, which are core Prism features. Most other AVCaptureDevice APIs (`minISO`, `maxExposureTargetBias`, `WhiteBalanceGains`, `videoZoomFactor`, depth APIs) are also `API_UNAVAILABLE(macos)`. The 33 remaining `#if !os(macOS)` guards are kept as documentation of which calls would crash if anyone re-introduced a Mac target; they're inert dead branches under the iOS-only build.
- **Metal toolchain**: Apple sometimes requires a separate download (`xcodebuild -downloadComponent MetalToolchain`) the first time you build PrismUI's shader.
- **PrismUI `defaultIsolation(MainActor)`**: this Package.swift setting makes every nested type in PrismUI MainActor-isolated. UI test suites must be `@MainActor` to use `Equatable` etc. on these types.

## Example App

- **Three screens** in `Example/PrismExample.xcodeproj`: `PermissionsViewController`, `StudioViewController` (DSLR), `FilterChainViewController`.
- The example exercises every public API surface of PrismCore + PrismUI.
- Edit `Example/project.yml` (XcodeGen) — never edit `project.pbxproj` directly.
- **Never commit `DEVELOPMENT_TEAM`** — set to `""` or omit.

## Key build settings (Package.swift)

- `swift-tools-version: 6.2`
- `platforms: [.iOS(.v18)]`
- PrismCore: `enableExperimentalFeature("StrictConcurrency")`
- PrismUI: `defaultIsolation(MainActor)` + `enableExperimentalFeature("StrictConcurrency")`

---

*Last updated 2026-05-22 — SnapKit removed from the library (Example app keeps its own SnapKit dep). Format-management split into `PRMCameraSession+Format.swift`, observer wiring into `PRMCamera+Observers.swift`, and async-stream plumbing consolidated behind `PRMStreamRegistry<T>`. PrismUI components rewritten on raw `NSLayoutConstraint`. 142 tests / 44 suites at v0.1.0 (release figure).*
