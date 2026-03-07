import AVFoundation
import PrismCore
import PrismUI
import SnapKit
import UIKit

// MARK: - VideoCaptureViewController

/// Demonstrates video recording using PRMVideoCaptureHelper, PRMVideoRecordingState
/// display, stabilization mode, interactive frame rate control, PRMLevelIndicatorView,
/// and PRMFileHelper for output paths.
final class VideoCaptureViewController: UIViewController {
    // MARK: - Properties

    private let sessionManager = PRMCameraSessionManager()
    private let filterPipeline = PRMFilterPipeline()
    private let videoCaptureHelper = PRMVideoCaptureHelper()
    private let previewView = PRMPreviewMetalView(frame: .zero)
    private let recordButton = PRMCameraButton()
    private let timerLabel = UILabel()
    private let statusLabel = UILabel()
    private let stateBadge = UILabel()
    private let levelIndicator = PRMLevelIndicatorView()
    private let frameRateSlider = UISlider()
    private let frameRateLabel = UILabel()
    private let filePathLabel = UILabel()

    private let dataOutputQueue = DispatchQueue(
        label: "com.luminoid.PrismExample.VideoRecordOutput",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem,
    )

    private var movieFileOutput: AVCaptureMovieFileOutput?
    private var timerTask: Task<Void, Never>?
    private var recordingSeconds = 0
    private var maxFPS: Float64 = 30

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Video Recording"
        view.backgroundColor = .black
        setupUI()
        setupCamera()
        setupVideoCallbacks()
        updateStateBadge(.idle)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        levelIndicator.isActive = true
        let sm = sessionManager
        sm.sessionQueue.async { sm.startSession() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        levelIndicator.isActive = false
        stopRecordingIfNeeded()
        let sm = sessionManager
        sm.sessionQueue.async { sm.stopSession() }
    }

    // MARK: - Setup

