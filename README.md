# Prism

A camera pipeline Swift Package for iOS 18+ and Mac Catalyst 18+.

Built with Swift 6.2 strict concurrency, an actor-isolated AVCaptureSession wrapper, async-await capture APIs (still / Live Photo / Portrait / burst / long-exposure night-mode composite), full manual exposure / ISO / shutter / white-balance / focus surface, `AVCaptureDevice.RotationCoordinator` (iOS 17+), iOS 17/18 photo features (responsive capture, deferred photo delivery, zero shutter lag), a Metal-backed Core Image filter pipeline with corrected per-filter intensity blending, and a Metal preview view.

## Architecture

```
PrismCore  — Camera (actor + MainActor facade), device extensions, filter pipeline,
             capture helpers, utilities. No UI dependency.
PrismUI    — Metal preview view, shutter / focus / grid / level / aspect-mask UI.
             Depends on PrismCore + SnapKit.
```

## Layout

```
Sources/PrismCore/
├── Camera/      PRMCameraActor, PRMCamera, PRMCameraSession, PRMCameraConfiguration,
│                PRMCameraDevice, PRMCameraState, PRMRotationCoordinator,
│                PRMPermissions, PRMSessionError
├── Capture/     PRMPhotoCapture (still + Live Photo + Portrait + burst, async/await),
│                PRMPhotoSettings + PRMPhoto, PRMLivePhoto, PRMPortraitPhoto,
│                PRMNightModeCapture (frame-averaging composite),
│                PRMVideoRecorder + PRMRecording, PRMDepthCapture
├── Device/      AVCaptureDevice extensions for zoom / torch / exposure / WB / frame rate /
│                ISO + shutter / lens position / HDR + low-light,
│                AVCaptureConnection+Stabilization, PRMLens
├── Filter/      PRMFilter protocol (struct-based), PRMFilterPipeline,
│                PRMBasicFilterRenderer, PRMFilterChain, PRMBufferPoolAllocator,
│                PRMRenderContext, PRMVideoFrame, 18 built-in filter structs
│                (17 generic + PRMPortraitBokehFilter)
└── Utilities/   PRMLogger, PRMTempFile, PRMImage

Sources/PrismUI/
├── Preview/     PRMPreviewView + PassThrough.metal
└── Components/  PRMShutterButton, PRMFocusIndicatorView, PRMGridView,
                 PRMLevelIndicatorView, PRMAspectRatioMaskView, PRMCaptureEventHelper,
                 PRMSettingsDrawerView + PRMSettingsRow
```

## Features

