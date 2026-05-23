# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-05-22

Initial release. Camera pipeline Swift Package for iOS 18+, built on Swift 6.2 strict concurrency.

### Targets

- **PrismCore** (no UI dependency): Camera, Capture, Device extensions, Filter pipeline, Utilities.
- **PrismUI** (depends on PrismCore, `defaultIsolation(MainActor)`): Metal preview view + UIKit camera components. Raw `NSLayoutConstraint` only, no SnapKit.

### Camera (PrismCore/Camera)

- `PRMCameraActor` global actor serializing every `AVCaptureSession` mutation.
- `PRMCameraSession` (`@PRMCameraActor`) owns the AVCaptureSession + outputs. Format-selection logic split into `PRMCameraSession+Format.swift` (48MP promotion, Live-Photo-compatible reconciliation, depth/matte format selection).
- `PRMCamera` `@MainActor` facade with async/await mutations and `AsyncStream` event delivery: `stateStream()`, `errorStream()`, `interruptionStream()`. Observers wired in `PRMCamera+Observers.swift` (session.isRunning KVO, device-commit, runtime error, interruption).
- `PRMRotationCoordinator` wraps iOS 17+ `AVCaptureDevice.RotationCoordinator` with `AsyncStream<CGFloat>` for preview + capture angles. Replaces the legacy `UIDeviceOrientation`-based path.
- `PRMCameraConfiguration` exposes `maxPhotoQualityPrioritization`, `enableResponsiveCapture`, `enableAutoDeferredPhotoDelivery`, `enableZeroShutterLag`, `enableMultitaskingCameraAccess`, `enableLivePhoto`, `enableDepthDataDelivery`, `enablePortraitEffectsMatteDelivery`, `preferredVideoStabilizationMode`, configurable device-type preference list (triple / dual / dual-wide / wide-angle).
- `PRMCameraDevice` Sendable snapshot of device identity + capabilities.
- `PRMCameraState` live telemetry (zoom, exposure, ISO, shutter, WB Kelvin/tint, lens position, focus mode, HDR/low-light state).
- `PRMPermissions` async camera + microphone authorization.
- `PRMSessionError` typed error surface.

### Capture (PrismCore/Capture)

- `PRMPhotoCapture` async/await still capture (`capturePhoto`, `capturePhotoData`), Live Photo (`captureLivePhoto`), Portrait (`capturePortraitPhoto`), burst (`captureBurst`), Night-mode (`captureNight`). Lock-protected `pendingCaptures` dictionary keyed by `AVCaptureResolvedPhotoSettings.uniqueID`. Cancellable.
- `PRMPhotoSettings` fluent builder: format, flash, redEyeReduction, qualityPrioritization, livePhoto, portraitEffectsMatte, depth, constantColor, autoVirtualDeviceFusion, autoStillImageStabilization.
- `PRMPhoto` / `PRMLivePhoto` / `PRMPortraitPhoto` result types. `PRMNightModeCapture` for multi-frame averaging long-exposure composites.
- `PRMVideoRecorder` async start/stop with `PRMRecording` result + URL.
- `PRMDepthCapture` enables/configures depth data delivery on the photo output.

### Device extensions (PrismCore/Device)

Namespace extensions on `AVCaptureDevice` (`prm_`) and `AVCaptureConnection`:

- **Zoom**: `prm_setZoom`, `prm_lenses`, `prm_focalLength35mm`.
- **Torch**: `prm_setTorch`.
- **Exposure**: `prm_setExposureBias`, `prm_setExposureMode`, `prm_setCustomExposure`, `prm_setFocusAndExposure`.
- **WhiteBalance**: `prm_setWhiteBalanceMode`, `prm_lockWhiteBalance`, `prm_currentTemperatureAndTint`.
- **FrameRate**: `prm_setFrameRate`, `prm_resetFrameRate`, `prm_supportsSlowMotion`.
- **ISO + Shutter**: `prm_setISO`, `prm_setShutterSpeed`, `prm_isoRange`, `prm_shutterSpeedRange`.
- **Lens**: `prm_setFocusMode`, `prm_setLensPosition`, `prm_setLensPositionAsync`.
- **HDR + Low-light**: `prm_setVideoHDR`, `prm_setLowLightBoost`, `prm_isLowLightBoostActive`.
- **Stabilization**: `AVCaptureConnection.prm_setStabilization`.
- `PRMLens` Sendable struct (focal length + position + opt-in `snapping()` heuristic).

### Filter pipeline (PrismCore/Filter)

