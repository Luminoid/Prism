@preconcurrency import AVFoundation
import PrismCore
import PrismUI

// MARK: - Mode setup

extension StudioViewController {
    /// Sets up ``StudioViewController/mode`` on the session, after any setup still running.
    func scheduleModeChange() {
        syncCaptureSounds()
        // Before the first start there's no session to set up; booting applies the mode.
        guard host.isBooted else { return }
        enqueueSessionWork { [weak self, target = mode] generation in
            await self?.applyMode(target, generation: generation)
        }
    }

    /// Runs `work` once the session work before it has finished, so device swaps and mode
    /// setups never interleave. Superseding work (mode changes, flips) moves
    /// ``StudioViewController/sessionGeneration`` on, and older work that sees it moved stops:
    /// the newer work sets the session up for the newer request.
    @discardableResult
    func enqueueSessionWork(supersedes: Bool = true, _ work: @escaping @MainActor (Int) async -> Void) -> Task<Void, Never> {
        if supersedes {
            sessionGeneration += 1
        }
        let generation = sessionGeneration
        let task = Task { [previous = sessionTask] in
            await previous?.value
            guard !Task.isCancelled else { return }
            await work(generation)
        }
        sessionTask = task
        return task
    }

    func isCurrent(_ generation: Int) -> Bool {
        !Task.isCancelled && generation == sessionGeneration
    }

    /// Configures the session for `target`, one step at a time, stopping when newer work
    /// supersedes it. Each step reads what the session actually has (``appliedMode``, the
    /// slow-motion flag) rather than the previous mode, so a setup that stopped half-way is
    /// completed or undone by the next one.
    func applyMode(_ target: Mode, generation: Int) async {
        let isChange = appliedMode != target
        if isChange {
            guard await setUpSession(for: target, generation: generation) else { return }
        }

        switch target {
        case .photo, .live, .portrait, .night:
            await camera.resetFrameRate()
            shutter.setMode(.photo)
        case .video:
            await camera.setFrameRate(videoFPS.value)
            shutter.setMode(.recording)
        case .slowMo:
            await camera.setFrameRate((camera.device?.maxFrameRate ?? 30) >= 240 ? 240 : 120)
            shutter.setMode(.recording)
        }
        guard isCurrent(generation) else { return }

        // Back to the main lens on a real change, so a 5× zoom from PHOTO doesn't carry into
        // PORTRAIT with the 24mm pill lit. Slow motion resets its own zoom.
        if isChange, target != .slowMo {
            await applyDefaultFocalLength()
            guard isCurrent(generation) else { return }
        }
        appliedMode = target
        if target == .night {
            refreshNightAutoLabel()
        }
    }

