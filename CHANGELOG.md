# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **PrismCore/Session**: `PRMCameraSessionManager`, `PRMCameraConfiguration`, `PRMCameraDelegate`, `PRMSessionSetupResult` — AVCaptureSession lifecycle, device discovery, focus/exposure, observers
- **PrismCore/Filter**: `PRMCameraFilter` and `PRMCameraFilterRenderer` protocols, `PRMBasicFilterRenderer` (composition-based), `PRMFilterPipeline` (sample buffer routing), `PRMBufferPoolAllocator`
- **PrismCore/Capture**: `PRMPhotoCaptureProcessor` (photo delegate without library saving), `PRMVideoCaptureHelper` (recording lifecycle), `AVCapture+PRM` (rotation angle extensions)
- **PrismCore/Utilities**: `PRMLogger` (os.Logger wrapper), `PRMFileHelper` (temp files), `PRMImageHelper` (pixel buffer → JPEG/CGImage)
- **PrismUI/Preview**: `PRMPreviewMetalView` (Metal-accelerated camera preview with rotation/mirroring), `PassThrough.metal` shader
- **PrismUI/Components**: `PRMCameraFocusView` (tap-to-focus indicator), `PRMCameraButton` (circular shutter button)
- 138 tests across 19 suites (92 PrismCore + 46 PrismUI)
- Zero warnings on iOS Simulator clean build
