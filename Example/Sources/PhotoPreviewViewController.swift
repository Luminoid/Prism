import Photos
import SnapKit
import UIKit

// MARK: - PhotoPreviewViewController

/// Shows a captured photo with a save-to-library button.
/// Pushed from PhotoCaptureViewController after capture completes.
final class PhotoPreviewViewController: UIViewController {
    // MARK: - Properties

    private let photoData: Data
    private let imageView = UIImageView()
    private let saveButton = UIButton(type: .system)
    private var isSaved = false

    // MARK: - Initialization

    init(photoData: Data) {
        self.photoData = photoData
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(photoData:) instead")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Preview"
        view.backgroundColor = .black
        setupUI()
    }

    // MARK: - Setup

    private func setupUI() {
        imageView.contentMode = .scaleAspectFit
        imageView.image = UIImage(data: photoData)
        view.addSubview(imageView)
        imageView.snp.makeConstraints { $0.edges.equalToSuperview() }

        var config = UIButton.Configuration.filled()
        config.title = "Save to Photos"
        config.image = UIImage(systemName: "square.and.arrow.down")
        config.imagePadding = 8
        config.baseBackgroundColor = .white
        config.baseForegroundColor = .black
        config.cornerStyle = .capsule
        saveButton.configuration = config
        saveButton.addTarget(self, action: #selector(savePhoto), for: .touchUpInside)
        view.addSubview(saveButton)
        saveButton.snp.makeConstraints {
            $0.centerX.equalToSuperview()
            $0.bottom.equalTo(view.safeAreaLayoutGuide).offset(-20)
            $0.height.equalTo(50)
        }
    }

    // MARK: - Actions

    @objc private func savePhoto() {
        guard !isSaved, let image = UIImage(data: photoData) else { return }
        isSaved = true
        UIImageWriteToSavedPhotosAlbum(
            image,
            self,
            #selector(imageSaved(_:didFinishSavingWithError:contextInfo:)),
            nil,
        )
    }

    @objc private func imageSaved(
        _ image: UIImage,
        didFinishSavingWithError error: Error?,
        contextInfo: UnsafeRawPointer?,
    ) {
        if let error {
            isSaved = false
            CaptureHelper.showToast("Save failed: \(error.localizedDescription)", in: view)
        } else {
            var config = saveButton.configuration
            config?.title = "Saved"
            config?.image = UIImage(systemName: "checkmark")
            config?.baseBackgroundColor = .systemGreen
            config?.baseForegroundColor = .white
            saveButton.configuration = config
            saveButton.isEnabled = false
            CaptureHelper.showToast("Saved to Photos", in: view)
        }
    }
}