    private func setupUI() {
        view.addSubview(previewView)
        previewView.snp.makeConstraints { $0.edges.equalToSuperview() }

        // Level indicator at center
        view.addSubview(levelIndicator)
        levelIndicator.snp.makeConstraints {
            $0.center.equalToSuperview()
            $0.width.equalTo(200)
            $0.height.equalTo(40)
        }

        // State badge (IDLE / REC / FINALIZING)
        stateBadge.font = .monospacedSystemFont(ofSize: 13, weight: .bold)
        stateBadge.textAlignment = .center
        stateBadge.layer.cornerRadius = 6
        stateBadge.clipsToBounds = true
        view.addSubview(stateBadge)
        stateBadge.snp.makeConstraints {
            $0.top.equalTo(view.safeAreaLayoutGuide).offset(12)
            $0.trailing.equalToSuperview().inset(16)
            $0.width.equalTo(100)
            $0.height.equalTo(26)
        }

        // Timer label
        timerLabel.text = "00:00"
        timerLabel.textColor = .white
        timerLabel.font = .monospacedDigitSystemFont(ofSize: 20, weight: .medium)
        timerLabel.textAlignment = .center
        timerLabel.isHidden = true
        view.addSubview(timerLabel)
        timerLabel.snp.makeConstraints {
            $0.top.equalTo(view.safeAreaLayoutGuide).offset(16)
            $0.centerX.equalToSuperview()
        }

        // Stabilization mode picker
        let stabLabel = UILabel()
        stabLabel.text = "Stabilization"
        stabLabel.textColor = .white
        stabLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        stabLabel.textAlignment = .center
        view.addSubview(stabLabel)
        stabLabel.snp.makeConstraints {
            $0.top.equalTo(timerLabel.snp.bottom).offset(8)
            $0.leading.trailing.equalToSuperview().inset(16)
        }

        let stabSegmented = UISegmentedControl(items: ["Off", "Standard", "Cinematic", "Auto"])
        stabSegmented.selectedSegmentIndex = 0
        stabSegmented.addTarget(self, action: #selector(stabilizationChanged(_:)), for: .valueChanged)
        stabSegmented.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        view.addSubview(stabSegmented)
        stabSegmented.snp.makeConstraints {
            $0.top.equalTo(stabLabel.snp.bottom).offset(4)
            $0.leading.trailing.equalToSuperview().inset(16)
        }

        // Frame rate slider
        frameRateLabel.textColor = .white
        frameRateLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        frameRateLabel.text = "Frame Rate: 30 fps"
        frameRateLabel.textAlignment = .center
        view.addSubview(frameRateLabel)
        frameRateLabel.snp.makeConstraints {
            $0.top.equalTo(stabSegmented.snp.bottom).offset(8)
            $0.leading.trailing.equalToSuperview().inset(16)
        }

        frameRateSlider.minimumValue = 1
        frameRateSlider.maximumValue = 30
        frameRateSlider.value = 30
        frameRateSlider.addTarget(self, action: #selector(frameRateChanged(_:)), for: .valueChanged)
        view.addSubview(frameRateSlider)
        frameRateSlider.snp.makeConstraints {
            $0.top.equalTo(frameRateLabel.snp.bottom).offset(4)
            $0.leading.trailing.equalToSuperview().inset(16)
        }

        // File path label
        filePathLabel.textColor = .lightGray
        filePathLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        filePathLabel.textAlignment = .center
        filePathLabel.numberOfLines = 2
        view.addSubview(filePathLabel)
        filePathLabel.snp.makeConstraints {
            $0.bottom.equalTo(view.safeAreaLayoutGuide).offset(-104)
            $0.leading.trailing.equalToSuperview().inset(16)
        }

        // Status label
        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 14)
        statusLabel.textAlignment = .center
        statusLabel.text = "Tap to record"
        view.addSubview(statusLabel)
        statusLabel.snp.makeConstraints {
            $0.bottom.equalTo(filePathLabel.snp.top).offset(-8)
            $0.centerX.equalToSuperview()
        }

        // Record button
        recordButton.fillColor = .systemRed
        view.addSubview(recordButton)
        recordButton.snp.makeConstraints {
            $0.centerX.equalToSuperview()
            $0.bottom.equalTo(view.safeAreaLayoutGuide).offset(-20)
            $0.size.equalTo(CGSize(width: 72, height: 72))
        }
        recordButton.onTap = { [weak self] in
            self?.toggleRecording()
        }
    }

    private func setupCamera() {
        let preview = previewView
        let sm = sessionManager
        let pipeline = filterPipeline
        let outputQueue = dataOutputQueue

        pipeline.onFrame = { pixelBuffer, _ in
            preview.pixelBuffer = pixelBuffer
            preview.requestDraw()
        }

        sm.sessionQueue.async { [weak self] in
            sm.checkAuthorization()

            let config = PRMCameraConfiguration(
                sessionPreset: .hd1920x1080,
                includesPhotoOutput: false,
            )
            sm.configureSession(
                with: config,
                videoDataOutputDelegate: pipeline,
                videoDataOutputQueue: outputQueue,
            )
            pipeline.isRenderingEnabled = true

            // Add movie file output
            let output = AVCaptureMovieFileOutput()
            var movieOutputAdded = false
            if sm.session.canAddOutput(output) {
                sm.session.beginConfiguration()
                sm.session.addOutput(output)
                sm.session.commitConfiguration()
                movieOutputAdded = true
            }

            // Frame rate info
            if let device = sm.videoDevice {
                let ranges = PRMFrameRateHelper.supportedFrameRateRanges(for: device)
                let deviceMaxFPS = PRMFrameRateHelper.maxSupportedFrameRate(for: device)
                let slowMo = PRMFrameRateHelper.supportsSlowMotion(on: device)

                DispatchQueue.main.async {
                    self?.maxFPS = deviceMaxFPS
                    self?.frameRateSlider.maximumValue = Float(deviceMaxFPS)
                    self?.frameRateSlider.value = Float(deviceMaxFPS)
                    self?.frameRateLabel.text = "Frame Rate: \(Int(deviceMaxFPS)) fps"
                    if movieOutputAdded { self?.movieFileOutput = output }
                    self?.statusLabel.text = "Max \(Int(deviceMaxFPS))fps | SlowMo: \(slowMo ? "Yes" : "No") | \(ranges.count) range(s)"
                    preview.rotation = .rotate90Degrees
                }
            } else {
                DispatchQueue.main.async {
                    if movieOutputAdded { self?.movieFileOutput = output }
                    preview.rotation = .rotate90Degrees
                }
            }
        }
    }

    private func setupVideoCallbacks() {
        videoCaptureHelper.onRecordingStarted = { [weak self] in
            DispatchQueue.main.async {
                self?.updateStateBadge(.recording)
                self?.timerLabel.isHidden = false
                self?.startTimer()
            }
        }

        videoCaptureHelper.onRecordingFinished = { [weak self] url, error in
            DispatchQueue.main.async {
                self?.updateStateBadge(.idle)
                self?.timerLabel.isHidden = true
                self?.stopTimer()

                if let error {
                    self?.statusLabel.text = "Error: \(error.localizedDescription)"
                    self?.filePathLabel.text = nil
                } else if let url {
                    // Show file info
                    let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                    let sizeMB = String(format: "%.1f", Double(fileSize) / 1_048_576.0)
                    self?.statusLabel.text = "Recorded \(sizeMB) MB"
                    self?.filePathLabel.text = url.lastPathComponent
                    self?.saveVideoToAlbum(url: url)
                }
            }
        }
    }

    // MARK: - Actions

    @objc private func stabilizationChanged(_ sender: UISegmentedControl) {
        let modes: [AVCaptureVideoStabilizationMode] = [.off, .standard, .cinematic, .auto]
        sessionManager.setStabilizationMode(modes[sender.selectedSegmentIndex])
    }

    @objc private func frameRateChanged(_ sender: UISlider) {
        let fps = Float64(Int(sender.value))
        frameRateLabel.text = "Frame Rate: \(Int(fps)) fps"
        sessionManager.setFrameRate(fps)
    }

    // MARK: - Recording

    private func toggleRecording() {
        guard let movieFileOutput else { return }

        if videoCaptureHelper.state == .idle {
            // Show temp file path before recording
            let tempURL = PRMFileHelper.temporaryFileURL(withExtension: "mov")
            filePathLabel.text = "Output: \(tempURL.lastPathComponent)"

            // Capture orientation on main thread, then start recording on session queue
            let angle = videoCaptureHelper.currentVideoRotationAngle()
            let helper = videoCaptureHelper
            let sm = sessionManager
            sm.sessionQueue.async {
                helper.startRecording(to: movieFileOutput, videoRotationAngle: angle)
            }
            recordButton.fillColor = .white
            frameRateSlider.isEnabled = false
        } else {
            updateStateBadge(.finalizing)
            let helper = videoCaptureHelper
            let sm = sessionManager
            sm.sessionQueue.async {
                helper.stopRecording(to: movieFileOutput)
            }
            recordButton.fillColor = .systemRed
            frameRateSlider.isEnabled = true
        }
    }

    private func stopRecordingIfNeeded() {
        guard let movieFileOutput, videoCaptureHelper.state == .recording else { return }
        let helper = videoCaptureHelper
        let sm = sessionManager
        sm.sessionQueue.async {
            helper.stopRecording(to: movieFileOutput)
        }
    }

    private func updateStateBadge(_ state: PRMVideoRecordingState) {
        switch state {
        case .idle:
            stateBadge.text = "IDLE"
            stateBadge.textColor = .white
            stateBadge.backgroundColor = UIColor.gray.withAlphaComponent(0.6)
        case .recording:
            stateBadge.text = "REC"
            stateBadge.textColor = .white
            stateBadge.backgroundColor = UIColor.systemRed.withAlphaComponent(0.8)
        case .finalizing:
            stateBadge.text = "FINALIZING"
            stateBadge.textColor = .black
            stateBadge.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.8)
        }
    }

    // MARK: - Timer

    private func startTimer() {
        recordingSeconds = 0
        updateTimerDisplay()

        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    self?.recordingSeconds += 1
                    self?.updateTimerDisplay()
                }
            }
        }
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
    }

    private func updateTimerDisplay() {
        let minutes = recordingSeconds / 60
        let seconds = recordingSeconds % 60
        timerLabel.text = String(format: "%02d:%02d", minutes, seconds)
    }

    // MARK: - Save to Album

    private func saveVideoToAlbum(url: URL) {
        guard UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(url.path) else {
            statusLabel.text = "Video format not compatible"
            return
        }
        UISaveVideoAtPathToSavedPhotosAlbum(url.path, self, #selector(videoSaved(_:didFinishSavingWithError:contextInfo:)), nil)
    }

    @objc private func videoSaved(_ videoPath: String, didFinishSavingWithError error: Error?, contextInfo: UnsafeRawPointer?) {
        if let error {
            statusLabel.text = "Save failed: \(error.localizedDescription)"
        } else {
            statusLabel.text = "Saved to Photos"
        }
    }

    deinit {
        timerTask?.cancel()
    }
}
