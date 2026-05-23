@preconcurrency import AVFoundation

// MARK: - Photo / Format management

//
// Split out of `PRMCameraSession.swift` so that file stays focused on session lifecycle
// (configure, start/stop, switch, attach/detach) and this one owns the format-selection
// logic: high-res (48MP) promotion, Live-Photo-compatible restore, baseline format
// snapshotting, auxiliary photo-output flag reconciliation, video-data-output BGRA
// re-binding, and photo-output `maxPhotoDimensions` refresh.
//
// All methods are `@PRMCameraActor`-isolated via the parent class annotation and may
// only be called while a `session.beginConfiguration()` / `commitConfiguration()` block
// is open (where noted in individual docstrings).

#if !os(macOS)
    extension PRMCameraSession {
        /// Sets `output.maxPhotoDimensions` to the largest entry the current device's
        /// active format supports. Without this, per-photo `maxPhotoDimensions` requests
        /// for entries larger than AVFoundation's conservative default ceiling (typically
        /// the 12MP entry) throw `NSInvalidArgumentException` ("must not be larger than
        /// the maxPhotoDimensions set on the AVCapturePhotoOutput").
        ///
        /// Called at photo output attach AND again after every `swapInput` so the
        /// ceiling tracks the device's actual capability across virtual ↔ physical
        /// camera swaps (e.g. triple → wide for manual exposure or 48MP capture).
        func refreshOutputMaxPhotoDimensions() {
            guard let output = photoOutput, let device = videoDevice else { return }
            // Same landscape filter as `applyPreferredPhotoFormatIfNeeded` — portrait
            // entries from video formats would otherwise win an area-based pick on iPhone
            // 15 Pro Max and pin the output ceiling to a 12MP video resolution.
            let supported = device.activeFormat.supportedMaxPhotoDimensions
                .filter { $0.width >= $0.height }
            guard let largest = supported.max(by: { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) }) else { return }
            output.maxPhotoDimensions = largest
        }

        /// Re-applies the video-data-output's pixel-format override against the
        /// **current** active format. `AVCaptureVideoDataOutput.videoSettings` is
        /// honored per-active-format: each `device.activeFormat` swap invalidates
        /// the previous override and AVFoundation falls back to whatever the new
        /// format's `availableVideoCVPixelFormatTypes` declares first — typically
        /// the device's native `420f` YUV. On iPhone Pro models the depth-streaming
        /// format and the portrait-coupled 12MP format both deliver YUV by default
        /// and exclude BGRA from `availableVideoPixelFormatTypes` entirely (the
        /// list is `[420f, 420v, x420, x422, ...]` — no BGRA).
        ///
        /// Without this re-apply, frames after a format swap arrive as YUV; our
        /// preview path hardcodes `bgra8Unorm` and the BufferPoolAllocator
        /// requires `kCVPixelFormatType_32BGRA`, so the preview freezes. Re-writing
        /// `videoSettings` forces AVFoundation to validate against the new format
        /// — it honors the BGRA conversion when available, and we log a loud
        /// `.error` if BGRA isn't even in the list so the silent freeze becomes
        /// a single Console.app grep target.
        func refreshVideoDataOutputPixelFormat() {
            guard let output = videoDataOutput else { return }
            let target = kCVPixelFormatType_32BGRA
            let available = output.availableVideoPixelFormatTypes
            guard available.contains(target) else {
                PRMLogger.session.error(
                    "videoDataOutput: BGRA not in availableVideoCVPixelFormatTypes after format swap (\(available, privacy: .public)) — preview may freeze"
                )
                return
            }
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: target]
        }

        /// Aligns the photo output's Live Photo / depth / portrait-matte / ZSL /
        /// deferred-delivery flags with the active format's capability. Called from
        /// inside `applyPhotoFormat` and `restoreBaselineFormat` while the session
        /// is in a begin/commit window.
        ///
        /// - `highRes: true` — pin every auxiliary stream OFF. The 48MP photo format
        ///   doesn't carry depth, matte, or the Live Photo movie pipeline, and ZSL /
        ///   deferred proxy delivery both substitute 12MP captures. The original
        ///   `PRMCameraConfiguration` is preserved so the inverse path can restore.
        /// - `highRes: false` — re-apply each flag from the original
        ///   `PRMCameraConfiguration` (subject to the output's `is*Supported` gate,
        ///   which is active-format-dependent). Leaves `isLivePhotoCaptureEnabled`
        ///   alone — that runtime state is owned by `setLivePhotoCaptureEnabled(_:)`
        ///   / the consuming app's mode picker, not configure-time defaults.
        func applyAuxiliaryPhotoOutputFlags(highRes: Bool) {
            guard let output = photoOutput else { return }
            let live = output.isLivePhotoCaptureEnabled
            let depth = output.isDepthDataDeliveryEnabled
            let matte = output.isPortraitEffectsMatteDeliveryEnabled
            let zsl = output.isZeroShutterLagEnabled
            let deferred = output.isAutoDeferredPhotoDeliveryEnabled
            PRMLogger.trace(
                .session,
                """
                applyAuxiliaryPhotoOutputFlags(highRes=\(highRes)) entry: \
                live=\(live), depth=\(depth), matte=\(matte), zsl=\(zsl), deferred=\(deferred)
                """
            )
            if highRes {
                if output.isLivePhotoCaptureEnabled {
                    PRMLogger.session.notice("aux-flags(highRes=true): disabling isLivePhotoCaptureEnabled (was true)")
                    output.isLivePhotoCaptureEnabled = false
                }
                if output.isDepthDataDeliverySupported, output.isDepthDataDeliveryEnabled {
                    PRMLogger.session.notice("aux-flags(highRes=true): disabling isDepthDataDeliveryEnabled (was true)")
                    output.isDepthDataDeliveryEnabled = false
                }
                if output.isPortraitEffectsMatteDeliverySupported, output.isPortraitEffectsMatteDeliveryEnabled {
                    PRMLogger.session.notice("aux-flags(highRes=true): disabling isPortraitEffectsMatteDeliveryEnabled (was true)")
                    output.isPortraitEffectsMatteDeliveryEnabled = false
                }
                if output.isAutoDeferredPhotoDeliverySupported, output.isAutoDeferredPhotoDeliveryEnabled {
                    output.isAutoDeferredPhotoDeliveryEnabled = false
                }
                if output.isZeroShutterLagSupported, output.isZeroShutterLagEnabled {
                    output.isZeroShutterLagEnabled = false
                }
            } else {
                guard let configuration else { return }
                if output.isDepthDataDeliverySupported {
                    let want = configuration.enableDepthDataDelivery
                    if output.isDepthDataDeliveryEnabled != want {
                        output.isDepthDataDeliveryEnabled = want
                    }
                }
                if output.isPortraitEffectsMatteDeliverySupported {
                    let want = configuration.enablePortraitEffectsMatteDelivery
                    if output.isPortraitEffectsMatteDeliveryEnabled != want {
                        output.isPortraitEffectsMatteDeliveryEnabled = want
                    }
                }
                if output.isAutoDeferredPhotoDeliverySupported {
                    let want = configuration.enableAutoDeferredPhotoDelivery
                    if output.isAutoDeferredPhotoDeliveryEnabled != want {
                        output.isAutoDeferredPhotoDeliveryEnabled = want
                    }
                }
                if output.isZeroShutterLagSupported {
                    let want = configuration.enableZeroShutterLag
                    if output.isZeroShutterLagEnabled != want {
                        output.isZeroShutterLagEnabled = want
                    }
                }
            }
        }

        /// If `prefersMaxPhotoDimensionsFormat` is set, swap `activeFormat` to the device
        /// format with the largest `supportedMaxPhotoDimensions` area. The `.photo` preset
        /// defaults to a conservative format (typically 12MP) even on iPhone 14 Pro+ /
        /// 15 Pro+ where the wide camera physically supports 48MP. Must run BEFORE
        /// `refreshOutputMaxPhotoDimensions` so the output ceiling pins against the
        /// promoted format.
        ///
        /// Pair the configuration flag with `deviceTypes: [.builtInWideAngleCamera]` —
        /// virtual devices (`triple`, `dual`, `dualWide`) cap at 12MP regardless of the
        /// format chosen, so this helper is a no-op on those.
        func applyPreferredPhotoFormatIfNeeded() {
            guard configuration?.prefersMaxPhotoDimensionsFormat == true else { return }
            applyHighResolutionPhotoFormat()
        }

        /// Promotes `activeFormat` to the device format with the largest landscape
        /// `supportedMaxPhotoDimensions`. Filters to landscape (`width >= height`)
        /// entries — some video formats expose portrait dimensions (e.g. `(3024, 4032)`)
        /// that would otherwise outrank the true 48MP photo format by area on iPhone
        /// 15 Pro Max. **Incompatible with Live Photo / burst / depth streaming** —
        /// call `applyLivePhotoCompatibleFormat()` before re-enabling those.
        ///
        /// Per the workspace AVFoundation lesson catalog and Apple dev-forum 715452 /
        /// 748321, 48MP capture requires the photo output's auxiliary delivery flags
        /// (Live Photo, depth, portrait matte) to be OFF — these all substitute 12MP
        /// proxy captures regardless of the active format. This helper turns them off
        /// inside the same session commit as the format swap so AVFoundation never
        /// sees a "48MP format + depth enabled" transient that would either reject
        /// the swap or downgrade captures to a tiny preview frame.
        func applyHighResolutionPhotoFormat() {
            PRMLogger.trace(.session, "applyHighResolutionPhotoFormat")
            // **Do NOT snapshot `baselineActiveFormat` here.** The configure-time
            // and `swapInput` snapshots are the authoritative "known-good" state.
            // A per-toggle snapshot would clobber that with whatever happens to be
            // active right now — and after a previous toggle-ON cycle the active
            // format is the 48MP one, which Live Photo / depth / matte all reject.
            // Re-toggling OFF would then "restore" to the 48MP format and break
            // every downstream feature that depends on a Live-Photo-compatible
            // active format. Trust the configure / swapInput snapshot — it's the
            // format AVFoundation actually picked at session-startup time when
            // every constraint (Live Photo, depth, BGRA delivery) was satisfied.
            applyPhotoFormat(name: "max-dimensions", maxAreaCeiling: nil, highRes: true)
        }

        /// Restores the active format to whatever was working at configure / pre-high-res
        /// time. **Does not compute a new format from scratch**: format introspection
        /// (`supportedDepthDataFormats`, frame-rate range, etc.) cannot predict whether
        /// `videoDataOutput.availableVideoPixelFormatTypes` will contain BGRA — that's
        /// computed by AVFoundation from the entire connection chain (device → input →
        /// connection → output), and on iPhone 15 Pro Max the 12MP `.photo`-preset
        /// portrait-coupled format excludes BGRA even though it looks identical to the
        /// regular 12MP format by every introspectable signal. So we trust the format
        /// AVFoundation picked at session-configure time (which we just rendered a
        /// preview with) and restore it verbatim.
        ///
        /// Also restores the auxiliary delivery flags (depth / portrait matte /
        /// deferred / ZSL) per `PRMCameraConfiguration` so the pre-toggle capture
        /// pipeline comes back intact.
        ///
        /// Falls back to the scored format pick (≤20MP, non-depth) when no baseline
        /// was captured — happens only if `applyHighResolutionPhotoFormat()` is the
        /// first format-swap call after configure (unusual; the snapshot path
        /// dominates real usage).
        func applyLivePhotoCompatibleFormat() {
            PRMLogger.trace(
                .session,
                "applyLivePhotoCompatibleFormat: baseline=\(baselineActiveFormat == nil ? "nil (will score)" : "captured")"
            )
            if let baseline = baselineActiveFormat {
                restoreBaselineFormat(baseline)
            } else {
                applyPhotoFormat(name: "Live-Photo-compatible", maxAreaCeiling: 20_000_000, highRes: false)
            }
        }

        /// Restore path: re-activate the previously-snapshotted format and re-apply
        /// the auxiliary flags + photo-output ceiling + videoDataOutput pixel-format
        /// override inside a single session begin/commit. No scoring, no probing —
        /// just put the device back where the user last had a working preview.
        private func restoreBaselineFormat(_ baseline: AVCaptureDevice.Format) {
            guard let device = videoDevice else { return }

            session.beginConfiguration()
            defer { session.commitConfiguration() }

            // Reconcile aux flags FIRST so AVFoundation never sees a 48MP-format +
            // aux-flags-on transient on the way back. The current state coming in is
            // "48MP format + aux flags OFF" (set by applyHighResolutionPhotoFormat).
            // Targeting `highRes: false` re-enables depth/matte per PRMCameraConfiguration
            // if the destination format supports them (guarded by isDepthDataDeliverySupported).
            applyAuxiliaryPhotoOutputFlags(highRes: false)

            if baseline !== device.activeFormat {
                do {
                    try device.lockForConfiguration()
                    defer { device.unlockForConfiguration() }
                    device.activeFormat = baseline
                } catch {
                    PRMLogger.session.warning(
                        "Failed to restore baseline activeFormat: \(error.localizedDescription, privacy: .public)"
                    )
                    return
                }
            }

            refreshVideoDataOutputPixelFormat()
            refreshOutputMaxPhotoDimensions()

            let dims = baseline.supportedMaxPhotoDimensions
                .filter { $0.width >= $0.height }
                .max(by: { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) })
            if let dims {
                PRMLogger.session.notice(
                    "applyLivePhotoCompatibleFormat: restored baseline format with maxPhotoDimensions \(dims.width, privacy: .public)×\(dims.height, privacy: .public)"
                )
            }
        }

        /// Shared format-swap path for the high-res / Live-Photo-compatible toggles.
        /// Critical detail: the format swap MUST be wrapped in
        /// `session.beginConfiguration()` / `commitConfiguration()`, not just the
        /// device-level `lockForConfiguration()`. Without the session wrap:
        ///
        /// 1. `device.activeFormat = best` updates the device immediately.
        /// 2. `output.maxPhotoDimensions = largest` is then validated by AVFoundation
        ///    against the SESSION's view of the active format — which is still the
        ///    pre-swap format until the next session commit. The assignment is
        ///    silently clamped to the OLD format's ceiling (typically 12MP).
        /// 3. Subsequent per-photo `settings.maxPhotoDimensions = largest` reads the
        ///    already-clamped output value, requesting (4032, 3024). The 48MP capture
        ///    you toggled on never actually fires — the saved photo stays at 12MP
        ///    with no error surfaced. This is the "Max Dimensions toggle does
        ///    nothing" symptom.
        ///
        /// Wrapping the format swap AND the output-ceiling refresh in a single
        /// session begin/commit forces AVFoundation to re-validate the photo output
        /// against the new active format before the assignment lands, so the 48MP
        /// ceiling sticks.
        ///
        /// Same pattern as `PRMCamera.enableDepthFormat()` — the photo output's
        /// delivery flags re-validate at session commit time, not at device-unlock
        /// time.
        ///
        /// - Parameters:
        ///   - name: Human-readable name for log lines on failure.
        ///   - maxAreaCeiling: When non-nil, only formats whose max landscape area
        ///     is ≤ this value are eligible (used to exclude the 48MP pure-photo
        ///     format from the Live-Photo-compatible path).
        ///   - highRes: `true` for the 48MP path — disables Live Photo / depth /
        ///     portrait matte on the photo output inside the same session commit so
        ///     AVFoundation never sees a 48MP-format + aux-flags-on transient (which
        ///     would either reject the swap or downgrade captures to a 144×192 preview
        ///     proxy). `false` for the Live-Photo-compatible path — restores the
        ///     aux flags from the original `PRMCameraConfiguration` so the toggle-off
        ///     direction recovers depth/matte/Live Photo support.
        private func applyPhotoFormat(name: String, maxAreaCeiling: Int64?, highRes: Bool) {
            guard let device = videoDevice else { return }
            let candidates = Self.scoredFormatCandidates(
                from: device.formats,
                maxAreaCeiling: maxAreaCeiling,
                preferNonDepth: !highRes
            )
            guard let best = Self.bestFormat(from: candidates) else { return }

            session.beginConfiguration()
            defer { session.commitConfiguration() }

            // Reconcile the photo output's auxiliary delivery flags with the destination
            // format BEFORE the format swap. See `applyAuxiliaryPhotoOutputFlags` for
            // the rationale (48MP format incompatibilities + 144×192 proxy bug).
            applyAuxiliaryPhotoOutputFlags(highRes: highRes)

            if best !== device.activeFormat {
                do {
                    try device.lockForConfiguration()
                    defer { device.unlockForConfiguration() }
                    device.activeFormat = best
                } catch {
                    PRMLogger.session.warning(
                        "Failed to apply \(name, privacy: .public) format: \(error.localizedDescription, privacy: .public)"
                    )
                    return
                }
            }

            // Re-apply videoDataOutput's BGRA pixel-format override and the photo
            // output's max-dimensions ceiling against the new active format. Both
            // must run inside the session config so AVFoundation re-validates them
            // against the just-installed format before the commit lands.
            refreshVideoDataOutputPixelFormat()
            refreshOutputMaxPhotoDimensions()

            let pickedDims = best.supportedMaxPhotoDimensions
                .filter { $0.width >= $0.height }
                .max(by: { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) })
            if let pickedDims {
                PRMLogger.session.notice(
                    "applyPhotoFormat(\(name, privacy: .public)) picked format with maxPhotoDimensions \(pickedDims.width, privacy: .public)×\(pickedDims.height, privacy: .public)"
                )
            }
        }

        // MARK: - Pure helpers (Sendable, testable)

        /// Filters the device's format list down to landscape-photo-capable candidates,
        /// optionally capped at a max area and preferring non-depth-streaming formats.
        /// Pure function — no device or session state — so it can be exercised in tests
        /// against synthetic `AVCaptureDevice.Format` lists.
        nonisolated static func scoredFormatCandidates(
            from formats: [AVCaptureDevice.Format],
            maxAreaCeiling: Int64?,
            preferNonDepth: Bool
        ) -> [AVCaptureDevice.Format] {
            let all = formats.filter { format in
                let s = score(format)
                if s == 0 { return false }
                if let ceiling = maxAreaCeiling, s > ceiling { return false }
                return true
            }
            // For the Live-Photo-compatible fallback path (no baseline snapshot
            // available): hard-prefer non-depth formats. Note that
            // `!supportedDepthDataFormats.isEmpty` is NOT a perfect signal — on
            // iPhone 15 Pro Max, the portrait-coupled 12MP format has an empty
            // depth-data list but still excludes BGRA from
            // `availableVideoPixelFormatTypes`. The proper handling is via
            // `applyLivePhotoCompatibleFormat`'s baseline-restore path; this
            // scoring is only the cold-start fallback.
            guard preferNonDepth else { return all }
            let nonDepth = all.filter { !isDepthStreamingFormat($0) }
            return nonDepth.isEmpty ? all : nonDepth
        }

        /// Picks the highest-scored format from `candidates` using a compound ordering:
        /// (1) higher max-photo-dim wins; (2) among ties, the pure-photo format wins
        /// over video-streaming formats; (3) further ties broken by non-depth-streaming
        /// preference.
        nonisolated static func bestFormat(
            from candidates: [AVCaptureDevice.Format]
        ) -> AVCaptureDevice.Format? {
            candidates.max(by: { a, b in
                let scoreA = score(a)
                let scoreB = score(b)
                if scoreA != scoreB { return scoreA < scoreB }
                let photoA = isPhotoFormat(a)
                let photoB = isPhotoFormat(b)
                if photoA != photoB { return !photoA && photoB }
                let depthA = isDepthStreamingFormat(a)
                let depthB = isDepthStreamingFormat(b)
                if depthA != depthB { return depthA && !depthB }
                return false
            })
        }

        /// Landscape max-photo-dimension area, used as the primary format score.
        nonisolated static func score(_ format: AVCaptureDevice.Format) -> Int64 {
            format.supportedMaxPhotoDimensions
                .filter { $0.width >= $0.height }
                .map { Int64($0.width) * Int64($0.height) }
                .max() ?? 0
        }

        /// True dedicated photo format: max frame rate ≤ 30 (video formats can reach
        /// 60/120/240). Used as a tie-breaker so when multiple formats advertise the
        /// 48MP entry, we pick the pure-photo one over a video-streaming format that
        /// happens to list 48MP. iPhone 14 Pro+ / 15 Pro+ wide cameras both have
        /// exactly one such photo format with the 48MP entry — picking a video format
        /// by accident produces captures AVFoundation silently degrades to a preview
        /// proxy because the video pipeline can't actually deliver 48MP frames.
        nonisolated static func isPhotoFormat(_ format: AVCaptureDevice.Format) -> Bool {
            let maxFps = format.videoSupportedFrameRateRanges
                .map(\.maxFrameRate)
                .max() ?? 0
            return maxFps <= 30.0
        }

        /// Whether the format streams depth. On iPhone 14 Pro+ / 15 Pro+,
        /// depth-streaming formats **exclude BGRA** from
        /// `AVCaptureVideoDataOutput.availableVideoPixelFormatTypes` — the
        /// videoDataOutput delivers only YUV (`420f`, `420v`, `x420`, `x422`,
        /// plus 10-bit variants) on those formats. Our preview pipeline + filter
        /// pipeline both hardcode BGRA, so picking a depth-streaming format
        /// freezes the preview (every frame fails the BGRA gate). The
        /// `PRMCamera.enableDepthFormat()` path picks one deliberately when
        /// the consumer enters Portrait mode; the general Live-Photo-compatible
        /// fallback should NOT, because it's invoked on toggle-OFF from Max
        /// Dimensions and the user isn't expecting their preview to die.
        nonisolated static func isDepthStreamingFormat(_ format: AVCaptureDevice.Format) -> Bool {
            !format.supportedDepthDataFormats.isEmpty
        }
    }
#endif
