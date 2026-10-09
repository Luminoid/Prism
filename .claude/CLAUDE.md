# Prism — Claude Code Guide

> Shared camera pipeline Swift Package with targets PrismCore and PrismUI.
> AVFoundation, CoreMedia, Metal, CoreImage. Swift 6 language mode, tools 6.4 (Xcode 27, iOS 27 SDK), deploys to iOS 18+.

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
- Frame delivery: the session's `PRMVideoFrameRouter` is the video data output's delegate. It forwards to the app's delegate (`setVideoDataOutputDelegate`, typically `PRMFilterPipeline`) and then to Prism's own observers (Night capture). Frames come in on `PRMCameraSession.dataOutputQueue` (a dedicated serial queue). The pipeline exposes both callback (`onFrame`) and `AsyncStream<PRMVideoFrame>` delivery.
- Preview view (`PRMPreviewView`) uses a lock-protected `latestPixelBuffer`. `MTKView` polls it via its built-in display link — no per-frame Task hop.

## Architecture conventions

- **`PRM` prefix** for all public types, **`prm_`** for AVFoundation extension methods.
- **No LumiKit dependency** — fully standalone package.
- **Value-type filters** — `PRMFilter` is a `Sendable` protocol with no `AnyObject` requirement; all 20 built-in filters are structs (18 generic + `PRMPortraitBokehFilter` + `PRMPassThroughFilter`).
- **Composition over inheritance** — `PRMBasicFilterRenderer(context:description:filterFactory:)`, no per-filter subclasses.
- **No `PHPhotoLibrary`** in the library — capture helpers deliver data/URLs and consuming apps save.
- **One CIContext per pipeline** — `PRMRenderContext` wraps a shared Metal-backed `CIContext` with `.cacheIntermediates: false` (per WWDC '20).
- **Modern rotation** — `PRMRotationCoordinator` wraps `AVCaptureDevice.RotationCoordinator` (iOS 17+); the old `UIDeviceOrientation`-based mapping in `AVCapture+PRM` is gone.
- **iOS 17/18 photo features** — `enableResponsiveCapture`, `enableAutoDeferredPhotoDelivery`, `enableZeroShutterLag` on `PRMCameraConfiguration`.
- **iOS 26/27 features are availability-gated, never required** — see the section below.

## iOS 26 / 27 adoption (0.2.0)

Built against the iOS 27 SDK (Xcode 27).

- **Stored properties can't hold iOS 26/27 types** on an iOS 18 target, so state and snapshots use Prism value types with gated bridging inits (`PRMExposureSignal`, `PRMAspectRatio`, `PRMLensSmudgeStatus`, `PRMSystemPressure`, `PRMSceneMonitoringStatus`, `PRMDetectedObject`, …). Never store `AVCaptureSmartFramingMonitor` / `AVCaptureDevice.AspectRatio`; read them from `videoDevice` each time.
- **Swift spellings differ from the ObjC names**: `AVCaptureDeviceExposureSignal` is top-level (not `AVCaptureDevice.ExposureSignal`), `setPrimaryConstituentDeviceSwitchingBehaviorLockedWith(_:)`, `defaultRectForFocusPoint(ofInterest:)`, `AVCaptureCameraLensSmudgeDetectionStatus`, `AVCaptureEvent.play(_:)`, `AVCaptureEventSound(url:)`. Typecheck a one-liner against the SDK (`printf … | xcrun --sdk iphoneos swiftc -typecheck -target arm64-apple-ios27.0 -`) before guessing.
- **Feature intents live on `PRMCameraSession`** (`wantsContinuousAutoFocusTracking`, `wantsCinematicVideo`, smudge interval, NR policy, desired aspect ratio, Smart Framing set, consumer metadata types). `tearDownAttachments()` keeps them; `configure(_:)` resets them via `resetFeatureIntents(from:)`. `applyFeatureIntents()` re-applies everything device/format-dependent and is called inside every begin/commit that replaces the input, outputs or active format (configure, `swapInput`, `reconfigureForDevice`, the `+Format` swaps, `setFrameRate`, `enableDepthFormat`). New format-changing paths must call it too.
- **Cinematic Video is an input property, re-applied by the facade, not by `swapInput`**: `PRMCamera.switchCamera` / `switchDevice` call `reapplyCinematicVideoCaptureIfNeeded()` after the swap's readiness wait, so the baseline-format snapshot never captures a cinematic format and the two rebuilds run one at a time. Enabling may take two commits (the input can report support only after the format commit), separated by `awaitPhotoOutputReady`; failures roll back to an exact snapshot (format, preset, depth/matte flags, tracking intent). An enable overtaken during that wait (`cinematicGeneration` moved: a toggle or camera switch ran) stops with `.cancelled` and leaves the state to the newer operation. Never call it inside an outer begin/commit: nested pairs apply only at the outermost commit.
- **Focus writes check Cinematic Video in the same actor turn** (`PRMCameraSession.withVideoDevice(_:)`, used through `PRMCamera.runOnDeviceCheckingCinematic`). While Cinematic Video is on, AVFoundation raises (uncatchably) on any focus-mode change, and a check in a separate hop leaves a window for a concurrent toggle.
- **`PRMCameraActor.run { }` does not run its body on the actor**: the closure is `@Sendable` and nonisolated, so each `await session.x` inside it is its own hop and the actor can interleave between them. Anything that must be atomic with respect to session state belongs in a synchronous `@PRMCameraActor` method on `PRMCameraSession`.
- **One shared metadata output**, attached on first need and never detached; `reconcileMetadataOutput()` computes its types with the pure `effectiveMetadataObjectTypes` (Cinematic's required set wins; otherwise `.focusTrackedObject` + consumer types; always filtered by `availableMetadataObjectTypes`, since the setter raises on anything else). AF tracking reports nothing without `.focusTrackedObject` subscribed.
- **Device-level KVO is owned by the session** (`PRMCameraSession+DeviceObservers.swift`), re-bound from `videoDevice`'s `didSet`; handlers are `@Sendable` and only touch Sendable registries (`deviceEvents`, `framingRecommendations`). `PRMCamera.deviceEventTask` turns ticks into `refreshState()`.
- **Deferred start is already on for photo + movie outputs** in apps linked on iOS 26+ (SDK default). `PRMCameraConfiguration.deferredStart` defaults to `.systemDefault`; switch the default to `.disabled` if the hardware pass shows `awaitPhotoOutputReady` timing out before deferred start runs.
- **Priority modes keep the virtual-device guard** (`prm_setExposure` throws `virtualDeviceManualControlUnsupported` when any axis is locked) until hardware shows whether they hold on a virtual device, with or without the iOS 27 lens lock.

## Session invariants (2026-10-04 audit fix pass)

- **Check-and-mutate in one actor turn.** Zoom, frame rate, depth format and the 48MP format live as synchronous methods on the session (`PRMCameraSession+Controls.swift`, `setHighResolutionPhotoFormat` in `+Format`); the facade only calls them. The frame-rate path rebuilds an attached movie output inside its own begin/commit (`applyMovieFileOutputAttached(false, targetLivePhoto: false)` then `(true)`), so a recorder can't land in between. `PRMCamera.refreshState()` reads `stateSnapshot()` (`+State.swift`) in one turn and skips the yield when nothing changed.
- **Refuse while busy** with `refuseWhileBusy(_:)` (recording, or a Night capture holding the camera): configure, camera switches, frame rate / reset, 48MP, depth format, movie-output detach, Cinematic toggle and aperture, dynamic aspect ratio. During a Night capture zoom refuses too (`refuseDuringExclusiveCapture`), and `PRMCamera`'s device-write helpers (`runOnDevice*`) refuse or skip, so focus, exposure and white balance can't move mid-stack.
- **Night capture** (`PRMCameraSession+NightCapture.swift`): `beginNightCapture` checks, plans and snapshots in one actor turn and sets `exclusiveCaptureOwner`; `applyNightExposure` sets the custom exposure, locks white balance and focus, and takes stabilization and low-light noise reduction off the data connection; `endNightCapture` restores all of it (frame durations last, only on the same format) on every path. Frames come through `frameRouter` observers; one is accepted only when its `{Exif}` exposure matches the plan (device and sync clocks differ, so timestamps can't be compared with the exposure's confirmation time). Vision's `warpTransform` maps the floating image onto the reference, bottom-left origin, in the pixels it was given; `PRMNightRegistration.referenceToFrameWarp` converts it for the shader, and a test on synthetic images pins that. Low-contrast frames can fool Vision, so a warp that matches worse than no warp loses to the identity.
- **Frame rotation is relative to the connection**: `RotationCoordinator` angles (and iOS 27's static `videoRotationAngle(relativeTo:)`) are absolute, measured from the native sensor orientation, but a connection's default `videoRotationAngle` isn't always 0. The Center Stage front camera (iPhone 17 and later, sensor mounted in portrait) reports 0° upright in portrait while its video-data connection defaults to 270° (so frames match older front cameras); recent iPads' front cameras default to 180°. Anything that rotates video-data frames itself (a preview, Night's output) rotates by upright minus the connection's angle (`frameRotation(uprightAngle:connectionAngle:)`); setting an absolute angle on a connection (photo, movie) uses the coordinator's value as is.
- **Cinematic Video runs on specific cameras**, per iPhone: Apple documents the back Dual Wide and front TrueDepth cameras; the iPhone 18 Pro Max runs it on the back wide camera and its front Center Stage camera (2026-10-08 log). Never the Triple camera. `PRMCamera.setCinematicVideoEnabled` switches to `PRMCameraDevice.cinematicVideoDeviceType(at:)` when the current camera has no Cinematic format and records `cinematicReturn` to switch back on disable; any app-initiated `switchCamera` / `switchDevice` clears it, and `switchCamera` lands on the new position's Cinematic camera while `wantsCinematicVideo`.
- **Preview stabilization**: the requested mode goes to the movie connection only. The data connection (the preview) runs unstabilized in photo modes and with iOS 26 `.lowLatency` while a movie output is attached (`previewStabilizationMode`): the cinematic modes `.auto` can pick add up to a second of preview lag.
- **`isRunning` is `session.isRunning`** (never a cached flag); `wantsRunning` records the app's intent, and `PRMCamera`'s runtime-error observer calls `restartAfterMediaServicesReset()` on `.mediaServicesWereReset`.
- **Intents that survive switches**: `stabilizationMode`, `wantsHighResolutionPhotoFormat` (both reset from the configuration; the 48MP format also comes back in `resetFrameRate()` after the preset restore, and turning it off with a movie output attached only drops the intent, never the video format), Live Photo's runtime on/off (read before `swapInput` removes the input), and the depth-stream request (`attachDepthDataOutput`, re-added by `reconfigureForDevice`). Cinematic Video refuses to enable while the 48MP format is wanted, and the 48MP format refuses to enable beside a movie output.
- **`swapInput`** restores the configured preset on the incoming device, skips the Live-Photo full-reconfigure fallback while a movie output is attached (Live Photo is never supported alongside one), falls back to `applyConfiguration(_:resettingIntents: false)` if that reconfigure throws, and takes each device's baseline format on its first visit only (`baselineFormats[uniqueID]`), so a 48MP or Cinematic format never becomes the baseline.
- **Settings Prism changes on its own** (auto video HDR for full manual, geometric distortion correction for depth) are recorded per device (`prm_noteDisabledByPrism`) and restored only if Prism turned them off, so an app's explicit `prm_setVideoHDR` survives.
- **Device setters throw `.unsupportedConfiguration` when the device lacks the mode** (turning something off on a device without it stays a no-op). Facade setters report through `runDeviceSetter(_:_:)` (PRMSessionError to `errorStream()`, lock failures logged, both once per error until the next success).
- **Capture pre-flight**: resolve the live output (`PRMOutputResolver`, shared by `PRMPhotoCapture` and `PRMVideoRecorder`), wait for readiness (`AVCapturePhotoOutput.prm_readiness`: active connection, `.ready`, non-zero `maxPhotoDimensions`, healing a `(0, 0)` ceiling on the way; the session's `awaitPhotoOutputReady` uses the same check), and only then build settings against that output: quality clamped to `maxPhotoQualityPrioritization`, `maxDimensions` validated, manual brackets clamped to the active format (or `.speed` regular settings when the output allows no bracket), Portrait requests from the live output. `photoOutput(_:didFinishCaptureFor:error:)` fails anything still pending; encoding runs outside the capture lock.
- **Recorder**: every state transition under its lock; `start()` refuses while `.finalizing`; finish callbacks for another file are ignored; `cancel()` discards on finish.

## Source Structure

```
Sources/PrismCore/
├── Camera/      PRMCameraActor, PRMCamera, PRMCamera+Observers, PRMCamera+ManualControls,
│                PRMCamera+SessionHealth, PRMCamera+Tracking, PRMCamera+Framing,
│                PRMCameraSession, PRMCameraSession+Format, PRMCameraSession+Controls,
│                PRMCameraSession+State, PRMCameraSession+DeviceObservers,
│                PRMCameraSession+Features, PRMCameraSession+Metadata, PRMCameraSession+Cinematic,
│                PRMCameraConfiguration, PRMCameraDevice, PRMCameraState, PRMRotationCoordinator,
│                PRMPermissions, PRMSessionError, PRMSessionHealth, PRMFraming,
│                PRMCinematicVideo, PRMDetectedObject, PRMMetadataRouter,
│                PRMVideoFrameRouter, PRMCameraSession+NightCapture
├── Capture/     PRMPhotoCapture (+Delegate, +Encoding; still / Live Photo / Portrait / burst),
│                PRMPhotoSettings, PRMPhoto, PRMLivePhoto, PRMPortraitPhoto,
│                PRMPortraitReadiness, PRMNightModeCapture, PRMVideoRecorder, PRMRecording,
│                PRMDepthCapture, PRMOutputResolver,
│                Night/ (PRMNightTypes, PRMNightPlanner, PRMNightStacker, PRMNightRegistration,
│                PRMNightMerger + PRMNightMerge.metal, PRMNightTone)
├── Device/      AVCaptureDevice+Zoom/Torch/Exposure/Aperture/WhiteBalance/FrameRate/ISO/
│                Lens/FocusTracking/Cinematic/HDR/Depth/AspectRatio/SmudgeDetection/
│                Configuration, AVCapturePhotoOutput+Readiness,
│                AVCaptureConnection+Stabilization, PRMLens, PRMExposureValue
├── Filter/      PRMFilter, PRMFilterRenderer, PRMBasicFilterRenderer,
│                PRMFilterChain, PRMFilterPipeline, PRMBufferPoolAllocator,
│                PRMRenderContext, PRMVideoFrame,
│                Filters/{Color,Blur,Stylize,Distortion,PortraitBokeh}
└── Utilities/   PRMLog (shared core), PRMLog+Categories, PRMStreamRegistry, PRMTempFile,
                 PRMImage

Sources/PrismUI/
├── Preview/     PRMPreviewView, Shaders/PassThrough.metal
├── Components/  PRMShutterButton, PRMFocusIndicatorView, PRMGridView,
│                PRMLevelIndicatorView, PRMAspectRatioMaskView, PRMCaptureEventHelper,
│                PRMSettingsDrawerView, PRMSettingsRow
└── Resources/   en.lproj/Localizable.strings (`String(localized:bundle: .module)`; plain
                 `.strings`, since command-line SwiftPM copies `.xcstrings` uncompiled)
```

**File-organization notes:**
- `PRMCamera+Observers.swift` owns the four KVO + NotificationCenter wirings (session.isRunning, device-commit, runtime error, interruption). Split off the main facade to keep `PRMCamera.swift` focused on device-mutation public methods.
- `PRMCameraSession+Format.swift` owns the high-res / Live-Photo-compatible / depth-capable format-selection logic (the 48MP promotion path + Live-Photo restore + auxiliary-flag reconciliation). Pulled out so the session file stays focused on lifecycle.
- `PRMStreamRegistry<T>` consolidates the UUID-keyed continuation dictionary + `onTermination` cleanup pattern used by ``PRMCamera`` (state / error / interruption), ``PRMRotationCoordinator`` (preview / capture angles), ``PRMFilterPipeline`` (frames), ``PRMMetadataRouter`` (detected objects), and the session's internal `deviceEvents` / `framingRecommendations`. An `initial` value is yielded under the registration lock, so a concurrent `yield` always lands after it.
- `PRMSessionHealth.swift`, `PRMFraming.swift` (also `PRMAspectRatio`, `PRMVideoDimensions`) and `PRMCinematicVideo.swift` are named after their topic and hold several small value types.
- `PRMPhotoCapture` is split by concern: entry points, pre-flight and settings in the main file, the delegate and outcome state machine in `+Delegate`, the EXIF patch and filter encode in `+Encoding`.
- The iOS 26/27 facade APIs live in `PRMCamera+ManualControls` / `+SessionHealth` / `+Tracking` / `+Framing` and their session halves in `PRMCameraSession+Features` / `+Metadata` / `+Cinematic`, so `PRMCamera.swift` and `PRMCameraSession.swift` stay on lifecycle and the long-standing controls. Extensions reach the facade's intents and `runOnDevice*` helpers, which are `internal` (not `private`) for that reason.

## Build & Test

PrismUI (UIKit + Metal) requires `xcodebuild`:

```bash
xcodebuild build -scheme Prism-Package -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2' CODE_SIGNING_ALLOWED=NO
xcodebuild test  -scheme Prism-Package -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2' CODE_SIGNING_ALLOWED=NO
xcodebuild test  -scheme Prism-Package -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' CODE_SIGNING_ALLOWED=NO   # runs the iOS 27-gated test bodies
```

```bash
make check   # SwiftLint (Sources, Tests, Example/Sources) + SwiftFormat
make build / make test / make test-27 / make build-example   # xcodebuild wrappers
```

> The scheme is `Prism-Package` (auto-generated from Package.swift), not `Prism`. Don't simplify or restructure Package.swift: past simplification attempts made the scheme disappear.

## Test Structure

- **362 tests / 69 suites at v0.2.0 (release figure)** — Swift Testing (`@Test`, `#expect`, `@Suite`)
- Tests mirror the source folders; `+Extension` files are covered by their type's suite or a grouped `…FeaturesTests` / `…ControlsTests` suite. Shared helpers live in `Tests/*/TestSupport/`.
- The intensity-blend correctness fix is verified with golden pixel-comparison tests in `PRMFilterChainTests`
- Device-touching paths (`AVCaptureDevice` extensions, `PRMPhotoCapture`/`PRMVideoRecorder`/`PRMDepthCapture` start/stop) can't run on simulator — `AVCaptureDevice.default(for:)` returns `nil`. Those modules are covered via **value-type tests** (enums, structs, presets), **API surface locks** (`KeyPath` lookups that fail to compile on signature drift), and **Sendable conformance checks** (`Task.detached` round-trips). Full hardware paths are exercised via the Example app. iOS 26/27 tests use `@Test(.enabled(if: OSAvailability.isIOS27))` (so they report as skipped, not passed, on an older simulator) plus `guard #available(...)` in the body for the compiler (Swift Testing forbids `@available` on `@Test` functions).

## Logging

- `PRMLog.swift` is the shared logging core (rendered from Monolith's `LogCoreGenerator`). Prism's categories (`session`, `capture`, `filter`, `preview`, `general`) and helpers (`PRMLog.bestEffort` for tolerated device calls instead of `try?`, `fourCC`, the `prm_logName` names for AVFoundation values) live in `PRMLog+Categories.swift`.
- Subsystem `dev.luminoid.prism`; write functions are `package`, so the Example uses its own `Logger` under `dev.luminoid.prism.example` and only sets `PRMLog.minimumLevel`.
- Message text is public (static text, codes, counts, dimensions, device types, presets); file paths go in `private:`, errors in `error:` (never `localizedDescription`). Per-frame or slider-rate failures use `PRMLog.once` + `resetOnce`; slider-rate calls themselves log through `PRMBurstLog` (the first call of a drag, then the value it settled on), and the frame-latency rollup logs only slow windows. Session lifecycle summaries (`configurationSummary()`) are notice; everything sent to `errorStream()` is logged by `emitError`.
- Tests must not set `PRMLog.handler` / `minimumLevel` outside `PRMLogTests`: both are process-wide and Swift Testing runs suites in parallel.

## Critical lessons / non-obvious details

- **`@preconcurrency import AVFoundation`** is required in files that pass non-`Sendable` AVFoundation types across actor boundaries: the `PRMCamera*` / `PRMCameraSession*` files, the capture helpers, and the Example view controllers.
- **AVCaptureSession is not Sendable**, but its internal queue serializes access. Use `nonisolated(unsafe) let session = AVCaptureSession()` on `@PRMCameraActor` classes.
- **The filter chain intensity bug** in the prior implementation: it called `composited(over:)` then `applyingFilter("CISourceOverCompositing", parameters: [:])` (no-op without `inputBackgroundImage`), then re-composited onto the **original source image** instead of the previous step's output. The fix uses `CIBlendWithMask` with a constant-color mask against the previous step's output for a correct `mix(prev, filtered, intensity)`.
- **`isEmpty` SwiftFormat rule**: the `--enable isEmpty` rule auto-rewrites `count == 0` to `.isEmpty`. Any custom collection-like type used in tests needs an `isEmpty` property to satisfy this. `PRMFilterChain` exposes both `count` and `isEmpty`.
- **iOS only** — Mac Catalyst was dropped at v0.1.0: Catalyst is API_UNAVAILABLE on `AVCaptureDeferredPhotoProxy`, Live Photo, and `AVCapturePhotoOutput.captureReadiness`, which are core Prism features. Most other AVCaptureDevice APIs (`minISO`, `maxExposureTargetBias`, `WhiteBalanceGains`, `videoZoomFactor`, depth APIs) are also `API_UNAVAILABLE(macos)`. The remaining `#if !os(macOS)` guards are kept as documentation of which calls would crash if anyone re-introduced a Mac target; they're inert dead branches under the iOS-only build (which is also why `swift build` on the macOS host fails: build and test through `xcodebuild` or the Makefile).
- **Metal toolchain**: Apple sometimes requires a separate download (`xcodebuild -downloadComponent MetalToolchain`) the first time you build PrismUI's shader.
- **PrismUI `defaultIsolation(MainActor)`**: this Package.swift setting makes every nested type in PrismUI MainActor-isolated. UI test suites must be `@MainActor` to use `Equatable` etc. on these types.

## Example App

- **Five screens** in `Example/PrismExample.xcodeproj`, listed by `RootCatalogViewController`: `PermissionsViewController`, `StudioViewController` (DSLR), `FilterChainViewController`, `DepthInspectorViewController`, `ConfigurationLabViewController`.
- The example exercises nearly every public API surface of PrismCore + PrismUI. The iOS 26/27 drawer sections, telemetry badges, detection outlines and tracked-subject overlay live in `ModernCaptureControls.swift`; Studio rebuilds the drawer when the camera flips (a button, so no slider is under a finger) but not on a device hop, so the rows re-check availability when the device changes, and `sync(from:)` mirrors device state into the rows while skipping controls whose change is still landing (`pendingControls`). Studio itself covers the WB presets, the AirPods capture sounds per mode and the interruption reason.
- **Shared Example plumbing**: `CameraPreviewHost` owns each camera screen's boot task, appear/disappear start and stop, stream loops, rotation coordinator (stills and recordings take its capture angle) and preview orientation: the data connection keeps AVFoundation's default rotation (so texture space is device space for tap-to-focus and detection outlines), and the preview view rotates by `PRMRotationCoordinator.portraitFrameRotation(connectionAngle:)`, the upright angle minus what the connection already applied, and mirrors the front camera; `LatestWinsRunner` coalesces slider-rate calls (`run(_:deduplicating:_:)` drops a snapped slider's repeats, `forget(_:)` on touch-down); `ToastPresenter`, `PaddedLabel`, `SectionHeaderLabel` and `ExampleFont` (Dynamic Type) keep the screens consistent; `CaptureLabels` holds shutter / focal-length formatting, `StabilizationOption` and the `CameraCapability` requirement strings; `PhotoLibrarySaver` and `ExampleLog` are shared. Studio is split into `StudioViewController` plus `+Capture`, `+DeviceHops`, `StudioDrawerControls` and `StudioComponents`. The Example is iPhone-only and linted with the package (`.swiftlint.yml` includes `Example/Sources`).
- **Settings that can't run together** follow one rule in every screen: the newest wins. The setting just turned on turns the others off (or a requirement on), the controls follow, and `ToastPresenter.gaveWay(_:)` shows one `SettingChange` toast and logs one `Conflict:` line. Only what the camera can't do (a disabled row or segment that explains itself) or what a recording would have to stop for is refused (`refused(_:because:)`, a `Refused:` line). Studio's table is in `StudioViewController+Conflicts.swift`: every control that turns something on calls `prepare(for:)` first (it also makes the wide-camera hop), and mode changes call `resolveConflicts(entering:)` inside their session work, which must never wait on another session task. Rows that depend on the session (recording, Subject Tracking) register with `ModernCaptureControls.gateOnState`. Studio's captures start only after the queued session work (`runCapture` awaits `awaitSessionWork()`): a recording started mid-setup failed with AVError -11805 once the setup swapped cameras. Studio goes back from the wide camera only when nothing needs it there (`restorePreManualCamera`: manual exposure or white balance, a locked focus, Max Dimensions, Cinematic Video running there), and logs each hop's reason; leaving VIDEO, the mode setup detaches the movie output before that return, so the virtual camera isn't swapped in with a movie pipeline. A device switch starts the new camera on the configured preset at its default frame rate, so a switch a control makes in VIDEO sets VIDEO's frame rate again (`reapplyVideoFrameRate`); mode changes and flips re-run the mode setup instead. Drawer rows the camera doesn't log (Codec, HDR, Low-Light Boost, Stabilization, Auto Red-Eye) log `Studio <row> → <value>` themselves, so a pasted log explains a JPEG. PORTRAIT runs on a camera with a depth format: when `enableDepthFormat()` finds none (an iPhone 14 Pro's Triple camera on iOS 18), Studio switches to `PRMCameraDevice.depthDeviceType(at:)` and back when PORTRAIT ends (`prePortraitDeviceType`, restored first in the next mode's setup), and a white balance or focus change that would move a virtual camera to the wide one turns PORTRAIT off. The WB and Focus rows stay enabled on a virtual camera that can't take their values, since the change moves to the wide camera first; the Exposure, WB and Focus Mode segments grey out modes the camera lacks (`supported*Modes`), and a picker change a conflict makes logs `(for <setting>)`.
- **Configuration Lab** exposes every `PRMCameraConfiguration` flag; when adding one, add its control there (with any mutual-exclusion rule in `enforceMutualExclusion`, with the reason its toast gives) and a line in the post-Apply summary, which lists the device's iOS 26/27 support and what landed.
- Edit `Example/project.yml` (XcodeGen) — never edit `project.pbxproj` directly.
- **Never commit `DEVELOPMENT_TEAM`** — set to `""` or omit.

## Key build settings (Package.swift)

- `swift-tools-version: 6.4` (Swift 6 language mode, so complete concurrency checking is on without a flag); building needs Xcode 27
- `defaultLocalization: "en"` (PrismUI's `Resources/en.lproj`)
- `platforms: [.iOS(.v18)]`
- PrismUI: `defaultIsolation(MainActor)`

---

*Last updated 2026-10-09 — 0.2.0: iOS 26/27 capture APIs, PRMLog, the rebuilt Night mode and Portrait readiness, the capture and session fixes, Xcode 27 / tools 6.4. 362 tests / 69 suites at v0.2.0 (release figure).*
