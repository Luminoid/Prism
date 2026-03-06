import UIKit

// MARK: - ExampleViewController

/// Root catalog of Prism demos. Each row pushes a demo view controller.
/// 5 sections, 7 screens — covering all public Prism APIs.
final class ExampleViewController: UITableViewController {
    // MARK: - Demo Sections

    private enum Section: Int, CaseIterable {
        case gettingStarted
        case camera
        case capture
        case filters
        case utilities
    }

    private struct Demo {
        let title: String
        let subtitle: String
        let makeViewController: () -> UIViewController
    }

    private var demos: [[Demo]] = []

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Prism Example"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")

        demos = [
            // Getting Started
            [
                Demo(
                    title: "Permissions",
                    subtitle: "PRMPermissionHelper — camera/mic status, request, settings URL",
                    makeViewController: { PermissionsViewController() },
                ),
            ],
            // Camera
            [
                Demo(
                    title: "Live Camera Preview",
                    subtitle: "PRMCameraDelegate, grid cycling, focus, zoom, torch, capture",
                    makeViewController: { CameraExampleViewController() },
                ),
                Demo(
                    title: "Device Controls",
                    subtitle: "Zoom, torch, exposure, white balance, stabilization, frame rate",
                    makeViewController: { DeviceControlsViewController() },
                ),
            ],
            // Capture
            [
                Demo(
                    title: "Photo Capture",
                    subtitle: "PRMPhotoSettingsBuilder, depth, capture control, filters",
                    makeViewController: { PhotoCaptureViewController() },
                ),
                Demo(
                    title: "Video Recording",
                    subtitle: "PRMVideoCaptureHelper, recording state, frame rate, level",
                    makeViewController: { VideoCaptureViewController() },
                ),
            ],
            // Filters
            [
                Demo(
                    title: "Filters",
                    subtitle: "18 filters (gallery + chain builder), all categories",
                    makeViewController: { FiltersViewController() },
                ),
            ],
            // Utilities
            [
                Demo(
                    title: "Utilities & Logging",
                    subtitle: "PRMLogger, PRMFileHelper, PRMImageHelper, rotation angles",
                    makeViewController: { UtilitiesViewController() },
                ),
            ],
        ]
    }

    // MARK: - UITableViewDataSource

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        demos[section].count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .gettingStarted: "Getting Started"
        case .camera: "Camera"
        case .capture: "Capture"
        case .filters: "Filters"
        case .utilities: "Utilities"
        case .none: nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        let demo = demos[indexPath.section][indexPath.row]
        var config = cell.defaultContentConfiguration()
        config.text = demo.title
        config.secondaryText = demo.subtitle
        cell.contentConfiguration = config
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    // MARK: - UITableViewDelegate

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let demo = demos[indexPath.section][indexPath.row]
        navigationController?.pushViewController(demo.makeViewController(), animated: true)
    }
}