    /// The outputs, camera and format a mode change to `target` needs, in order. Returns
    /// `false` when newer work superseded it part-way.
    private func setUpSession(for target: Mode, generation: Int) async -> Bool {
        // Only PORTRAIT streams depth; the stream costs bandwidth the other modes need.
        if target != .portrait {
            await stopPortraitReadiness()
        }

        // Pro iPhones have their 120 / 240 fps formats only on the physical wide camera.
        // Leaving slow motion comes first: its exit re-attaches the photo output with the
        // configuration's Live Photo flag, and the movie-output step below then sets the
        // mode's own.
        if target != .slowMo, slowMoSetupActive {
            // NIGHT runs on the wide camera slow motion already uses: stay on it rather than
            // going back to the virtual camera and hopping again, and return to that camera
            // when NIGHT ends.
            let staysOnWideCamera = target == .night
            let priorType = preSlowMoDeviceType
            await exitSlowMoSetup(restoringDevice: !staysOnWideCamera)
            if staysOnWideCamera, preManualDeviceType == nil, let priorType, Self.virtualDeviceTypes.contains(priorType) {
                preManualDeviceType = priorType
            }
            guard isCurrent(generation) else { return false }
        }

        // Leaving NIGHT (or a manual hop) goes back to the virtual camera unless manual
        // controls still need the wide one. Also before slow motion's setup, which only
        // hops and detaches the photo output when it starts on a camera without 120 fps.
        if target != .night, !slowMoSetupActive {
            await restorePreManualCamera()
            guard isCurrent(generation) else { return false }
        }

        // Live Photo and a movie output can't share a session (with both attached, Live
        // Photo reports unsupported), so only VIDEO and SLO-MO attach the movie output.
        // Live Photo's target state goes into the same begin/commit: two back-to-back
        // toggles strand the movie pipeline on virtual devices. Every mode but LIVE turns
        // Live Photo off, which manual exposure and white-balance lock also need.
        do {
            try await camera.setMovieFileOutputAttached(target.isVideo, targetLivePhoto: target == .live)
        } catch {
            toaster.report(error, context: "Mode switch")
        }
        await refreshVideoRecorder()
        guard isCurrent(generation) else { return false }

        if target == .slowMo, !slowMoSetupActive {
            await enterSlowMoSetup()
            guard isCurrent(generation) else { return false }
        }

        // Every NIGHT frame carries a manual exposure, which virtual cameras can't take
        // (iOS 27 raises on a manual-exposure bracket from one), so NIGHT runs on the
        // physical wide camera, the same hop manual controls make.
        if target == .night {
            await hopToWideCamera()
            guard isCurrent(generation) else { return false }
        }

        // Portrait needs a format that streams depth; the `.photo` preset's default on Pro
        // iPhones doesn't, and its depth would arrive empty. The depth format stays for the
        // session (turning it off would raise while depth delivery is on), so later entries
        // are cheap.
        if target == .portrait {
            if await !camera.enableDepthFormat() {
                ExampleLog.session.info("Portrait: no depth-capable format on this camera")
            }
            // The depth format can limit the constituent lenses.
            rebuildLensStrip()
            guard isCurrent(generation) else { return false }
            await startPortraitReadiness()
            guard isCurrent(generation) else { return false }
        }
        return true
    }

    // MARK: - Portrait readiness

    /// Starts (or, after a camera switch, re-reads) the depth-effect monitor and shows its
    /// status in ``portraitStatusPill``.
    private func startPortraitReadiness() async {
        guard let portraitMonitor else { return }
        do {
            try await portraitMonitor.start()
        } catch {
            toaster.report(error, context: "Portrait depth")
            return
        }
        guard portraitStatusTask == nil else { return }
        portraitStatusTask = Task { [weak self, portraitMonitor] in
            for await readiness in portraitMonitor.readinessStream() {
                self?.showPortraitReadiness(readiness)
            }
        }
    }

    private func stopPortraitReadiness() async {
        guard let portraitMonitor, portraitStatusTask != nil else { return }
        portraitStatusTask?.cancel()
        portraitStatusTask = nil
        portraitStatusPill.hide()
        await portraitMonitor.stop()
    }

    /// The system Camera's wording: "NATURAL LIGHT" in yellow when the depth effect applies,
    /// a hint otherwise, nothing while there's no reading.
    private func showPortraitReadiness(_ readiness: PRMPortraitReadiness) {
        guard mode == .portrait else {
            portraitStatusPill.hide()
            return
        }
        switch readiness {
        case .ready:
            portraitStatusPill.show("NATURAL LIGHT", style: .highlight)
        case .moveFarther:
            portraitStatusPill.show("Move farther away.", style: .hint)
        case .moveCloser:
            portraitStatusPill.show("Place subject within 2.5 m.", style: .hint)
        case .needsMoreLight:
            portraitStatusPill.show("More light required.", style: .hint)
        case .searching, .unavailable:
            portraitStatusPill.hide()
        }
    }

    /// A recorder exists only while the movie output is attached.
    func refreshVideoRecorder() async {
        if await Self.hasMovieOutput(camera.session) {
            videoRecorder = videoRecorder ?? PRMVideoRecorder(session: camera.session)
        } else {
            videoRecorder = nil
        }
    }

    @PRMCameraActor
    private static func hasMovieOutput(_ session: PRMCameraSession) -> Bool {
        session.movieFileOutput != nil
    }

    // MARK: - Slow motion

