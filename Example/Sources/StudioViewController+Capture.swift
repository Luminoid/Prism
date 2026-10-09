@preconcurrency import AVFoundation
import CoreImage
import ImageIO
import PrismCore
import PrismUI
import UIKit

// MARK: - AspectCrop

/// What the aspect crop needs, read on the main actor so the crop itself can run off it.
private struct AspectCrop: Sendable {
    /// Long side : short side (`4/3`, `16/9`, `1`).
    let ratio: CGFloat
    let codec: AVVideoCodecType
    let context: PRMRenderContext
}

// MARK: - Shutter

extension StudioViewController {
    /// The shutter button, the hardware buttons and the self-timer all land here. A tap during
    /// the countdown cancels it; taps while a capture is in flight are ignored.
    func handleShutterTap() {
        let modeLabel = mode.label
        let timer = timerSetting.rawValue
        ExampleLog.capture.notice("Studio shutter: mode=\(modeLabel, privacy: .public), timer=\(timer)")
        if countdownTask != nil {
            cancelCountdown()
            toaster.show("Self-timer cancelled")
            return
        }
        guard captureTask == nil else {
            ExampleLog.capture.info("Shutter ignored: a capture is still in flight")
            return
        }
        guard timerSetting != .off, recordingStartedAt == nil else {
            performShutter()
            return
        }
        startCountdown(from: timerSetting.rawValue)
    }

    /// Press-and-hold records in the video modes only, so a long press in a still mode can't
    /// start a recording by accident.
    func handleShutterLongPressBegan() {
        guard mode.isVideo, recordingStartedAt == nil, captureTask == nil, countdownTask == nil else { return }
        startRecording()
    }

    func handleShutterLongPressEnded() {
        guard mode.isVideo, recordingStartedAt != nil || captureTask != nil else { return }
        stopRecording()
    }

    private func performShutter() {
        switch mode {
        case .photo:
            if burstEnabled {
                captureBurst()
            } else {
                capturePhoto()
            }
        case .live:
            captureLivePhoto()
        case .portrait:
            capturePortraitPhoto()
        case .video, .slowMo:
            if recordingStartedAt == nil {
                startRecording()
            } else {
                stopRecording()
            }
        case .night:
            captureNight()
        }
    }

    private func startCountdown(from seconds: Int) {
        countdownLabel.text = "\(seconds)"
        countdownLabel.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: "\(seconds)")
        countdownTask = Task { [weak self] in
            for remaining in stride(from: seconds - 1, through: 0, by: -1) {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard let self else { return }
                guard remaining > 0 else {
                    countdownLabel.isHidden = true
                    countdownTask = nil
                    performShutter()
                    return
                }
                countdownLabel.text = "\(remaining)"
            }
        }
    }

    func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdownLabel.isHidden = true
    }

    /// Runs `body` as the capture in flight (after `pending`, when given): the shutter ignores
    /// taps until it ends, and a failure goes to the toast.
    ///
    /// It starts once the mode setups, flips and camera hops queued before it have landed. A
    /// capture fired mid-setup fails: a recording started while SLO-MO's setup was still
    /// switching to the wide camera stopped with AVError -11805 ("Cannot Record").
    private func runCapture(context: String, after pending: Task<Void, Never>? = nil, _ body: @escaping @MainActor () async throws -> Void) {
        captureGeneration += 1
        let generation = captureGeneration
        captureTask = Task { [weak self] in
            if await self?.awaitSessionWork() == true {
                ExampleLog.capture.info("\(context, privacy: .public) waited for the camera setup in flight")
            }
            await pending?.value
            do {
                try await body()
            } catch {
                self?.toaster.report(error, context: context)
            }
            guard let self, captureGeneration == generation else { return }
            captureTask = nil
        }
    }

    /// Lets a capture in flight finish, and stops and saves a running recording, when Studio
    /// disappears. The host stops the camera once the returned tasks are done. Neither task
    /// needs Studio: a capture saves through static helpers, so leaving never loses a shot.
    func finishCapturesOnExit() -> [Task<Void, Never>] {
        let pendingCapture = captureTask
        guard let videoRecorder, mode.isVideo else {
            return pendingCapture.map { [$0] } ?? []
        }
        let finishing = Task {
            await pendingCapture?.value
            guard case .recording = videoRecorder.state else { return }
            do {
                let recording = try await videoRecorder.stop()
                try await PhotoLibrarySaver.save(.video(recording.url))
                ExampleLog.capture.notice("Saved the recording that was running when Studio closed")
            } catch {
                ExampleLog.capture.error("Recording at close failed: \(PRMLog.describe(error).summary, privacy: .public)")
            }
        }
        exitTask = finishing
        return [finishing]
    }
}

