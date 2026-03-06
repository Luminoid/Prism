# Prism

A comprehensive camera pipeline Swift Package for iOS, iPadOS, and Mac Catalyst.

Built with Swift 6.2, strict concurrency, and a Metal-based preview renderer.

## Architecture

```
PrismCore  — Session management, device controls, filter pipeline, capture helpers
PrismUI   — Metal preview, camera button, focus view, grid overlay, level indicator,
             aspect ratio overlay, capture control helper (SnapKit dependency)
```

## Features

### Core
- **Session management** — `PRMCameraSessionManager` with device discovery, focus/exposure, observers
- **Device controls** — Zoom, torch, exposure, white balance, stabilization, frame rate (6 stateless helpers) with 35mm-equivalent focal length calculation and physical lens switching
- **Filter pipeline** — `PRMFilterPipeline` + `PRMBasicFilterRenderer` for real-time GPU processing
- **Filter chain** — `PRMFilterChain` for multi-filter composition with per-filter intensity
- **Built-in filters** — 15 filters: color (4), blur (3), stylize (4), distortion (4)
- **Photo capture** — `PRMPhotoCaptureProcessor` + `PRMPhotoSettingsBuilder` (fluent API)
- **Video capture** — `PRMVideoCaptureHelper` with state machine
- **Depth data** — `PRMDepthHelper` for depth-enabled capture
- **Permissions** — `PRMPermissionHelper` for camera + microphone authorization

### UI
- **Metal preview** — `PRMPreviewMetalView` for low-latency camera preview
- **Camera button** — Configurable shutter button with tap/hold modes
- **Focus view** — Tap-to-focus indicator with animation
- **Grid overlay** — Rule of thirds, golden ratio, crosshair
- **Level indicator** — CoreMotion-based horizon level
- **Aspect ratio overlay** — 4:3, 16:9, 1:1, full frame with crop rect
- **Capture controls** — `PRMCaptureControlHelper` for iPhone 16+ Camera Control button

## Getting Started

```swift
// Package.swift dependency
.package(path: "../Prism")

// Import
import PrismCore
import PrismUI
```

## Building & Testing

```bash
# Build (requires Xcode with iOS SDK)
xcodebuild build -scheme Prism-Package -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO

# Test
xcodebuild test -scheme Prism-Package -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO
```

## Stats

| Metric | Count |
|--------|-------|
| Source files | 36 |
| Test files | 34 |
| Tests | 338 |
| Example files | 8 |

## Example App

The `Example/` directory contains a full camera app demonstrating:
- Live camera preview with filter switching and tap-to-focus
- Pinch-to-zoom, torch toggle, composition grid overlay
- Physical lens switching with 35mm-equivalent focal length labels (e.g., 13 mm, 24 mm, 120 mm)
- Filter chain with stacked built-in filters
- Photo capture with flash modes, aspect ratio overlay
- Video recording with stabilization mode picker and level indicator
- Device controls with zoom, torch, exposure, white balance, stabilization, frame rate