    /// Hops to the wide camera when the current one has no 120 fps format, after detaching the
    /// photo output: wide camera + photo output (with Live Photo's movie pipeline) + video data
    /// + movie output at 240 fps exceeds the ISP budget, and AVFoundation reports AVError
    /// -11872 ("too many camera hardware resources", WWDC19 session 249). The system Camera
    /// drops the photo output for slow motion for the same reason.
    func enterSlowMoSetup() async {
        guard let current = camera.device, current.maxFrameRate < 120 else { return }
        slowMoSetupActive = true
        preSlowMoDeviceType = current.deviceType
        pipeline.isEnabled = false
        defer { pipeline.isEnabled = true }
        do {
            try await camera.setPhotoOutputAttached(false)
            try await camera.switchDevice(type: .builtInWideAngleCamera, position: current.position)
        } catch {
            toaster.report(error, context: "Enter slo-mo")
            return
        }
        // Slow-motion formats are 16:9 and use less of the sensor; fill the screen like the
        // system Camera instead of letterboxing a smaller frame.
        previewView.contentFit = .fill
        // A digital crop from the previous camera would compound the high-frame-rate crop.
        await camera.setZoom(1)
        await deviceDidChange()
        await applyDefaultFocalLength()
    }

    /// Restores the camera slow motion left and re-attaches the photo output. The output comes
    /// back as a new instance; the session-based capture wrappers resolve it at their next
    /// capture.
    func exitSlowMoSetup(restoringDevice: Bool = true) async {
        slowMoSetupActive = false
        let priorType = preSlowMoDeviceType
        preSlowMoDeviceType = nil
        pipeline.isEnabled = false
        defer { pipeline.isEnabled = true }
        if restoringDevice, let priorType {
            do {
                try await camera.switchDevice(type: priorType, position: camera.device?.position ?? .back)
            } catch {
                toaster.report(error, context: "Exit slo-mo")
            }
        }
        do {
            try await camera.setPhotoOutputAttached(true)
        } catch {
            toaster.report(error, context: "Reattach photo output")
        }
        previewView.contentFit = .fit
        if restoringDevice {
            await deviceDidChange()
        }
    }

    // MARK: - Manual controls

    /// Hops to the physical wide camera before a manual exposure, white-balance or focus
    /// change when the current camera is virtual (triple, dual, dual-wide). Virtual devices
    /// blend constituent cameras whose auto exposure and white balance keep re-asserting
    /// themselves, and they reject custom lens positions; on the wide camera manual values
    /// land and stick.
    ///
    /// The hop queues behind any mode setup or flip in flight; slider ticks that arrive
    /// meanwhile wait for it instead of starting another.
    func prepareForManualExposure() async {
        if let manualHopTask {
            await manualHopTask.value
            return
        }
        guard needsWideCameraForManual else { return }
        let hop = enqueueSessionWork(supersedes: false) { [weak self] _ in await self?.hopToWideCamera() }
        manualHopTask = hop
        await hop.value
        manualHopTask = nil
    }

    private var needsWideCameraForManual: Bool {
        guard let device = camera.device else { return false }
        return Self.virtualDeviceTypes.contains(device.deviceType) && !slowMoSetupActive
    }

    private func hopToWideCamera() async {
        // Checked again: a flip or mode setup queued ahead may have changed the camera.
        guard needsWideCameraForManual, let current = camera.device else { return }
        preManualDeviceType = current.deviceType
        // Each camera meters on its own, and the wide camera's narrower view lands on a
        // different exposure: carry the user's EV offset across.
        let priorBias = camera.state.exposureBias
        pipeline.isEnabled = false
        defer { pipeline.isEnabled = true }
        do {
            try await camera.switchDevice(type: .builtInWideAngleCamera, position: current.position)
        } catch {
            preManualDeviceType = nil
            toaster.report(error, context: "Switch to the wide camera")
            return
        }
        if abs(priorBias) > 0.01 {
            await camera.setExposureBias(priorBias)
        }
        await deviceDidChange()
    }

    /// The reverse hop, once exposure and white balance are both automatic again (and Max
    /// Dimensions, which needs the wide camera, is off). Queued like the hop.
    func restoreVirtualCameraIfFullyAuto() async {
        guard preManualDeviceType != nil else { return }
        await enqueueSessionWork(supersedes: false) { [weak self] _ in await self?.restoreVirtualCamera() }.value
    }