// MARK: - Stills

extension StudioViewController {
    /// Photo settings from the toolbar and the drawer's Format section, rotated to how the
    /// phone is held.
    private func makePhotoSettings(flash: AVCaptureDevice.FlashMode, quality: AVCapturePhotoOutput.QualityPrioritization) -> PRMPhotoSettings {
        var settings = PRMPhotoSettings()
            .flashMode(flash)
            .qualityPrioritization(quality)
            .codec(drawerControls.photoCodec)
            .autoRedEyeReduction(drawerControls.autoRedEyeReductionEnabled)
            .rotationAngle(host.captureRotationAngle)
        // Max Dimensions asks for the camera's largest photo size. `PRMPhotoSettings` checks it
        // against the live output when the shutter fires and falls back to the largest size the
        // output accepts.
        if drawerControls.capMaxDimensions, let largest = camera.device?.maxSupportedPhotoDimensions {
            settings = settings.maxDimensions(largest)
        }
        // The manual ISO and shutter as set, not as the lagging device reports them, so the
        // saved EXIF shows the slider values.
        if let snapshot = camera.currentManualExposureSnapshot {
            settings = settings.manualExposureOverride(iso: snapshot.iso, duration: snapshot.duration)
        }
        return settings
    }

    /// The crop for the aspect ratio on the preview, or `nil` for the full sensor frame.
    private func makeAspectCrop() -> AspectCrop? {
        guard let ratio = aspectMask.aspectRatio.value else { return nil }
        return AspectCrop(ratio: ratio, codec: drawerControls.photoCodec, context: host.renderContext)
    }

    private func capturePhoto() {
        guard let photoCapture else { return }
        let settings = makePhotoSettings(flash: flashSetting.avMode, quality: .quality)
        let crop = makeAspectCrop()
        flashOverlay()
        runCapture(context: "Capture") { [weak self] in
            let photo = try await photoCapture.capturePhoto(settings: settings, willCapture: { [weak self] in
                // The capture queue calls this; hop to the main actor for the haptic.
                Task { @MainActor [weak self] in self?.shutterFlashTick() }
            })
            try await Self.save(photo: photo.data, crop: crop)
            self?.toaster.show("Saved to Photos")
        }
    }

    private func captureBurst() {
        guard let photoCapture else { return }
        let count = 5
        let settings = makePhotoSettings(flash: flashSetting.avMode, quality: .speed)
        let crop = makeAspectCrop()
        flashOverlay()
        runCapture(context: "Burst") { [weak self] in
            let photos: [PRMPhoto]
            var interruption: (any Error)?
            do {
                photos = try await photoCapture.captureBurst(count: count, settings: settings)
            } catch let error as PRMBurstInterruptedError {
                // A later shot failed: keep the ones already taken, then report.
                photos = error.capturedPhotos
                interruption = error.underlyingError
            }
            for photo in photos {
                try await Self.save(photo: photo.data, crop: crop)
            }
            if let interruption {
                self?.toaster.report(interruption, context: "Burst (saved \(photos.count) of \(count))")
            } else {
                self?.toaster.show("Saved \(photos.count) burst photos")
            }
        }
    }

    private func captureLivePhoto() {
        guard let photoCapture else { return }
        let settings = makePhotoSettings(flash: flashSetting.avMode, quality: .quality)
        flashOverlay()
        livePill.setActive(true, text: "LIVE")
        runCapture(context: "Live capture") { [weak self] in
            defer { self?.livePill.setActive(false) }
            let live = try await photoCapture.captureLivePhoto(settings: settings)
            // No aspect crop: re-encoding the still drops the maker note that pairs it with the
            // movie, and Photos would show two separate items. The system Camera saves Live
            // Photos uncropped too.
            try await PhotoLibrarySaver.save(.livePhoto(photo: live.photo.data, movieURL: live.movieURL))
            self?.toaster.show("Saved Live Photo")
        }
    }

