# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added (full settings surface + new capture modes)

- **PrismCore/Capture**: `PRMLivePhoto` (paired still + movie sidecar), `PRMPortraitPhoto` (still + depth + portrait effects matte), `PRMNightModeCapture` (multi-frame averaging long-exposure), burst helper `PRMPhotoCapture.captureBurst(count:)`
- **PrismCore/Filter**: `PRMPortraitBokehFilter` (matte or depth-driven `CIDepthBlurEffect`)
- **PrismCore/Device**: `AVCaptureDevice+ISO.swift` (`prm_setISO`, `prm_setShutterSpeed`, `prm_isoRange`, `prm_shutterSpeedRange`), `AVCaptureDevice+Lens.swift` (`prm_setFocusMode`, `prm_setLensPosition`, `prm_setLensPositionAsync`), `AVCaptureDevice+HDR.swift` (`prm_setVideoHDR`, `prm_setLowLightBoost`, `prm_isLowLightBoostActive`)
- **PrismCore/Camera**: `PRMCamera` gains `setLensPosition(_:)`, `setISO(_:)`, `setShutterSpeed(seconds:)`, `setVideoHDR(_:)`, `setLowLightBoost(_:)`; `PRMCameraConfiguration` gains `enableLivePhoto`, `enableDepthDataDelivery`, `enablePortraitEffectsMatteDelivery`, `preferredVideoStabilizationMode`; `PRMCameraState` gains `lensPosition`, `isVideoHDREnabled`, `isLowLightBoostActive`; `PRMPhotoSettings` gains `livePhoto`, `portraitEffectsMatte`, `constantColorEnabled` builder methods
- **PrismUI/Components**: `PRMSettingsDrawerView` (slide-in right-edge drawer with sectioned scroll), `PRMSettingsRow` (collapsible row with SF Symbol header, value label, and arbitrary content view)
- **Example Studio**: full settings drawer wires every supported API (EV/ISO/shutter sliders, WB Kelvin slider + preset chips, manual focus lens-position slider, HDR auto/on/off, low-light boost, stabilization mode, codec); mode strip extends to PHOTO/LIVE/PORTRAIT/PANO/VIDEO/SLO-MO/NIGHT; top bar gains timer (3s/10s/off), burst toggle, and settings (`slider.horizontal.3`) chip

### Notes

- Panorama mode is wired into the UI but currently shows a "stitching not yet implemented" toast — frame accumulation + Vision stitching is a follow-up
- Live Photo capture requires `enableLivePhoto = true` on `PRMCameraConfiguration`; portrait depth requires `enableDepthDataDelivery` + `enablePortraitEffectsMatteDelivery`

### Breaking redesign — full API rewrite