### Core
- **Actor-isolated session** — `@PRMCameraActor` global actor wraps `AVCaptureSession` mutations; `PRMCamera` is a MainActor facade with `AsyncStream<PRMCameraState>` for UI binding
- **Async-await capture** — `try await camera.capturePhoto(settings:)` returns a `PRMPhoto`; `captureLivePhoto(settings:)` returns a `PRMLivePhoto` (still + paired movie URL); `capturePortraitPhoto(settings:)` returns a `PRMPortraitPhoto` (still + depth + portrait effects matte); `captureBurst(count:settings:)` returns `[PRMPhoto]`; video recording with `try await recorder.start()` / `stop()` returning `PRMRecording`
- **Night mode** — `PRMNightModeCapture(capture:context:).capture(frameCount:perFrameDuration:iso:)` averages N captures into a long-exposure composite
- **Full manual control** — `prm_setZoom`, `prm_setTorch`, `prm_setExposureBias`, `prm_setExposureMode`, `prm_setCustomExposure`, `prm_setISO`, `prm_setShutterSpeed`, `prm_setLensPosition` (manual focus), `prm_setFocusMode`, `prm_lockWhiteBalance` (temperature + tint or preset), `prm_setFrameRate`, `prm_setVideoHDR`, `prm_setLowLightBoost`, `prm_setStabilization`. All surface on `PRMCamera` as `await camera.setX(...)`
- **Rotation coordinator** — wraps iOS 17+ `AVCaptureDevice.RotationCoordinator` and exposes preview / capture angles as `AsyncStream<CGFloat>`
- **Permissions** — async `PRMPermissions.requestCameraAccess()` / `requestMicrophoneAccess()`
- **iOS 17/18 photo features** — `enableResponsiveCapture`, `enableAutoDeferredPhotoDelivery`, `enableZeroShutterLag`, `enableLivePhoto`, `enableDepthDataDelivery`, `enablePortraitEffectsMatteDelivery`, `preferredVideoStabilizationMode` on `PRMCameraConfiguration`
- **Multitasking camera access** — iPad-only opt-in via `enableMultitaskingCameraAccess`
- **Lens descriptors** — `PRMLens` exposes raw 35mm-equivalent focal length per physical camera, with opt-in `snapping(to:tolerance:)` for marketing-friendly values
- **Filter pipeline** — `PRMFilterPipeline` routes `AVCaptureVideoDataOutput` frames through any `PRMFilterRenderer`; delivery via callback or `AsyncStream<PRMVideoFrame>`
- **Filter chain** — `PRMFilterChain` stacks multiple filters with **correct** per-filter intensity blending (uses `CIBlendWithMask` against the previous step's output, fixing a subtle bug in the prior implementation)
- **Shared render context** — `PRMRenderContext` provides one Metal-backed `CIContext` per pipeline (Apple's WWDC '20 guidance); zero per-renderer context churn
- **Built-in filters** — 18 structs across color, blur, stylize, distortion, and portrait bokeh (Brightness, Contrast, Saturation, Hue, Grayscale, Sepia, Vignette, GaussianBlur, MotionBlur, ZoomBlur, Pixellate, Comic, Pointillize, Edges, Bump, Twirl, Pinch, Vortex, PortraitBokeh)

### UI
- **Metal preview** — `PRMPreviewView` with simple latest-frame-buffered drawing on `MTKView`'s display link; no per-frame MainActor hop
- **Settings drawer** — `PRMSettingsDrawerView` slides in from the trailing edge with a sectioned, scrollable list of collapsible `PRMSettingsRow` controls (SF Symbol header, value label, arbitrary content view: slider, segmented control, chip strip, switch)
- **Shutter button** — `PRMShutterButton` morphs between photo / video / recording-active modes with tap + long-press handlers
- **Focus indicator** — animated tap-to-focus square with Reduce Motion support
- **Composition grid** — rule of thirds, golden ratio, crosshair, **Fibonacci spiral**
- **Aspect ratio mask** — 4:3, 16:9, 1:1, full frame
- **Level indicator** — CoreMotion gravity-based horizon with hysteresis and snap-to-zero
- **Capture controls** — `PRMCaptureEventHelper` wraps iOS 17.2+ `AVCaptureEventInteraction` for the Camera Control button and volume buttons

## Example app

`Example/PrismExample.xcodeproj` ships three demo screens:

1. **Permissions** — camera + microphone status pills and request flow.
2. **Studio** — a DSLR-grade camera that combines preview, lens picker (35mm-equivalent), tap-to-focus, pinch-to-zoom, vertical drag for exposure bias, top-bar quick toggles (torch / grid / aspect / timer / burst / settings), telemetry strip (mode, zoom, ISO, shutter, EV, white balance, frame rate), mode strip with **PHOTO / LIVE / PORTRAIT / PANO / VIDEO / SLO-MO / NIGHT**, and a slide-in settings drawer exposing every supported AVFoundation API (EV / ISO / shutter sliders, WB Kelvin slider + preset chips, manual focus lens-position slider, HDR auto/on/off, low-light boost, stabilization mode, codec).
3. **Filter Chain** — a real-time multi-filter editor with reorderable active pills, per-filter intensity sheet, and a library tabbed by category.

Regenerate the Xcode project with XcodeGen:

```bash
cd Example && xcodegen generate
```

## Build & test

```bash
xcodebuild build -scheme Prism-Package -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2' CODE_SIGNING_ALLOWED=NO
xcodebuild test  -scheme Prism-Package -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2' CODE_SIGNING_ALLOWED=NO

make check   # SwiftLint + SwiftFormat
```

## Stats

| Metric | Count |
|--------|-------|
| Source files (PrismCore) | 44 |
| Source files (PrismUI) | 9 |
| Test files | 44 |
| Tests | 138 |
| Example screens | 3 |

## Getting started

```swift
import PrismCore
import PrismUI

@MainActor
final class CameraVC: UIViewController {
    private let camera = PRMCamera()
    private let pipeline = PRMFilterPipeline()
    private lazy var renderContext = PRMRenderContext()!
    private lazy var preview = PRMPreviewView(context: renderContext)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(preview)

        Task {
            try await camera.configure(PRMCameraConfiguration())
            pipeline.isEnabled = true
            await camera.session.setVideoDataOutputDelegate(pipeline)
            pipeline.onFrame = { [weak self] frame in
                self?.preview.update(frame.pixelBuffer)
            }
            await camera.start()
        }
    }
}
```

See [Example/Sources/StudioViewController.swift](Example/Sources/StudioViewController.swift) for the full integration.

## Privacy manifest (consumers)

Prism does not ship a `PrivacyInfo.xcprivacy` — Apple's privacy report is aggregated at the app bundle level, so the manifest belongs in the app embedding Prism, not in the package. When you integrate PrismCore, add the following required-reason API declarations to your app's `PrivacyInfo.xcprivacy`:

| API category | Reason code | Why Prism needs it |
|---|---|---|
| `NSPrivacyAccessedAPICategoryFileTimestamp` | `C617.1` (read timestamps of files you control) | `PRMTempFile` reads attributes of video files it just wrote (to compute duration and for cleanup). |
| `NSPrivacyAccessedAPICategoryDiskSpace` *(only if your app calls it)* | `85F4.1` | Apps that gate recording on available space should declare this; Prism itself does not read disk space. |

Prism does **not** access UserDefaults, system boot time, or active keyboards, so those categories don't apply.

App-side Info.plist keys you also need: `NSCameraUsageDescription` (always), `NSMicrophoneUsageDescription` (if `includesAudio: true`), `NSPhotoLibraryAddUsageDescription` (if you save captures via `PHPhotoLibrary`). Prism does not interact with PHPhotoLibrary itself — it returns `Data`/`URL`, and the consuming app saves.

## License

MIT — see [LICENSE](LICENSE).
