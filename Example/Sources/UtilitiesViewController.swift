import os
import PrismCore
import UIKit

// MARK: - UtilitiesViewController

/// Demonstrates `PRMLogger` (5 categories), `PRMFileHelper`, `PRMImageHelper`,
/// and `AVCapture+PRM` / `PRMVideoRotationAngle`.
final class UtilitiesViewController: UITableViewController {
    // MARK: - Sections

    private enum Section: Int, CaseIterable {
        case logger
        case fileHelper
        case imageHelper
        case rotationAngles
    }

    private var tempFileURL: URL?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Utilities & Logging"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
    }

    // MARK: - UITableViewDataSource

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .logger: "PRMLogger (5 categories)"
        case .fileHelper: "PRMFileHelper"
        case .imageHelper: "PRMImageHelper"
        case .rotationAngles: "PRMVideoRotationAngle"
        case .none: nil
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .logger: PRMLogCategory.allCases.count
        case .fileHelper: 2
        case .imageHelper: 1
        case .rotationAngles: 6
        case .none: 0
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        var config = cell.defaultContentConfiguration()

        switch Section(rawValue: indexPath.section) {
        case .logger:
            let category = PRMLogCategory.allCases[indexPath.row]
            config.text = category.rawValue
            config.secondaryText = "Tap to log a test message"

        case .fileHelper:
            if indexPath.row == 0 {
                config.text = "Create Temp File"
                config.secondaryText = tempFileURL?.lastPathComponent ?? "Tap to generate"
            } else {
                config.text = "Clear Temp Files"
                config.secondaryText = "PRMFileHelper.clearTemporaryFiles()"
            }

        case .imageHelper:
            config.text = "Image Conversion"
            config.secondaryText = "jpegData(from: CVPixelBuffer) → Data, cgImage(from: CVPixelBuffer) → CGImage"

        case .rotationAngles:
            switch indexPath.row {
            case 0:
                config.text = "portrait"
                config.secondaryText = "\(Int(PRMVideoRotationAngle.portrait))°"
            case 1:
                config.text = "portraitUpsideDown"
                config.secondaryText = "\(Int(PRMVideoRotationAngle.portraitUpsideDown))°"
            case 2:
                config.text = "landscapeRight"
                config.secondaryText = "\(Int(PRMVideoRotationAngle.landscapeRight))°"
            case 3:
                config.text = "landscapeLeft"
                config.secondaryText = "\(Int(PRMVideoRotationAngle.landscapeLeft))°"
            case 4:
                let angle = UIDevice.current.orientation.prm_videoRotationAngle
                config.text = "Current device orientation"
                config.secondaryText = angle.map { "\(Int($0))°" } ?? "N/A (face up/down)"
            case 5:
                let scene = view.window?.windowScene
                let angle = scene?.interfaceOrientation.prm_videoRotationAngle
                config.text = "Current interface orientation"
                config.secondaryText = angle.map { "\(Int($0))°" } ?? "Unknown"
            default:
                break
            }

        case .none:
            break
        }

        cell.contentConfiguration = config
        return cell
    }

    // MARK: - UITableViewDelegate

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        switch Section(rawValue: indexPath.section) {
        case .logger:
            let category = PRMLogCategory.allCases[indexPath.row]
            let logger = PRMLogger.logger(for: category)
            logger.info("Test message from PrismExample — category: \(category.rawValue)")
            showAlert(title: "Logged", message: "Info message sent to \(category.rawValue) logger.\nCheck Console.app with subsystem: com.luminoid.Prism")

        case .fileHelper:
            if indexPath.row == 0 {
                let url = PRMFileHelper.temporaryFileURL(withExtension: "jpg")
                tempFileURL = url
                tableView.reloadRows(at: [indexPath], with: .automatic)
                showAlert(title: "Temp File Created", message: url.path)
            } else {
                PRMFileHelper.clearTemporaryFiles()
                tempFileURL = nil
                tableView.reloadRows(at: [IndexPath(row: 0, section: indexPath.section)], with: .automatic)
                showAlert(title: "Cleared", message: "All temporary files removed.")
            }

        case .imageHelper:
            showAlert(
                title: "PRMImageHelper",
                message: """
                Available conversions:
                • jpegData(from: CVPixelBuffer) → Data?
                • jpegData(from: CIImage) → Data?
                • cgImage(from: CVPixelBuffer) → CGImage?

                Used by capture screens to convert filtered frames.
                """,
            )

        case .rotationAngles:
            // Refresh orientation values
            tableView.reloadSections(IndexSet(integer: indexPath.section), with: .automatic)

        case .none:
            break
        }
    }

    // MARK: - Helpers

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - PRMLogCategory + CaseIterable

extension PRMLogCategory: @retroactive CaseIterable {
    public static var allCases: [PRMLogCategory] {
        [.session, .capture, .filter, .preview, .general]
    }
}
