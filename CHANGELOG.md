# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-10-09

iOS 26 and iOS 27 capture APIs, a rebuilt logging layer, and a round of capture, session and accessibility fixes. Building now requires Xcode 27 (Swift 6.4, iOS 27 SDK); the deployment target stays iOS 18, and every new API is availability-gated. Breaking changes are marked in Changed.

### Added

- **Priority modes and variable aperture (iOS 27)**: `PRMExposureValue`, `PRMExposureAxes`, `setExposure(aperture:shutterSeconds:iso:)`, `setShutterPriority(seconds:)`, `setISOPriority(_:)`, `setAperturePriority(_:)`, `setAutoApertureRateLimit(_:)`, `exposurePriorityAxes`; device helpers `prm_setExposure(aperture:shutterSeconds:iso:completion:)`, `prm_supportsExposure(...)`, `prm_lensApertureRange`, `prm_autoExposureAxes`, `prm_setAutoApertureRateLimit(_:)`. State `lensAperture`, `autoExposureAxes`; device `apertureRange`, `recommendedApertureStops`.
- **Exposure signals (iOS 27)**: `PRMExposureSignal`, `setExposureSignals(_:)`, `prm_setExposureSignals(_:)`, `prm_activeExposureSignals`; state `activeExposureSignals`, device `supportedExposureSignals`.
- **Lens lock (iOS 27)**: `lockLens(_:)`, `prm_lockPrimaryConstituent(to:)`, `prm_isPrimaryConstituentLocked`; state `isPrimaryConstituentLocked`, device `supportsPrimaryConstituentLock`.
- **Focus and exposure rects of interest (iOS 26)**: `setFocusAndExposure(focusMode:exposureMode:in:monitorSubjectAreaChange:)`, `defaultFocusRect(for:)`, `prm_setFocusAndExposure(focusMode:exposureMode:in:monitorSubjectAreaChange:)`, `prm_defaultFocusRect(for:)`, `prm_setExposurePointOfInterest(_:mode:)`; device `supportsFocusRectOfInterest`, `supportsExposureRectOfInterest`.
- **Calibrated white balance presets (iOS 26)**: `PRMWhiteBalancePreset.temperatureAndTint`.
- **Nominal focal lengths (iOS 26)**: `PRMLens.FocalLengthSource` / `focalLengthSource`, `prm_nominalFocalLength35mm`.
- **Subject tracking (iOS 27)**: `setContinuousAutoFocusTrackingEnabled(_:)`, `setContinuousAutoFocusTrackingBias(_:)`, `prm_setContinuousAutoFocusTracking(_:)`, `prm_setContinuousAutoFocusTrackingBias(_:retargetingAt:)` and the `prm_isContinuousAutoFocusTracking…` / `prm_continuousAutoFocusTrackingBias` properties; state for enabled, subject acquired and bias; device `supportsContinuousAutoFocusTracking`.
- **Detected objects**: `PRMDetectedObject`, `PRMMetadataRouter` (with `lastFocusTrackedObject`), `detectedObjectsStream()`, `setMetadataObjectTypes(_:)`, `PRMCameraConfiguration.includesMetadataOutput` and `metadataObjectTypes`.
- **Cinematic Video (iOS 26)**: `setCinematicVideoEnabled(_:targetPhotoOutputAttached:)`, `PRMCameraConfiguration.enableCinematicVideo`, `PRMCinematicFocusMode`, `PRMCinematicFocusRequest` with `setCinematicFocus(_:)` / `prm_setCinematicFocus(_:)`, `setCinematicSimulatedAperture(_:)`, `PRMSceneMonitoringStatus` / `prm_cinematicSceneStatuses`, format `prm_cinematicFrameRateRange` and `prm_simulatedApertureRange`, and on iOS 27 `PRMCinematicMetadataCapture` with `setCinematicMetadataCapture(_:)`. State `isCinematicVideoCaptureEnabled`, `cinematicSimulatedAperture`, `cinematicSceneStatuses`, `isCinematicVideoMetadataCaptureEnabled`; device `supportsCinematicVideo`, `cinematicVideoDeviceType`, `cinematicZoomRange`, `simulatedApertureRange`, `cinematicFrameRateRange`, and `PRMCameraDevice.cinematicVideoDeviceType(at:)`. Which cameras run Cinematic Video depends on the iPhone (Apple documents the back Dual Wide and front TrueDepth cameras; an iPhone 18 Pro Max runs it on the back wide camera), never the Triple camera Pro iPhones open by default: enabling switches to a camera that supports it and disabling switches back, `switchCamera(to:)` lands on the new position's Cinematic camera while it's on, and `enableCinematicVideo` opens that camera at configure. Enabling it is refused while the 48MP format is wanted. Apps driving `PRMCameraSession` directly call `reapplyCinematicVideoCaptureIfNeeded()` after a camera switch (`PRMCamera` does it for you).
- **Focus safety**: `PRMCamera.setFocusMode(_:)` and `PRMCameraSession.withVideoDevice(_:)`, which checks Cinematic Video and writes to the device in one step (AVFoundation raises on focus-mode changes while Cinematic Video is on). `setFocusAndExposure(focusMode:exposureMode:at:monitorSubjectAreaChange:)`, its rect variant and `prm_setFocusAndExposure` take a `nil` exposure mode to focus without touching exposure, so a tap keeps a manual exposure.
- **Session health**: `PRMDeferredStart` / `PRMCameraConfiguration.deferredStart` (iOS 26), `lensSmudgeDetectionInterval`, `setLensSmudgeDetection(interval:)`, `PRMLensSmudgeStatus` and `prm_lensSmudgeStatus` (iOS 26), `PRMLowLightVideoNoiseReduction` with `setLowLightVideoNoiseReduction(_:)` (iOS 27), `enableBluetoothHighQualityRecording` (iOS 26), `PRMSystemPressure`; state `lensSmudgeStatus`, `isLowLightVideoNoiseReductionActive`, `systemPressure`, `interruptionReason`; device `supportsLensSmudgeDetection`, `supportsLowLightVideoNoiseReduction`.
- **Dynamic aspect ratio and Smart Framing (iOS 26)**: `PRMAspectRatio`, `PRMVideoDimensions`, `PRMFraming`, `setDynamicAspectRatio(_:)`, `supportedFramings()`, `setSmartFraming(enabledFramings:)`, `framingRecommendationStream()` (the current recommendation first, then changes), `applyFraming(_:)`, `prm_dynamicAspectRatio`, `prm_dynamicDimensions`, `prm_setDynamicAspectRatio(_:timeout:)`; state `dynamicAspectRatio`, `dynamicDimensions`; device `supportedDynamicAspectRatios`, `supportsSmartFraming`.
- **AirPods Camera Control (iOS 26)**: `PRMCaptureSound`, `PRMCaptureEventHelper.primarySound` / `secondarySound` / `usesCustomCaptureSounds`.
- **Capture orientation**: `PRMPhotoSettings.rotationAngle(_:)` rotates the saved photo; pass `PRMRotationCoordinator.currentCaptureRotationAngle` so landscape shots save upright.
- **Session controls**: `PRMCameraSession.setZoom(_:)`, `rampZoom(to:rate:)`, `setFrameRate(_:allowFormatChange:)`, `resetFrameRate()`, `enableDepthFormat()`, `setHighResolutionPhotoFormat(_:)` and `setStabilization(_:)`, each checked and applied in one step; `attachDepthDataOutput(delegate:queue:filteringEnabled:)` / `detachDepthDataOutput()` for a live depth stream the session keeps across reconfigures; `wantsRunning` and `restartAfterMediaServicesReset()`.
- **Errors**: `PRMSessionError.captureFailed(_:)` carries AVFoundation's `AVError` (so its code, such as `-11872`, survives), plus `.exposureCombinationUnsupported` and `.unsupportedConfiguration(_:)`; `PRMBurstInterruptedError`.
- **Device helpers**: `prm_withConfigurationLock(_:)`, `prm_supportsCustomLensPosition`, `prm_supportsManualExposureCapture`, `prm_setLensPosition(_:completion:)`; the waiting variants of `prm_setLensPosition`, `prm_setCustomExposure` and `prm_lockWhiteBalance` take a `timeout`.
- **PrismUI accessibility**: VoiceOver labels and states on the settings drawer and rows (the drawer is modal while open and closes with the escape gesture), mode-aware shutter labels with press-and-hold offered as custom actions, a localized level reading, Dynamic Type in the drawer and rows, and opt-in `hapticsEnabled` on `PRMShutterButton` and `PRMLevelIndicatorView`. PrismUI's strings are localizable.
- **Night mode**: `PRMNightModeOptions`, `PRMNightPlan`, `PRMNightProgress`, `PRMNightPhoto`, `PRMNightModeCapture.plan(_:)` (the plan a capture would use, for an "AUTO 3s" label), and `PRMCameraSession.isExclusiveCaptureActive`.
- **Portrait readiness**: `PRMPortraitReadiness` and `PRMPortraitReadinessMonitor`, which tell whether a Portrait capture gets its depth effect right now (subject distance from a live depth stream, face and body detections, light) for a "NATURAL LIGHT" style indicator.
- **Frame orientation**: `PRMRotationCoordinator.portraitFrameRotation(connectionAngle:)` and `frameRotation(uprightAngle:connectionAngle:)` give the rotation a view still has to apply to video-data frames, with `PRMCameraSession.videoDataRotationAngle` and `isVideoDataMirrored`. A connection's default rotation isn't always 0: on the Center Stage front camera of iPhone 17 and later it is 270°, so drawing frames by the coordinator's angle alone leaves that preview sideways.
- **Other**: `PRMCameraConfiguration.enableCameraSensorOrientationCompensation` (iOS 26), `PRMRotationCoordinator.videoRotationAngle(relativeTo:)` (iOS 27), `PRMCameraSession.defaultVideoDeviceType(at:)`, `.lowLatency` stabilization (iOS 26), and `PRMCameraDevice.supportedExposureModes`, `supportedWhiteBalanceModes` and `supportedFocusModes` (with `AVCaptureDevice.prm_supportedExposureModes` and friends, and each mode's `prm_name`) so a UI offers only the modes a camera runs: iPhone cameras have no one-shot auto white balance. `PRMCameraDevice.supportsLowLightBoost` and `supportsVideoHDR` (active format) gate those controls the same way. `PRMCameraDevice.depthDeviceType(at:)` names the camera that streams depth, for when the current one has no depth format (`enableDepthFormat()` returns `false`): an iPhone 14 Pro's Triple camera has none on iOS 18.
- **Logging (`PRMLog`)**: six levels (`debug` to `fault`, `PRMLogLevel`) under the subsystem `dev.luminoid.prism`, categories `Session`, `Capture`, `Filter`, `Preview` and `General`. `PRMLog.minimumLevel` sets the threshold at runtime (default `.info`; errors and faults are always written); `PRMLog.handler` forwards every written `PRMLogEntry`. Message text is public; file paths and full error descriptions are private.
- **Always-on log lines**: a notice summary after configure, start, stop and every device switch; `isRunning` changes; interruptions with their reason; thermal state and system pressure changes; photo and recording outcomes, where a photo smaller than the size it asked for says why when that's known (manual exposure and locked white balance capture at 12 MP; 24 MP needs auto-deferred photo delivery); permission results. Every error sent to `errorStream()` is logged.
- **Example app**: iOS 26 / 27 drawer sections in Studio with telemetry badges and detection overlays, and the iOS 26 / 27 flags in Configuration Lab. Settings that can't run together follow one rule: the newest wins, turning the others off with a toast and a log line that say what changed and why; only what the camera can't do, or a recording would have to stop for, is refused.

### Changed

- **Breaking: building requires Xcode 27** (`swift-tools-version: 6.4`).
- **Breaking: `PRMLogger` and `PRMLogCategory` are removed**, replaced by `PRMLog`. `PRMLogger.isVerboseTracingEnabled = true` becomes `PRMLog.minimumLevel = .debug`. The subsystem changes from `com.luminoid.Prism` to `dev.luminoid.prism`, so update Console filters and `log` predicates.
- **Breaking: `PRMSessionError` has three new cases** (`captureFailed`, `exposureCombinationUnsupported`, `unsupportedConfiguration`), which break exhaustive `switch` statements. AVFoundation capture and recording errors now arrive as `captureFailed` instead of `photoCaptureFailed` / `videoRecordingFailed` strings.
- **Breaking: `PRMPhotoCapture.output` and `PRMVideoRecorder.output` are optional**: `nil` for a session-based wrapper before its first capture, instead of an empty placeholder output.
- **Breaking: device setters throw when the device lacks the mode** instead of returning silently: `prm_setExposureMode`, `prm_setCustomExposure`, `prm_setWhiteBalanceMode`, `prm_lockWhiteBalance`, `prm_setTorch`, `prm_setFocusMode`, `prm_setLensPosition`, and `prm_setVideoHDR` / `prm_setLowLightBoost` when turning the feature on. The matching `PRMCamera` setters report it on `errorStream()`.
- **Breaking: `captureBurst` throws `PRMBurstInterruptedError`** (with the photos already captured) when a shot after the first fails.
- Switching cameras, changing the frame rate or format, entering a depth format, removing the movie output and reconfiguring are refused while recording, with `PRMSessionError.unsupportedConfiguration`.
- `setHighResolutionPhotoFormat(true)` is refused while a movie output is attached (the 48MP format would replace the video format), and turning it off then only drops the choice (allowed while recording). `PRMCamera.setHighResolutionPhotoFormat(_:)` returns whether it applied.
- Photo settings are checked against the photo output at capture time: quality prioritization above the output's maximum is lowered to it, and `maxDimensions` the active format doesn't offer falls back to the largest one that fits.
- **Breaking: `PRMNightModeCapture` is rebuilt for brighter, cleaner Night photos.** `init(session:context:)` and `capture(_:progress:)` returning `PRMNightPhoto` replace `init(capture:context:)` and `capture(frameCount:perFrameDuration:iso:codec:didCaptureFrame:)`, and `session` replaces the `capture` and `context` properties. It picks the exposure from how dark the scene is, gathers frames from the live stream for 1 to 3 seconds (up to 10 when the phone is stable), aligns them, leaves out what moved, and brightens the result by up to 3 EV. It needs a physical camera: on a virtual multi-camera device it throws `virtualDeviceManualControlUnsupported`, so switch to `.builtInWideAngleCamera` first. During a capture, camera switches, format and frame-rate changes, zoom, focus, exposure and white-balance changes are refused.
- The live preview no longer gets the requested stabilization mode, which on video formats could delay it by up to a second (`.auto` picks cinematic stabilization there). The video data output runs unstabilized in photo modes and with iOS 26's low-latency stabilization while a movie output is attached; recordings keep the requested mode, and `PRMCameraState.activeStabilizationMode` reports the recording connection when there is one.
- The video data output's `sampleBufferDelegate` is Prism's frame router, which forwards every callback to the delegate passed to `setVideoDataOutputDelegate(_:)`.
- A `PRMPhotoSettings.manualExposureOverride` on a camera that can't take a manual exposure (virtual multi-camera devices) captures at the camera's own exposure and leaves the EXIF alone.
- `PRMAspectRatioMaskView.cropRect(in:)` orients the ratio to the bounds: 4:3 in a portrait view is a 3:4 crop.
- `PRMCameraSession.isRunning` reflects the capture session itself, and the session restarts on its own after a media-services reset if the app wanted it running.
- The 48MP photo format choice and Live Photo's on/off state carry across camera switches.
- `stateStream()` emits only when the state changed and delivers the newest state to slow subscribers.
- `lockWhiteBalance(preset:)` locks to Apple's calibrated values on iOS 26 and later (every preset except `.flash`); `PRMWhiteBalancePreset.temperature` keeps the nominal Kelvin.
- `PRMLens.focalLength35mm` reports nominal focal lengths on iOS 26 and later; `snapping()` leaves nominal values unchanged.
- `setFrameRate`, `resetFrameRate` and `enableDepthFormat` refresh `PRMCamera.device`, since the active format (and with it most capability flags) can change.
- `PRMPreviewView` stops redrawing while frames aren't arriving and flushes its texture cache on memory warnings.
- `PRMImage.jpegData(from:compressionQuality:context:)` encodes in sRGB, like the metadata-preserving encoders (an extended-range color space from a capture made it return `nil`), and returns `nil` for an infinite extent.
- Deprecated: `withConfigurationLock(_:)` (use `prm_withConfigurationLock(_:)`), `prm_setLensPositionAsync` (use `prm_setLensPosition(_:completion:)`), `PRMPhotoSettings.livePhoto` (ignored; use `captureLivePhoto`), `PRMPhotoSettings.makeAVSettings()` (use `makeAVSettings(for:)`), `PRMDepthCapture.addDepthDataOutput(to:delegate:queue:)` (use `PRMCameraSession.attachDepthDataOutput`).

### Fixed

- After AVFoundation stopped the session (a runtime error or media-services reset), `start()` did nothing and the preview stayed black.
- Switching cameras in video or slow-motion mode with Live Photo configured froze the preview for a full session rebuild and ended any recording.
- Manual-exposure stills crashed on iOS 27 when the camera was a virtual multi-camera device (Triple or Dual Camera).
- Captures could crash the app: a quality prioritization above the output's maximum, a manual exposure outside the active format's ISO or shutter range, and `maxDimensions` the output couldn't deliver.
- Starting a recording while the previous one was finalizing left the new one impossible to stop (`start()` now throws until the previous recording finishes), and `cancel()` left the recorder in `.recording`.
- A capture could hang when a deferred photo came back empty or a Live Photo's movie never arrived.
- `captureBurst` discarded every photo already captured when a later shot failed.
- `setLensPosition` never returned while the session was stopped or interrupted.
- Shutter speeds at the ends of the range could round outside it and crash; fractional frame rates such as 29.97 fps were truncated.
- Auto torch crashed on devices without it; manual exposure turned automatic video HDR back on after an explicit `setVideoHDR(_:)`; `enableDepthFormat()` left geometric distortion correction off for good.
- Lens zoom labels on dual (wide + telephoto) cameras read the wide lens as 0.5×.
- Video stabilization was lost after a camera switch, and the video output's pixel format was forced back to BGRA after a format change.
- A refused manual exposure, white-balance lock, or exposure or white-balance mode change kept showing the requested values, and a tap-to-focus left manual ISO and shutter pinned.
- `PRMPortraitBokehFilter`'s depth mode crashed, the blur filters darkened the frame edges, and filters that move the image rendered offset in the live chain.
- Replacing the active filter renderer could race the frame being rendered.
- `PRMPreviewView.texturePoint(fromViewPoint:)` and `viewPoint(fromTexturePoint:)` mirrored 90° and 270° rotations and ignored the fill crop and fit letterbox.
- `PRMLevelIndicatorView` hid the tilt with Reduce Motion on, and took over a shared motion manager's handler.
- A late subscriber to a stream with a current value could end up with a stale one.
- `PRMVideoRecorder.start()` could hang forever when recording failed (or was stopped) before it began.
- `PRMVideoRecorder.stop()` returned a `PRMRecording` with a `duration` of 0.
- `setHighResolutionPhotoFormat(true)` could pick the video-range (`420v`) twin of the 48MP format, which has fewer tonal steps than the full-range one.
- `resetFrameRate()` restored the photo preset without the 48MP format, so after a custom frame rate photos came back at 12MP while `setHighResolutionPhotoFormat(true)` was still in effect.
- Filtered frames from a camera format that carries color primaries but no color space were rendered in device RGB, which could shift colors; the color space is now built from the format's primaries and transfer function.
- HEIC photos from the filter pass and `PRMImage.heifDataPreservingMetadata` stored an alpha channel the photo didn't have, so files were larger and took twice the memory to decode.

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
