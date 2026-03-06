import CoreImage
import PrismCore

// MARK: - GrayscaleFilter

/// Removes all color — simplest possible CIFilter implementation.
final class GrayscaleFilter: PRMCameraFilter, @unchecked Sendable {
    func render(image: CIImage) -> CIImage? {
        image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
    }
}

// MARK: - SepiaFilter

/// Classic warm-toned sepia effect.
final class SepiaFilter: PRMCameraFilter, @unchecked Sendable {
    func render(image: CIImage) -> CIImage? {
        image.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.8])
    }
}

// MARK: - VignetteFilter

/// Darkens the edges of the frame for a dramatic effect.
final class VignetteFilter: PRMCameraFilter, @unchecked Sendable {
    func render(image: CIImage) -> CIImage? {
        image.applyingFilter("CIVignette", parameters: [
            kCIInputIntensityKey: 1.5,
            kCIInputRadiusKey: 2.0,
        ])
    }
}

// MARK: - FilterCategory

enum FilterCategory: String, CaseIterable, Sendable {
    case custom = "Custom"
    case color = "Color"
    case blur = "Blur"
    case stylize = "Stylize"
    case distortion = "Distortion"
}

// MARK: - ExampleFilterCatalog

/// Provides named filter entries organized by category, covering all 15 built-in
/// Prism filters plus 3 custom example filters.
enum ExampleFilterCatalog {
    struct Entry: Sendable {
        let name: String
        let category: FilterCategory
        let parameters: String
        /// Whether the filter supports continuous intensity adjustment (alpha blending).
        /// Filters that are binary on/off (e.g., Comic, Edges, Pixellate) should be `false`.
        let adjustable: Bool
        let makeFilter: @Sendable () -> any PRMCameraFilter
        let makeRenderer: @Sendable () -> PRMBasicFilterRenderer
    }

    // MARK: - Custom Filters (3)

    static let custom: [Entry] = [
        Entry(
            name: "Grayscale",
            category: .custom,
            parameters: "saturation: 0.0",
            adjustable: true,
            makeFilter: { GrayscaleFilter() },
            makeRenderer: { PRMBasicFilterRenderer(description: "Grayscale") { GrayscaleFilter() } },
        ),
        Entry(
            name: "Sepia",
            category: .custom,
            parameters: "intensity: 0.8",
            adjustable: true,
            makeFilter: { SepiaFilter() },
            makeRenderer: { PRMBasicFilterRenderer(description: "Sepia") { SepiaFilter() } },
        ),
        Entry(
            name: "Vignette",
            category: .custom,
            parameters: "intensity: 1.5, radius: 2.0",
            adjustable: true,
            makeFilter: { VignetteFilter() },
            makeRenderer: { PRMBasicFilterRenderer(description: "Vignette") { VignetteFilter() } },
        ),
    ]

    // MARK: - Color Filters (4)

    static let color: [Entry] = [
        Entry(
            name: "Brightness",
            category: .color,
            parameters: "value: 0.1",
            adjustable: true,
            makeFilter: { PRMBrightnessFilter(value: 0.1) },
            makeRenderer: { PRMBasicFilterRenderer(description: "Brightness") { PRMBrightnessFilter(value: 0.1) } },
        ),
        Entry(
            name: "Contrast",
            category: .color,
            parameters: "value: 1.5",
            adjustable: true,
            makeFilter: { PRMContrastFilter(value: 1.5) },
            makeRenderer: { PRMBasicFilterRenderer(description: "Contrast") { PRMContrastFilter(value: 1.5) } },
        ),
        Entry(
            name: "Saturation",
            category: .color,
            parameters: "value: 1.8",
            adjustable: true,
            makeFilter: { PRMSaturationFilter(value: 1.8) },
            makeRenderer: { PRMBasicFilterRenderer(description: "Saturation") { PRMSaturationFilter(value: 1.8) } },
        ),
        Entry(
            name: "Hue Rotation",
            category: .color,
            parameters: "angle: π/4",
            adjustable: true,
            makeFilter: { PRMHueRotationFilter(angle: .pi / 4) },
            makeRenderer: { PRMBasicFilterRenderer(description: "Hue Rotation") { PRMHueRotationFilter(angle: .pi / 4) } },
        ),
    ]

    // MARK: - Blur Filters (3)