    private func capturePortraitPhoto() {
        guard let photoCapture else { return }
        let settings = makePhotoSettings(flash: .off, quality: .quality)
        flashOverlay()
        runCapture(context: "Portrait") { [weak self] in
            let portrait = try await photoCapture.capturePortraitPhoto(settings: settings)
            if portrait.depthData == nil, portrait.portraitEffectsMatte == nil {
                self?.toaster.show("Portrait depth unavailable for this lens; saved a standard photo")
            }
            // Saved as captured, with no aspect crop: the file already carries the depth, the
            // matte and the maker notes Photos needs to render Portrait, and any re-encode
            // would strip them. The system Camera also saves Portrait at full framing.
            try await PhotoLibrarySaver.save(.photo(portrait.photo.data))
            self?.toaster.show("Saved to Photos")
        }
    }

    /// Night: Prism plans the exposure from how dark it is, holds the camera there while it
    /// gathers frames from the live stream, then merges, brightens and saves. The pill counts
    /// down while frames come in ("hold still"), then shows PROCESSING; camera controls wait.
    private func captureNight() {
        guard let nightCapture else { return }
        let options = PRMNightModeOptions(
            duration: nightDuration.requested,
            isStable: stabilityMeter.isStable,
            codec: drawerControls.photoCodec,
            rotationAngle: host.captureRotationAngle
        )
        let crop = makeAspectCrop()
        setNightChrome(true)
        nightPill.setActive(true, text: "NIGHT · HOLD STILL")
        runCapture(context: "Night") { [weak self] in
            defer {
                self?.nightPill.setActive(false)
                self?.setNightChrome(false)
            }
            let photo = try await nightCapture.capture(options) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.showNightProgress(progress)
                }
            }
            try await Self.save(photo: photo.data, crop: crop)
            self?.toaster.show("Saved to Photos (\(photo.mergedFrameCount) frames)")
        }
    }

    private func showNightProgress(_ progress: PRMNightProgress) {
        guard isNightCapturing else { return }
        switch progress.phase {
        case .capturing:
            nightPill.setActive(true, text: "NIGHT \(progress.secondsRemaining)s · HOLD STILL")
        case .processing:
            nightPill.setActive(true, text: "PROCESSING")
        }
    }

    /// A Night capture holds the camera (Prism refuses other camera controls meanwhile), so
    /// mode, camera, lens, zoom, focus and the drawer wait for it, as during a recording.
    private func setNightChrome(_ capturing: Bool) {
        isNightCapturing = capturing
        setRecordingChrome(capturing)
        lensStrip.isUserInteractionEnabled = !capturing
        lensStrip.alpha = capturing ? 0.4 : 1
        if capturing {
            drawer.setOpen(false, animated: true)
        }
    }

    /// The black flash over the screen when the shutter fires.
    private func flashOverlay() {
        let cover = UIView(frame: view.bounds)
        cover.backgroundColor = .black
        cover.isUserInteractionEnabled = false
        view.addSubview(cover)
        UIView.animate(withDuration: 0.25, animations: { cover.alpha = 0 }, completion: { _ in cover.removeFromSuperview() })
    }

    /// A haptic tick when the shutter actually fires (`willCapture`), for the on-screen and the
    /// hardware shutter alike.
    private func shutterFlashTick() {
        UIImpactFeedbackGenerator(style: .light, view: shutter).impactOccurred()
    }
}

// MARK: - Video

extension StudioViewController {
    /// The recorder is read once the setup in flight has landed: a mode change into VIDEO
    /// attaches the movie output only then.
    private func startRecording() {
        let angle = host.captureRotationAngle
        runCapture(context: "Record") { [weak self] in
            guard let self else { return }
            guard mode.isVideo, let videoRecorder else {
                ExampleLog.capture.error("Record refused: the movie output isn't attached")
                toaster.show("Recording isn't ready yet. Try again in a moment.")
                return
            }
            try await videoRecorder.start(rotationAngle: angle)
            recordingDidStart()
        }
    }

    /// Stops after a start that's still under way (a press-and-hold released early).
    private func stopRecording() {
        runCapture(context: "Stop recording", after: captureTask) { [weak self] in
            guard self?.recordingStartedAt != nil, let videoRecorder = self?.videoRecorder else { return }
            let recording: PRMRecording
            do {
                recording = try await videoRecorder.stop()
            } catch {
                self?.stopRecordingTimer()
                throw error
            }
            self?.stopRecordingTimer()
            try await PhotoLibrarySaver.save(.video(recording.url))
            self?.toaster.show("Saved video")
        }
    }