    private func restoreVirtualCamera() async {
        // Slow motion and NIGHT need the wide camera; their mode setup restores on exit.
        guard mode != .slowMo, mode != .night else { return }
        await restorePreManualCamera()
    }

    private func restorePreManualCamera() async {
        guard let priorType = preManualDeviceType else { return }
        let state = camera.state
        let exposureIsAuto = state.exposureMode == .continuousAutoExposure || state.exposureMode == .autoExpose
        let whiteBalanceIsAuto = state.whiteBalanceMode == .continuousAutoWhiteBalance || state.whiteBalanceMode == .autoWhiteBalance
        guard exposureIsAuto, whiteBalanceIsAuto, !drawerControls.capMaxDimensions else { return }
        preManualDeviceType = nil
        pipeline.isEnabled = false
        defer { pipeline.isEnabled = true }
        do {
            try await camera.switchDevice(type: priorType, position: camera.device?.position ?? .back)
        } catch {
            toaster.report(error, context: "Restore the virtual camera")
            return
        }
        await deviceDidChange()
    }

    // MARK: - Camera flip

    /// Flips cameras after any mode setup in flight. Refused while recording (the session
    /// would refuse too).
    func requestFlip() {
        guard host.isBooted else { return }
        guard recordingStartedAt == nil else {
            toaster.show("Stop recording to switch cameras")
            return
        }
        enqueueSessionWork { [weak self] generation in
            await self?.flipCamera(generation: generation)
        }
    }

    /// Switches position, rebuilds what depends on the camera (lens strip, drawer ranges,
    /// slow-motion availability) and sets the current mode up again on the new camera.
    private func flipCamera(generation: Int) async {
        let current = camera.device?.position ?? .back
        let next: AVCaptureDevice.Position = current == .back ? .front : .back
        ExampleLog.session.notice("Studio flip: \(current.rawValue) → \(next.rawValue)")
        if slowMoSetupActive {
            await exitSlowMoSetup(restoringDevice: false)
        }
        // The flip lands on the position's default camera, or for NIGHT straight on the wide
        // camera it runs on (no second switch from the virtual camera), remembering the default
        // to return to.
        preManualDeviceType = nil
        let usualType = await camera.session.defaultVideoDeviceType(at: next)
        pipeline.isEnabled = false
        do {
            if mode == .night, let usualType, Self.virtualDeviceTypes.contains(usualType) {
                try await camera.switchDevice(type: .builtInWideAngleCamera, position: next)
                preManualDeviceType = usualType
            } else {
                try await camera.switchCamera(to: next)
            }
        } catch {
            pipeline.isEnabled = true
            toaster.report(error, context: "Switch camera")
            return
        }
        await deviceDidChange()
        pipeline.isEnabled = true
        // The drawer's ranges, shutter stops and Sensor Aspect segments come from the camera,
        // so rebuild it (a button tap, so no slider is under a finger).
        populateDrawer()
        populateModeStrip()
        if mode == .slowMo, !modePicker.supportsSlowMotion {
            // No slow motion here: fall back to 30 fps video. Setting the mode queues its setup.
            videoFPS = .fps30
            modePicker.select(primary: .video, variant: .video30)
            mode = .video
            return
        }
        appliedMode = nil
        await applyMode(mode, generation: generation)
    }

    // MARK: - Device changes and rotation

    /// Cinematic Video switched cameras (to the Dual Wide camera on a Pro iPhone, or back).
    /// The camera it left was the one to return to, so a manual hop's memory no longer
    /// applies.
    func cinematicVideoDidChangeCamera() async {
        preManualDeviceType = nil
        await deviceDidChange()
    }

    /// After every device change: bind a rotation coordinator to the new device (which also
    /// orients the preview for it), and refresh what depends on the device without
    /// rebuilding the drawer (a slider may be under the finger).
    func deviceDidChange() async {
        await host.rebindRotationCoordinator()
        rebuildLensStrip()
        drawerControls.deviceDidChange(camera.device)
    }
}