    static let blur: [Entry] = [
        Entry(
            name: "Gaussian Blur",
            category: .blur,
            parameters: "radius: 8.0",
            adjustable: true,
            makeFilter: { PRMGaussianBlurFilter(radius: 8.0) },
            makeRenderer: { PRMBasicFilterRenderer(description: "Gaussian Blur") { PRMGaussianBlurFilter(radius: 8.0) } },
        ),
        Entry(
            name: "Motion Blur",
            category: .blur,
            parameters: "radius: 15.0, angle: 0.0",
            adjustable: true,
            makeFilter: { PRMMotionBlurFilter(radius: 15.0, angle: 0.0) },
            makeRenderer: { PRMBasicFilterRenderer(description: "Motion Blur") { PRMMotionBlurFilter(radius: 15.0, angle: 0.0) } },
        ),
        Entry(
            name: "Zoom Blur",
            category: .blur,
            parameters: "amount: 15.0",
            adjustable: true,
            makeFilter: { PRMZoomBlurFilter(amount: 15.0) },
            makeRenderer: { PRMBasicFilterRenderer(description: "Zoom Blur") { PRMZoomBlurFilter(amount: 15.0) } },
        ),
    ]

    // MARK: - Stylize Filters (4)

    static let stylize: [Entry] = [
        Entry(
            name: "Pixellate",
            category: .stylize,
            parameters: "scale: 8.0",
            adjustable: false,
            makeFilter: { PRMPixellateFilter(scale: 8.0) },
            makeRenderer: { PRMBasicFilterRenderer(description: "Pixellate") { PRMPixellateFilter(scale: 8.0) } },
        ),
        Entry(
            name: "Comic",
            category: .stylize,
            parameters: "(none)",
            adjustable: false,
            makeFilter: { PRMComicFilter() },
            makeRenderer: { PRMBasicFilterRenderer(description: "Comic") { PRMComicFilter() } },
        ),
        Entry(
            name: "Pointillize",
            category: .stylize,
            parameters: "radius: 15.0",
            adjustable: true,
            makeFilter: { PRMPointillizeFilter(radius: 15.0) },
            makeRenderer: { PRMBasicFilterRenderer(description: "Pointillize") { PRMPointillizeFilter(radius: 15.0) } },
        ),
        Entry(
            name: "Edges",
            category: .stylize,
            parameters: "intensity: 1.0",
            adjustable: false,
            makeFilter: { PRMEdgesFilter(intensity: 1.0) },
            makeRenderer: { PRMBasicFilterRenderer(description: "Edges") { PRMEdgesFilter(intensity: 1.0) } },
        ),
    ]

    // MARK: - Distortion Filters (4)

    static let distortion: [Entry] = [
        Entry(
            name: "Bump",
            category: .distortion,
            parameters: "radius: 300, scale: 0.5",
            adjustable: true,
            makeFilter: { PRMBumpDistortionFilter(radius: 300.0, scale: 0.5) },
            makeRenderer: { PRMBasicFilterRenderer(description: "Bump") { PRMBumpDistortionFilter(radius: 300.0, scale: 0.5) } },
        ),
        Entry(
            name: "Twirl",
            category: .distortion,
            parameters: "radius: 300, angle: π",
            adjustable: true,
            makeFilter: { PRMTwirlDistortionFilter(radius: 300.0, angle: .pi) },
            makeRenderer: { PRMBasicFilterRenderer(description: "Twirl") { PRMTwirlDistortionFilter(radius: 300.0, angle: .pi) } },
        ),
        Entry(
            name: "Pinch",
            category: .distortion,
            parameters: "radius: 300, scale: 0.5",
            adjustable: true,
            makeFilter: { PRMPinchDistortionFilter(radius: 300.0, scale: 0.5) },
            makeRenderer: { PRMBasicFilterRenderer(description: "Pinch") { PRMPinchDistortionFilter(radius: 300.0, scale: 0.5) } },
        ),
        Entry(
            name: "Vortex",
            category: .distortion,
            parameters: "radius: 300, angle: 56.55",
            adjustable: true,
            makeFilter: { PRMVortexDistortionFilter(radius: 300.0, angle: 56.55) },
            makeRenderer: { PRMBasicFilterRenderer(description: "Vortex") { PRMVortexDistortionFilter(radius: 300.0, angle: 56.55) } },
        ),
    ]

    // MARK: - Accessors

    /// All 18 filter entries (3 custom + 15 built-in).
    static let all: [Entry] = custom + color + blur + stylize + distortion

    /// Entries for a specific category.
    static func entries(for category: FilterCategory) -> [Entry] {
        switch category {
        case .custom: custom
        case .color: color
        case .blur: blur
        case .stylize: stylize
        case .distortion: distortion
        }
    }
}
