#if canImport(UIKit) && canImport(CoreMotion)
    import CoreMotion
    import SnapKit
    import UIKit

    // MARK: - PRMLevelIndicatorView

    /// A horizon level indicator that uses device motion to show tilt.
    ///
    /// Draws a horizontal line that rotates based on device roll. Snaps to a
    /// highlight color when the device is within `levelThreshold` degrees of level.
    ///
    /// ```swift
    /// let level = PRMLevelIndicatorView()
    /// cameraView.addSubview(level)
    /// level.isActive = true  // Starts motion updates
    /// ```
    public class PRMLevelIndicatorView: UIView {
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

        /// Smoothing factor for the low-pass filter (0.0–1.0).
        /// Lower values = smoother but laggier; higher = more responsive but jittery.
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

        /// The current roll angle in degrees (read-only).
        public private(set) var currentRollDegrees: Double = 0

        /// Whether the device is currently within the level threshold (read-only).
        public private(set) var isLevel: Bool = false

        // MARK: - Private

        private let shapeLayer = CAShapeLayer()
        /// `nonisolated(unsafe)` to allow access from nonisolated `deinit`.
        /// Safe because CMMotionManager is only started/stopped on MainActor
        /// except for the final stop in deinit (which runs after all other references are gone).
        private nonisolated(unsafe) let motionManager = CMMotionManager()
        private let motionQueue = OperationQueue()
        /// Tracks previous level state to avoid redundant color/accessibility updates.
        private var wasLevel: Bool = false
        /// Low-pass filtered roll value in radians.
        private var filteredRollRadians: Double = 0
        /// Hysteresis margin in degrees — must exceed `levelThreshold + hysteresis` to exit level state.
        private let hysteresisMargin: Double = 0.5

        // MARK: - Initialization

        public init() {
            super.init(frame: .zero)
            setup()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("Use init() instead")
        }

        deinit {
            motionManager.stopDeviceMotionUpdates()
        }

        private func setup() {
            backgroundColor = .clear
            isUserInteractionEnabled = false
            isAccessibilityElement = true
            accessibilityLabel = "Level indicator"

            shapeLayer.fillColor = nil
            shapeLayer.strokeColor = lineColor.cgColor
            shapeLayer.lineWidth = lineWidth
            shapeLayer.lineCap = .round
            // Disable implicit animations — updates arrive at 30fps from motion data,
            // so Core Animation interpolation adds overhead with no visual benefit.
            shapeLayer.actions = ["transform": NSNull(), "strokeColor": NSNull()]
            layer.addSublayer(shapeLayer)

            motionQueue.maxConcurrentOperationCount = 1
            motionQueue.name = "com.luminoid.Prism.LevelIndicator"
        }

        // MARK: - Layout

        override public func didMoveToSuperview() {
            super.didMoveToSuperview()
            guard superview != nil else { return }
            snp.makeConstraints { make in
                make.center.equalToSuperview()
                make.width.equalToSuperview()
                make.height.equalTo(snp.width)
            }
        }

        override public func layoutSubviews() {
            super.layoutSubviews()
            // Use bounds + position instead of frame — setting frame on a
            // transformed layer is undefined and shifts the visual center.
            shapeLayer.bounds = bounds
            shapeLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            updateLinePath()
        }

        // MARK: - Motion Updates

        private nonisolated func startMotionUpdates() {
            #if targetEnvironment(simulator)
                // CoreMotion plist lookup crashes on Simulator — no motion hardware available.
                return
            #else
                guard motionManager.isDeviceMotionAvailable else { return }
                motionManager.deviceMotionUpdateInterval = 1.0 / 60.0

                motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, _ in
                    guard let motion else { return }
                    // Use gravity vector instead of attitude.roll — Euler angles
                    // suffer from gimbal lock near vertical, causing wild values.
                    // atan2(gx, -gy) projects gravity onto the screen plane and
                    // returns 0 when level, regardless of device pitch.
                    let gx = motion.gravity.x
                    let gy = motion.gravity.y
                    let rawRollRadians = atan2(-gx, -gy)

                    Task { @MainActor [weak self] in
                        guard let self else { return }

                        // Low-pass filter (exponential moving average) to smooth jitter.
                        let alpha = self.smoothingFactor
                        self.filteredRollRadians = alpha * rawRollRadians + (1.0 - alpha) * self.filteredRollRadians

                        let rollDegrees = self.filteredRollRadians * 180.0 / .pi
                        self.currentRollDegrees = rollDegrees

                        // Hysteresis: harder to exit level state than to enter it.
                        let absDegrees = abs(rollDegrees)
                        let leveled = if self.isLevel {
                            absDegrees <= self.levelThreshold + self.hysteresisMargin
                        } else {
                            absDegrees <= self.levelThreshold
                        }
                        self.isLevel = leveled

                        // Snap-to-zero: show perfectly level when within threshold.
                        let displayRadians = leveled ? 0 : self.filteredRollRadians
                        self.applyRotation(radians: displayRadians)

                        // Only update color and accessibility on state transitions.
                        if leveled != self.wasLevel {
                            self.wasLevel = leveled
                            self.updateLineColor()
                            self.accessibilityValue = leveled
                                ? "Level"
                                : String(format: "%.1f degrees", rollDegrees)
                        }
                    }
                }
            #endif
        }

        private func stopMotionUpdates() {
            motionManager.stopDeviceMotionUpdates()
            currentRollDegrees = 0
            filteredRollRadians = 0
            isLevel = false
            wasLevel = false
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

        private func applyRotation(radians: Double) {
            if UIAccessibility.isReduceMotionEnabled {
                shapeLayer.transform = CATransform3DIdentity
            } else {
                shapeLayer.transform = CATransform3DMakeRotation(CGFloat(radians), 0, 0, 1)
            }
        }
    }
#endif
