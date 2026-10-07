#if canImport(UIKit) && canImport(CoreMotion)
    import CoreMotion
    import UIKit

    // MARK: - PRMLevelIndicatorView

    /// A horizon level indicator that uses device motion to show tilt.
    ///
    /// Draws a horizontal line that rotates based on device roll. Snaps to a
    /// highlight color when the device is within `levelThreshold` degrees of level.
    ///
    /// ```swift
    /// let level = PRMLevelIndicatorView()
    /// level.translatesAutoresizingMaskIntoConstraints = false
    /// cameraView.addSubview(level)
    /// NSLayoutConstraint.activate([
    ///     level.centerXAnchor.constraint(equalTo: cameraView.centerXAnchor),
    ///     level.centerYAnchor.constraint(equalTo: cameraView.centerYAnchor),
    ///     level.widthAnchor.constraint(equalToConstant: 140),
    ///     level.heightAnchor.constraint(equalToConstant: 140),
    /// ])
    /// level.isActive = true  // Starts motion updates
    /// ```
    ///
    /// The view does not install its own size or position constraints — the caller is
    /// responsible. The line is drawn centered in `bounds` and scales with
    /// `lineLengthRatio`, so any square (or rectangular) frame works.
    public final class PRMLevelIndicatorView: UIView {
        // MARK: - Configuration

        /// The default line color when the device is tilted.
        public var lineColor: UIColor = .white {
            didSet { updateLineColor() }
        }

        /// The line color when the device is within the level threshold.
        public var leveledColor: UIColor = .systemYellow {
            didSet { updateLineColor() }
        }

        /// The width of the level indicator line.
        public var lineWidth: CGFloat = 2.0 {
            didSet { shapeLayer.lineWidth = lineWidth }
        }

        /// The length of the indicator line as a fraction of the view's width (0.0-1.0).
        public var lineLengthRatio: CGFloat = 0.3 {
            didSet { updateLinePath() }
        }

        /// The threshold in degrees within which the device is considered level.
        /// Uses hysteresis: enters level state at this threshold, exits at `levelThreshold + 0.5`.
        public var levelThreshold: Double = 1.0

        /// Smoothing factor `α` for the exponential low-pass filter applied to the raw
        /// roll signal (`filtered = α * raw + (1 - α) * filtered_prev`). Range `0.0–1.0`.
        ///
        /// Trade-off:
        /// - `α → 0`: maximum smoothing, but the indicator visibly lags the device by
        ///   100–300 ms when the user tilts quickly.
        /// - `α → 1`: zero smoothing, but raw `CMDeviceMotion` jitter shows up as ±0.5°
        ///   line wobble even on a still device.
        ///
        /// `0.05–0.20` is the practical band for hand-held photography UI; the default
        /// `0.15` matches the iOS Camera app's perceived responsiveness. Smaller values
        /// (`0.05–0.10`) make sense if the indicator drives a deliberate "is level"
        /// snap-and-hold UX; larger values (`0.20–0.30`) if you're driving a continuous
        /// numeric readout next to the line.
        public var smoothingFactor: Double = 0.15

        /// Whether the level indicator is actively tracking device motion.
        ///
        /// Setting to `true` starts motion updates; `false` stops them.
        public var isActive: Bool = false {
            didSet {
                if isActive {
                    startMotionUpdates()
                } else {
                    stopMotionUpdates()
                }
            }
        }

        /// Plays a selection tick when the device becomes level. Off by default.
        public var hapticsEnabled = false

        /// The current roll angle in degrees (read-only). Range is `(-180, 180]`.
        public private(set) var currentRollDegrees: Double = 0

        /// Whether the device is currently within the level threshold (read-only).
        public private(set) var isLevel: Bool = false

        // MARK: - Private

        private let shapeLayer = CAShapeLayer()
        /// `nonisolated(unsafe)` to allow access from nonisolated `deinit`.
        /// Safe because CMMotionManager is only started/stopped on MainActor
        /// except for the final stop in deinit (which runs after all other references are gone).
        ///
        /// Injectable so a host app can pass its own shared instance — Apple documents that a
        /// single CMMotionManager per process is preferred. The default `CMMotionManager()` is
        /// the convenient choice for apps that only show one level indicator at a time.
        private nonisolated(unsafe) let motionManager: CMMotionManager
        /// Whether this view owns the motion manager. An owned manager gets this view's push
        /// handler; a shared one is only read (see ``init(motionManager:)``), so the view
        /// never replaces another consumer's handler or stops updates it didn't start.
        /// `nonisolated` because `deinit` is nonisolated.
        private nonisolated let ownsMotionManager: Bool
        /// Shared manager only: whether this view started its (pull) updates, so it stops
        /// only those.
        private nonisolated(unsafe) var startedSharedUpdates = false
        /// Shared manager only: polls `deviceMotion` at 30 Hz while active.
        private nonisolated(unsafe) var sharedPollTimer: Timer?
        /// The whole degree last written to `accessibilityValue` while tilted.
        private var announcedDegrees: Int?
        private let motionQueue = OperationQueue()
        /// Tracks previous level state to avoid redundant color/accessibility updates.
        private var wasLevel: Bool = false
        /// Low-pass filtered roll value in radians.
        private var filteredRollRadians: Double = 0
        /// Hysteresis margin in degrees — must exceed `levelThreshold + hysteresis` to exit level state.
        private let hysteresisMargin: Double = 0.5

        // MARK: - Initialization

        /// Creates a level indicator with its own internal `CMMotionManager`.
        ///
        /// For apps that already manage a shared `CMMotionManager` (or that show multiple
        /// motion-driven UI elements), use ``init(motionManager:)`` to inject the shared
        /// instance — Apple recommends one CMMotionManager per process.
        public convenience init() {
            self.init(motionManager: CMMotionManager(), ownsMotionManager: true)
        }

        /// Creates a level indicator that shares the given `CMMotionManager`.
        ///
        /// The view reads the manager's latest `deviceMotion` instead of installing its own
        /// handler, so other consumers keep theirs. If device-motion updates aren't running
        /// when the view activates, it starts pull updates and stops them again when it
        /// deactivates; updates someone else started are left alone.
        public convenience init(motionManager: CMMotionManager) {
            self.init(motionManager: motionManager, ownsMotionManager: false)
        }

        private init(motionManager: CMMotionManager, ownsMotionManager: Bool) {
            self.motionManager = motionManager
            self.ownsMotionManager = ownsMotionManager
            super.init(frame: .zero)
            setup()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("Use init() instead")
        }

        deinit {
            sharedPollTimer?.invalidate()
            if ownsMotionManager || startedSharedUpdates {
                motionManager.stopDeviceMotionUpdates()
            }
        }

        private func setup() {
            backgroundColor = .clear
            isUserInteractionEnabled = false
            isAccessibilityElement = true
            accessibilityLabel = String(localized: "Level indicator", bundle: .module)

            shapeLayer.fillColor = nil
            shapeLayer.strokeColor = lineColor.cgColor
            shapeLayer.lineWidth = lineWidth
            shapeLayer.lineCap = .round
            // Disable implicit animations — updates arrive at 30fps from motion data,
            // so Core Animation interpolation adds overhead with no visual benefit.
            shapeLayer.actions = ["transform": NSNull(), "strokeColor": NSNull()]
            layer.addSublayer(shapeLayer)

            motionQueue.maxConcurrentOperationCount = 1
            motionQueue.name = "dev.luminoid.prism.levelIndicator"
        }

        // MARK: - Layout

        override public func layoutSubviews() {
            super.layoutSubviews()
            // Use bounds + position instead of frame — setting frame on a
            // transformed layer is undefined and shifts the visual center.
            shapeLayer.bounds = bounds
            shapeLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            updateLinePath()
        }

        // MARK: - Motion Updates

        private func startMotionUpdates() {
            #if targetEnvironment(simulator)
                // CoreMotion plist lookup crashes on Simulator — no motion hardware available.
                return
            #else
                guard motionManager.isDeviceMotionAvailable else { return }
                guard ownsMotionManager else {
                    startSharedMotionPolling()
                    return
                }
                motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
                motionManager.startDeviceMotionUpdates(to: motionQueue, withHandler: Self.motionHandler(for: self))
            #endif
        }

        /// Builds the owned manager's push handler outside MainActor. `CMDeviceMotionHandler`
        /// isn't `@Sendable`, so a closure written inside a MainActor method is inferred
        /// MainActor-isolated, and CoreMotion calling it on `motionQueue` traps in the
        /// runtime's executor check (`_dispatch_assert_queue_fail`). Formed here, it's
        /// nonisolated and hops to the main actor only to apply the sample.
        private nonisolated static func motionHandler(for view: PRMLevelIndicatorView) -> CMDeviceMotionHandler {
            { [weak view] motion, _ in
                guard let motion else { return }
                let gravityX = motion.gravity.x
                let gravityY = motion.gravity.y
                Task { @MainActor [weak view] in
                    view?.handleGravity(x: gravityX, y: gravityY)
                }
            }
        }

        /// Shared manager: read its latest sample on a timer rather than taking over its
        /// handler.
        private func startSharedMotionPolling() {
            if !motionManager.isDeviceMotionActive {
                motionManager.startDeviceMotionUpdates()
                startedSharedUpdates = true
            }
            sharedPollTimer?.invalidate()
            sharedPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let motion = self.motionManager.deviceMotion else { return }
                    self.handleGravity(x: motion.gravity.x, y: motion.gravity.y)
                }
            }
        }

        /// Turns one gravity sample into the line's rotation, color and accessibility value.
        private func handleGravity(x gravityX: Double, y gravityY: Double) {
            // Use gravity vector instead of attitude.roll — Euler angles
            // suffer from gimbal lock near vertical, causing wild values.
            // atan2(-gx, -gy) projects gravity onto the screen plane and
            // returns 0 when level in portrait, ±π/2 in landscape, ±π upside-down.
            let rawRollRadians = atan2(-gravityX, -gravityY)

            // Low-pass filter (exponential moving average) to smooth jitter.
            filteredRollRadians = smoothingFactor * rawRollRadians + (1.0 - smoothingFactor) * filteredRollRadians

            let rollDegrees = filteredRollRadians * 180.0 / .pi
            currentRollDegrees = rollDegrees

            // Highlight whenever the device is near any cardinal orientation
            // (portrait, landscape-left, landscape-right, upside-down). Deviation
            // from the nearest 90° multiple is wrapped to (-45°, 45°].
            var deviationRadians = filteredRollRadians.truncatingRemainder(dividingBy: .pi / 2)
            if deviationRadians > .pi / 4 { deviationRadians -= .pi / 2 }
            if deviationRadians < -.pi / 4 { deviationRadians += .pi / 2 }
            let deviationDegrees = deviationRadians * 180.0 / .pi

            // Hysteresis: harder to exit level state than to enter it.
            let leveled = if isLevel {
                abs(deviationDegrees) <= levelThreshold + hysteresisMargin
            } else {
                abs(deviationDegrees) <= levelThreshold
            }
            isLevel = leveled

            // Snap-to-cardinal: when leveled, subtract the residual deviation so
            // the line aligns with the nearest 90° multiple (perfectly horizontal
            // in portrait/upside-down, perfectly vertical in landscape).
            let displayRadians = leveled ? filteredRollRadians - deviationRadians : filteredRollRadians
            applyRotation(radians: displayRadians)

            if leveled != wasLevel {
                wasLevel = leveled
                updateLineColor()
                if leveled, hapticsEnabled {
                    UISelectionFeedbackGenerator(view: self).selectionChanged()
                }
            }
            updateAccessibilityValue(leveled: leveled, deviationDegrees: deviationDegrees)
        }

        /// "Level", or the tilt from the nearest level orientation in whole degrees, rewritten
        /// only when that number changes (samples arrive 30-60 times a second).
        private func updateAccessibilityValue(leveled: Bool, deviationDegrees: Double) {
            let degrees: Int? = leveled ? nil : Int(deviationDegrees.rounded())
            guard degrees != announcedDegrees || accessibilityValue == nil else { return }
            announcedDegrees = degrees
            if let degrees {
                accessibilityValue = String(localized: "Tilted \(degrees) degrees", bundle: .module)
            } else {
                accessibilityValue = String(localized: "Level", bundle: .module)
            }
        }

        private func stopMotionUpdates() {
            sharedPollTimer?.invalidate()
            sharedPollTimer = nil
            if ownsMotionManager || startedSharedUpdates {
                motionManager.stopDeviceMotionUpdates()
                startedSharedUpdates = false
            }
            currentRollDegrees = 0
            filteredRollRadians = 0
            isLevel = false
            wasLevel = false
            announcedDegrees = nil
            accessibilityValue = nil
            shapeLayer.transform = CATransform3DIdentity
            updateLineColor()
        }

        // MARK: - Drawing

        private func updateLinePath() {
            let path = UIBezierPath()
            let midY = bounds.midY
            let lineLength = bounds.width * lineLengthRatio
            let startX = (bounds.width - lineLength) / 2
            let endX = startX + lineLength

            path.move(to: CGPoint(x: startX, y: midY))
            path.addLine(to: CGPoint(x: endX, y: midY))

            shapeLayer.path = path.cgPath
        }

        private func updateLineColor() {
            shapeLayer.strokeColor = isLevel ? leveledColor.cgColor : lineColor.cgColor
        }

        /// The rotation is the reading itself, not decoration, so it applies with Reduce Motion
        /// on too (implicit animations are already off, so nothing animates).
        private func applyRotation(radians: Double) {
            shapeLayer.transform = CATransform3DMakeRotation(CGFloat(radians), 0, 0, 1)
        }
    }
#endif