    private func recordingDidStart() {
        recordingStartedAt = Date()
        shutter.setMode(.recordingActive)
        setRecordingChrome(true)
        syncCaptureSounds()
        recordingTimerLabel.isHidden = false
        updateRecordingTimer()
        recordingTimerTask?.cancel()
        recordingTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.updateRecordingTimer()
            }
        }
    }

    func stopRecordingTimer() {
        recordingTimerTask?.cancel()
        recordingTimerTask = nil
        recordingTimerLabel.isHidden = true
        if recordingStartedAt != nil {
            recordingStartedAt = nil
            shutter.setMode(mode.isVideo ? .recording : .photo)
            setRecordingChrome(false)
            syncCaptureSounds()
        }
    }

    private func updateRecordingTimer() {
        guard let started = recordingStartedAt else { return }
        let elapsed = Int(Date().timeIntervalSince(started))
        recordingTimerLabel.text = String(format: "● %02d:%02d", elapsed / 60, elapsed % 60)
        recordingTimerLabel.accessibilityLabel = "Recording, \(elapsed / 60) minutes \(elapsed % 60) seconds"
    }

    /// Modes and cameras can't change mid-recording (the session refuses both), so the mode
    /// picker and the flip button go inactive.
    private func setRecordingChrome(_ recording: Bool) {
        modePicker.isUserInteractionEnabled = !recording
        modePicker.alpha = recording ? 0.4 : 1
        modePicker.accessibilityElementsHidden = recording
        switchCameraButton.isEnabled = !recording
    }
}

// MARK: - Saving

extension StudioViewController {
    /// Crops (when the aspect mask is on) and saves a still. Static and nonisolated, so it
    /// runs to the end even when Studio has gone.
    private nonisolated static func save(photo data: Data, crop: AspectCrop?) async throws {
        var output = data
        if let crop {
            output = await cropped(data, to: crop)
        }
        try await PhotoLibrarySaver.save(.photo(output))
    }

    /// Crops a still to the preview's aspect ratio and re-encodes it in the drawer's codec,
    /// keeping its EXIF and TIFF metadata; the original bytes when decoding or encoding fails.
    /// Off the main actor (`@concurrent`): it decodes and encodes a full-size image, five
    /// times for a burst.
    @concurrent
    private nonisolated static func cropped(_ data: Data, to crop: AspectCrop) async -> Data {
        // Honoring the EXIF orientation gives the upright extent the user framed. Without it
        // the crop runs in sensor coordinates, where 4:3 on a 4:3 sensor crops nothing.
        guard let source = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return data }
        let rect = orientedCropRect(ratio: crop.ratio, in: source.extent)
        // Move the crop to the origin so the encoder writes a tight image, not a full-size
        // canvas with transparent margins.
        let image = source.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.origin.x, y: -rect.origin.y))
        // The pixels are upright now: reset the orientation tag in both places viewers read
        // it, or Photos rotates them a second time.
        var properties = imageProperties(of: data)
        properties[kCGImagePropertyOrientation as String] = 1
        if var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            properties[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        if crop.codec == .hevc,
           let heif = PRMImage.heifDataPreservingMetadata(from: image, sourceExtent: image.extent, originalProperties: properties, context: crop.context) {
            return heif
        }
        return PRMImage.jpegDataPreservingMetadata(from: image, sourceExtent: image.extent, originalProperties: properties, context: crop.context) ?? data
    }

    /// The centered crop of `bounds` at `ratio` (long side : short side), oriented like
    /// `bounds`, so a portrait photo gets a portrait 3:4 crop for 4:3. The same math as
    /// `PRMAspectRatioMaskView.cropRect(in:)`, which is main-actor isolated.
    private nonisolated static func orientedCropRect(ratio: CGFloat, in bounds: CGRect) -> CGRect {
        guard ratio > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let target = bounds.width >= bounds.height ? ratio : 1 / ratio
        let size = bounds.width / bounds.height > target
            ? CGSize(width: bounds.height * target, height: bounds.height)
            : CGSize(width: bounds.width, height: bounds.width / target)
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private nonisolated static func imageProperties(of data: Data) -> [String: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        else { return [:] }
        return properties
    }
}