Every public type has been reshaped against current Apple guidance (iOS 17+ `RotationCoordinator`, iOS 17/18 photo APIs, Swift 6.2 strict concurrency, WWDC '20 Core Image best practices). No source-compatible upgrade path; consumers should adopt the new API.

### Added

- **PrismCore/Camera**: `PRMCameraActor` (global actor serializing session work), `PRMCameraSession` (actor-isolated AVCaptureSession owner), `PRMCamera` (MainActor facade with `AsyncStream<PRMCameraState>`, async-await mutations), `PRMCameraDevice` (Sendable snapshot), `PRMCameraState` (live telemetry), `PRMRotationCoordinator` (wraps iOS 17+ `AVCaptureDevice.RotationCoordinator` with `AsyncStream<CGFloat>`), `PRMPermissions` (async camera/mic access), `PRMSessionError`
- **PrismCore/Capture**: `PRMPhotoCapture` (async-await `try await capturePhoto(...) -> PRMPhoto`), `PRMPhotoSettings` (fluent builder), `PRMPhoto`, `PRMVideoRecorder` (async start/stop), `PRMRecording`, `PRMDepthCapture`
- **PrismCore/Device**: namespace extensions on `AVCaptureDevice` (`prm_setZoom`, `prm_setTorch`, `prm_setExposureBias`, `prm_setExposureMode`, `prm_setCustomExposure`, `prm_setFocusAndExposure`, `prm_setWhiteBalanceMode`, `prm_lockWhiteBalance`, `prm_setFrameRate`, `prm_resetFrameRate`, `prm_lenses`, `prm_focalLength35mm`, `prm_currentTemperatureAndTint`, `prm_supportsSlowMotion`) and `AVCaptureConnection` (`prm_setStabilization`); `PRMLens` struct
- **PrismCore/Filter**: `PRMFilter` value-type protocol (`func render(_:) -> CIImage`, non-optional), `PRMRenderContext` (one Metal-backed `CIContext` per pipeline per Apple's WWDC '20 guidance), `PRMVideoFrame` Sendable struct, 17 built-in filter structs (Brightness/Contrast/Saturation/Hue/Grayscale/Sepia/Vignette/GaussianBlur/MotionBlur/ZoomBlur/Pixellate/Comic/Pointillize/Edges/Bump/Twirl/Pinch/Vortex), `PRMFilterChain` with **correct per-filter intensity blending** via `CIBlendWithMask`, `PRMBasicFilterRenderer` that accepts an injected render context, `PRMFilterPipeline` with both callback and `AsyncStream<PRMVideoFrame>` delivery
- **PrismCore/Utilities**: `PRMTempFile` (scoped to `<tmp>/Prism/` instead of nuking the whole tmp directory), `PRMImage` (takes a `PRMRenderContext`)
- **PrismCore/Configuration**: `PRMCameraConfiguration` now exposes `maxPhotoQualityPrioritization`, `enableResponsiveCapture`, `enableAutoDeferredPhotoDelivery`, `enableZeroShutterLag`, `enableMultitaskingCameraAccess`, configurable device-type preference list including triple/dual/wide-angle
- **PrismUI/Preview**: `PRMPreviewView` replaces `PRMPreviewMetalView` with simpler threading — a single lock-protected latest-frame buffer drawn on `MTKView`'s display link (no per-frame MainActor hop)
- **PrismUI/Components**: `PRMShutterButton` (photo / video / recording-active states with tap + long-press), `PRMFocusIndicatorView`, `PRMGridView` (now includes **Fibonacci spiral**), `PRMAspectRatioMaskView`, `PRMCaptureEventHelper` (iOS 17.2+ camera control button)
- **Example app**: collapsed from 8 screens to 3 — Permissions, **Studio** (DSLR-grade camera in one screen: lens picker, telemetry strip, photo/video/slow-mo modes, tap-to-focus, pinch-to-zoom, drag-to-bias-exposure), and Filter Chain (interactive multi-filter editor with intensity sheet)

### Changed (breaking)

- `PRMCameraSessionManager` → split into `PRMCameraSession` (actor) + `PRMCamera` (MainActor facade). State changes are now `AsyncStream<PRMCameraState>` instead of `PRMCameraDelegate` callbacks
- `PRMCameraFilter` (`AnyObject`, returns optional `CIImage?`) → `PRMFilter` (Sendable struct, returns non-optional `CIImage`)
- `PRMCameraFilterRenderer` → `PRMFilterRenderer`
- `PRMPhotoCaptureProcessor` (NSObject + four callbacks) → `PRMPhotoCapture` with `try await capturePhoto(settings:applying:context:willCapture:) -> PRMPhoto`
- `PRMPhotoSettingsBuilder` → `PRMPhotoSettings` (drops deprecated `isAutoStillImageStabilizationEnabled` flag; replaced by `qualityPrioritization`)
- `PRMVideoCaptureHelper` → `PRMVideoRecorder` with async `start` / `stop`
- `PRMDepthHelper` → `PRMDepthCapture` (semantic same)
- `PRMPermissionHelper` → `PRMPermissions` (semantic same)
- `PRMFileHelper` → `PRMTempFile` (now scopes cleanup to a `Prism/` subdirectory; the old `clearTemporaryFiles()` deleted **everything** in `NSTemporaryDirectory()`)
- `PRMImageHelper` → `PRMImage` (now accepts a `PRMRenderContext`)
- `PRMPreviewMetalView` → `PRMPreviewView` (lighter threading)
- `PRMCameraButton` → `PRMShutterButton` (adds press-and-hold for video)
- `PRMCameraFocusView` → `PRMFocusIndicatorView`
- `PRMGridOverlayView` → `PRMGridView`
- `PRMAspectRatioOverlayView` → `PRMAspectRatioMaskView`
- `PRMCaptureControlHelper` → `PRMCaptureEventHelper`
- `PRMZoomHelper.LensInfo` → `PRMLens` (no longer applies the lowest-focal-length snap heuristic by default; call `lens.snapping()` to opt in)
- All six `PRM*Helper` enums (`PRMZoomHelper`, `PRMTorchHelper`, `PRMExposureHelper`, `PRMWhiteBalanceHelper`, `PRMStabilizationHelper`, `PRMFrameRateHelper`) → extension methods on `AVCaptureDevice` / `AVCaptureConnection`
- `AVCapture+PRM.swift` rotation-angle constants → removed (superseded by `PRMRotationCoordinator`)
- All 15 built-in filter classes (`final class @unchecked Sendable`) → structs (zero `@unchecked` annotations remaining in the built-in filter set)
- Platform support narrowed from `iOS / macCatalyst / macOS` to `iOS 18+ / macCatalyst 18+` (most camera AVFoundation APIs are unavailable on macOS native, and Mac Catalyst is the supported Mac path)

### Fixed

- **Filter chain intensity blending**: the previous implementation called `composited(over:)` followed by `applyingFilter("CISourceOverCompositing", parameters: [:])` (no `inputBackgroundImage` — a no-op) and then composited the result back over the **original** source image instead of the previous filter's output. Multi-filter chains with intermediate intensities silently discarded upstream work. The new implementation uses `CIBlendWithMask` against the previous step's output for a correct `mix(prev, filtered, intensity)` per step
- **`PRMFileHelper.clearTemporaryFiles()`** deleted every file in `NSTemporaryDirectory()`, not just Prism's. The replacement `PRMTempFile.clearAll()` only touches `<tmp>/Prism/`
- **Per-renderer `CIContext()`**: every `PRMBasicFilterRenderer` and `PRMFilterChain` allocated its own context. Now they share one `PRMRenderContext` per pipeline, bound to a Metal command queue with `.cacheIntermediates: false` per Apple's WWDC '20 guidance
- **Per-frame MainActor hop in preview**: `PRMPreviewMetalView.requestDraw()` dispatched a `Task @MainActor` per frame (60 hops/sec at 60 fps). The new `PRMPreviewView` uses an `MTKView` display link that polls a lock-protected latest buffer
- **Deprecated `isAutoStillImageStabilizationEnabled`**: removed from the photo settings builder (the property was deprecated in iOS 13 and ignored as of iOS 18)

### Removed

- `PRMCameraSessionManager`, `PRMCameraDelegate`, `PRMSessionSetupResult`, `PRMPhotoCaptureProcessor`, `PRMPhotoSettingsBuilder`, `PRMVideoCaptureHelper`, `PRMDepthHelper`, `PRMZoomHelper` / `PRMTorchHelper` / `PRMExposureHelper` / `PRMWhiteBalanceHelper` / `PRMStabilizationHelper` / `PRMFrameRateHelper`, `PRMCameraFilter`, `PRMCameraFilterRenderer`, `PRMFileHelper`, `PRMImageHelper`, `PRMPreviewMetalView`, `PRMCameraButton`, `PRMCameraFocusView`, `PRMGridOverlayView`, `PRMAspectRatioOverlayView`, `PRMCaptureControlHelper`, manual `PRMVideoRotationAngle` constants in `AVCapture+PRM`
- macOS native target (use Mac Catalyst instead)

### Stats after redesign

- 44 PrismCore source files + 9 PrismUI source files
- 41 test files / 138 tests across 44 suites, all passing on iOS Simulator
- Zero SwiftLint or SwiftFormat violations
- 3 example screens (down from 8)