- `PRMFilter` Sendable value-type protocol, `func render(_ image: CIImage) -> CIImage`. No `AnyObject` requirement.
- `PRMRenderContext` wraps a shared Metal-backed `CIContext` (`.cacheIntermediates: false`, per WWDC '20). One context per pipeline.
- `PRMVideoFrame` Sendable struct of `CVPixelBuffer` + presentation timestamp.
- 20 built-in filter structs:
  - **Color** (7): Brightness, Contrast, Saturation, HueRotation, Grayscale, Sepia, Vignette.
  - **Blur** (3): GaussianBlur, MotionBlur, ZoomBlur.
  - **Stylize** (4): Pixellate, Comic, Pointillize, Edges.
  - **Distortion** (4): BumpDistortion, TwirlDistortion, PinchDistortion, VortexDistortion.
  - **PortraitBokeh** (1): matte- or depth-driven `CIDepthBlurEffect`.
  - **PassThrough** (1): identity filter for testing or chain endpoints.
- `PRMFilterChain` with correct per-filter intensity blending via `CIBlendWithMask` against the previous step's output. Exposes both `count` and `isEmpty`. Thread-safe.
- `PRMBasicFilterRenderer` accepts an injected `PRMRenderContext` and a `filterFactory: @Sendable () -> any PRMFilter` closure, composition over inheritance with no per-filter subclasses.
- `PRMFilterPipeline` is the `AVCaptureVideoDataOutputSampleBufferDelegate`, delivers frames via callback (`onFrame`) and `AsyncStream<PRMVideoFrame>`. Runs on `PRMCameraSession.dataOutputQueue`. `discardsLateVideoFrames = true`.
- `PRMBufferPoolAllocator` reuses `CVPixelBuffer` allocations through a `CVPixelBufferPool`.

### Utilities (PrismCore/Utilities)

- `PRMLogger` typed logging (`PRMLogCategory` enum) with `isVerboseTracingEnabled` build-time flag + `trace(_:_:)` autoclosure helper for AVF state-truth instrumentation.
- `PRMStreamRegistry<Element>` UUID-keyed continuation registry consolidating the `AsyncStream` plumbing used by `PRMCamera`, `PRMRotationCoordinator`, and `PRMFilterPipeline`.
- `PRMTempFile` scoped to `<tmp>/Prism/` (does not touch unrelated files in `NSTemporaryDirectory()`).
- `PRMImage` takes an injected `PRMRenderContext`; HEIF/JPEG encode helpers with sRGB color-space + extent-aware crop (handles infinite/empty extents from distortion filters).

### Preview view (PrismUI/Preview)

- `PRMPreviewView: MTKView` with lock-protected `latestPixelBuffer`; `MTKView`'s display link polls the latest frame so there is no per-frame Task or MainActor hop.
- `PassThrough.metal` shader for direct CVPixelBuffer to drawable blit.

### Components (PrismUI/Components)

- `PRMShutterButton` photo / video / recording-active states with tap + long-press for video.
- `PRMFocusIndicatorView` tap-to-focus + AF-converged animation.
- `PRMGridView` rule-of-thirds, golden ratio, square, Fibonacci spiral overlays.
- `PRMLevelIndicatorView` horizon level with cardinal-snap visual feedback.
- `PRMAspectRatioMaskView` letterbox mask for non-native aspect ratios.
- `PRMCaptureEventHelper` iOS 17.2+ camera-control button via `AVCaptureEventInteraction` (memoized).
- `PRMSettingsDrawerView` slide-in right-edge drawer with sectioned scroll, configurable fonts, mode handling.
- `PRMSettingsRow` collapsible row with SF Symbol header, value label, arbitrary content view.

### Tests

- 142 tests across 44 suites, Swift Testing (`@Test`, `#expect`).
- Tests mirror source structure exactly.
- Filter-chain intensity blend correctness verified with golden pixel-comparison tests.
- Device-touching paths covered via value-type tests, API-surface KeyPath locks, and Sendable round-trip checks (full hardware paths exercise via Example app and manual test plan, since `AVCaptureDevice.default(for:)` returns nil on simulator).

### Example app

- `Example/PrismExample.xcodeproj` (XcodeGen, edit `Example/project.yml`). Three screens:
  - `PermissionsViewController`.
  - `StudioViewController`, DSLR-grade camera in one screen, lens picker, telemetry strip, photo / live / portrait / pano / video / slo-mo / night modes, tap-to-focus, pinch-to-zoom, drag-to-bias-exposure, full settings drawer (EV / ISO / shutter sliders, WB Kelvin slider + preset chips, manual focus lens-position, HDR, low-light boost, stabilization, codec), 48MP toggle, burst, timer.
  - `FilterChainViewController`, interactive multi-filter editor with per-filter intensity sheet.
- Example app uses SnapKit for its own layout (private demo dependency, not a library one).

### Package

- `Package.swift`, `swift-tools-version: 6.2`, `.iOS(.v18)` only. Mac Catalyst was scoped in early development but dropped before v0.1.0, `AVCaptureDeferredPhotoProxy`, Live Photo, and `AVCapturePhotoOutput.captureReadiness` are `API_UNAVAILABLE(macCatalyst)`.
- No external SPM dependencies.
- PrismCore, `enableExperimentalFeature("StrictConcurrency")`.
- PrismUI, `defaultIsolation(MainActor)` + `enableExperimentalFeature("StrictConcurrency")`.
