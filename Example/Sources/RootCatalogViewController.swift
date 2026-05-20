import SnapKit
import UIKit

// MARK: - RootCatalogViewController

/// Three-demo catalog for the Prism example app.
///
/// 1. **Permissions** — camera / mic status, request flow.
/// 2. **Studio** — DSLR-grade camera app combining preview, lens switching, device controls,
///    photo capture, and video recording.
/// 3. **Filter Chain** — multi-filter pipeline editor with intensity sliders.
final class RootCatalogViewController: UIViewController {
    private struct Demo {
        let title: String
        let subtitle: String
        let symbol: String
        let make: () -> UIViewController
    }

    private let demos: [Demo] = [
        Demo(
            title: "Permissions",
            subtitle: "Camera + microphone access flow",
            symbol: "checkmark.shield",
            make: { PermissionsViewController() }
        ),
        Demo(
            title: "Studio",
            subtitle: "DSLR · all controls + hw shutter + rotation coordinator",
            symbol: "camera.aperture",
            make: { StudioViewController() }
        ),
        Demo(
            title: "Filter Chain",
            subtitle: "Multi-filter chain · reorder · intensity blending",
            symbol: "wand.and.rays",
            make: { FilterChainViewController() }
        ),
        Demo(
            title: "Basic Renderer",
            subtitle: "Single-filter pipeline + filtered photo capture",
            symbol: "camera.macro",
            make: { BasicRendererViewController() }
        ),
        Demo(
            title: "Depth Inspector",
            subtitle: "Live depth map · PRMDepthCapture + filtering",
            symbol: "view.3d",
            make: { DepthInspectorViewController() }
        ),
        Demo(
            title: "Configuration Lab",
            subtitle: "Every PRMCameraConfiguration knob · Apply + reconfigure",
            symbol: "slider.horizontal.3",
            make: { ConfigurationLabViewController() }
        ),
    ]

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Prism"
        navigationItem.largeTitleDisplayMode = .always
        view.backgroundColor = .systemBackground

        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 80
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        view.addSubview(tableView)
        tableView.snp.makeConstraints { $0.edges.equalToSuperview() }
    }
}

extension RootCatalogViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        demos.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let demo = demos[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        var config = cell.defaultContentConfiguration()
        config.text = demo.title
        config.secondaryText = demo.subtitle
        config.image = UIImage(systemName: demo.symbol)
        config.imageProperties.tintColor = .systemYellow
        cell.contentConfiguration = config
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let demo = demos[indexPath.row]
        navigationController?.pushViewController(demo.make(), animated: true)
    }
}
