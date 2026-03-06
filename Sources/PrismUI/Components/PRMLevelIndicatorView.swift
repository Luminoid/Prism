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
        public var levelThreshold: Double = 1.0

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
            layer.addSublayer(shapeLayer)

            motionQueue.maxConcurrentOperationCount = 1
            motionQueue.name = "com.luminoid.Prism.LevelIndicator"
        }

        // MARK: - Layout

        override public func layoutSubviews() {
            super.layoutSubviews()
            shapeLayer.frame = bounds
            updateLinePath()
        }

        // MARK: - Motion Updates

        private func startMotionUpdates() {
            #if targetEnvironment(simulator)
                // CoreMotion plist lookup crashes on Simulator — no motion hardware available.
                return
            #else
                guard motionManager.isDeviceMotionAvailable else { return }
                motionManager.deviceMotionUpdateInterval = 1.0 / 30.0

                motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, _ in
                    guard let self, let motion else { return }

                    let rollRadians = motion.attitude.roll
                    let rollDegrees = rollRadians * 180.0 / .pi

                    DispatchQueue.main.async {
                        self.currentRollDegrees = rollDegrees
                        self.isLevel = abs(rollDegrees) <= self.levelThreshold
                        self.updateLineColor()
                        self.applyRotation(radians: rollRadians)
                        self.accessibilityValue = self.isLevel ? "Level" : String(format: "%.1f degrees", rollDegrees)
                    }
                }
            #endif
        }

        private func stopMotionUpdates() {
            motionManager.stopDeviceMotionUpdates()
            currentRollDegrees = 0
            isLevel = false
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
