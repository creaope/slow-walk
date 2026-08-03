@preconcurrency import AVFoundation
import PhotosUI
import SlowWalkClientCore
import SwiftUI

enum MedicineCaptureCopy {
    static let assessmentStartFailed = "无法开始用药检查，请重试。"
    static let capturePrompt = "请拍摄药品标签"
    static let requestingCameraPermission = "正在请求相机权限\u{2026}"
    static let cameraPermissionDenied = "相机权限未开启"
    static let capturing = "正在拍摄\u{2026}"
    static let processingImage = "正在处理药品图片\u{2026}"
    static let noTextFound = "没有识别到文字，请重拍。"
    static let recognitionFailed = "药品图片识别失败"
    static let cancelled = "已取消"
    static let cameraUnavailable = "相机暂时无法使用"
    static let capture = "拍摄"
    static let choosePhoto = "从照片中选择"
    static let cancel = "取消"
    static let retake = "重拍"
    static let close = "关闭用药检查"
    static let recognizedText = "识别到的文字"

    static let allUserVisibleText = [
        assessmentStartFailed, capturePrompt, requestingCameraPermission,
        cameraPermissionDenied, capturing, processingImage, noTextFound,
        recognitionFailed, cancelled, cameraUnavailable, capture, choosePhoto,
        cancel, retake, close, recognizedText,
    ]
}

enum MedicineCaptureControlState: Equatable {
    case captureAndPhotoLibrary
    case photoLibraryOnly
    case cancel
    case retry
    case none

    init(
        captureState: MedicineCaptureState,
        submissionStatus: MedicineAssessmentSubmissionStatus
    ) {
        switch submissionStatus {
        case .submitted:
            self = .none
            return
        case .failed:
            self = .retry
            return
        case .none:
            break
        }

        switch captureState {
        case .idle, .ready:
            self = .captureAndPhotoLibrary
        case .permissionDenied, .cameraUnavailable:
            self = .photoLibraryOnly
        case .capturing, .recognizing:
            self = .cancel
        case .success, .noTextFound, .recognitionFailed, .cancelled:
            self = .retry
        case .requestingPermission:
            self = .none
        }
    }
}

private final class CameraPreviewView: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        for sublayer in layer.sublayers ?? [] { sublayer.frame = bounds }
    }
}

private struct CameraPreview: UIViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer?
    func makeUIView(context: Context) -> CameraPreviewView {
        CameraPreviewView()
    }
    func updateUIView(_ uiView: CameraPreviewView, context: Context) {
        guard let layer = previewLayer else { return }
        if layer.superlayer !== uiView.layer {
            uiView.layer.addSublayer(layer)
        }
        layer.frame = uiView.bounds
    }
}

struct MedicineCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: MedicineCaptureViewModel
    @State private var photosPickerItem: PhotosPickerItem?
    @State private var isSessionStarted = false
    @State private var photoLoadTask: Task<Void, Never>?
    @State private var photoLoadGeneration = 0

    init(viewModel: MedicineCaptureViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        ZStack {
            backgroundView
            overlayView
            controlsView
        }
        .overlay(alignment: .topTrailing) {
            closeButton
                .padding(20)
        }
        .task { await setupSession() }
        .onDisappear {
            isSessionStarted = false
            photoLoadTask?.cancel()
            photoLoadTask = nil
            photoLoadGeneration &+= 1
            Task { await viewModel.dismiss() }
        }
        .onChange(of: photosPickerItem) { _, newItem in
            guard let newItem else { return }
            beginLoadingPhoto(newItem)
        }
    }

    @ViewBuilder private var backgroundView: some View {
        if isSessionStarted {
            CameraPreview(
                previewLayer: viewModel.previewSource.previewLayer
            ).ignoresSafeArea()
        } else { Color.black.ignoresSafeArea() }
    }

    @ViewBuilder private var overlayView: some View {
        if case .failed = viewModel.assessmentSubmissionStatus {
            statusOverlay(
                icon: "exclamationmark.triangle.fill",
                text: MedicineCaptureCopy.assessmentStartFailed
            )
        } else {
            switch viewModel.state {
            case .idle:
                statusOverlay(icon: "camera.fill",
                              text: MedicineCaptureCopy.capturePrompt)
            case .requestingPermission:
                statusOverlay(icon: nil,
                              text: MedicineCaptureCopy.requestingCameraPermission)
            case .permissionDenied:
                statusOverlay(icon: "camera.slash.fill",
                              text: MedicineCaptureCopy.cameraPermissionDenied)
            case .ready:           EmptyView()
            case .capturing:
                statusOverlay(icon: nil, text: MedicineCaptureCopy.capturing)
            case .recognizing:
                statusOverlay(icon: nil, text: MedicineCaptureCopy.processingImage)
            case .success(let observations):
                successPanel(observations)
            case .noTextFound:
                statusOverlay(icon: "text.magnifyingglass",
                              text: MedicineCaptureCopy.noTextFound)
            case .recognitionFailed:
                statusOverlay(icon: "exclamationmark.triangle.fill",
                              text: MedicineCaptureCopy.recognitionFailed)
            case .cancelled:
                statusOverlay(icon: "xmark.circle.fill",
                              text: MedicineCaptureCopy.cancelled)
            case .cameraUnavailable:
                statusOverlay(icon: "camera.fill",
                              text: MedicineCaptureCopy.cameraUnavailable)
            }
        }
    }

    @ViewBuilder private var controlsView: some View {
        VStack {
            Spacer()
            HStack(spacing: 24) {
                switch MedicineCaptureControlState(
                    captureState: viewModel.state,
                    submissionStatus: viewModel.assessmentSubmissionStatus
                ) {
                case .captureAndPhotoLibrary:
                    captureButton
                    photosPickerButton
                case .photoLibraryOnly:
                    photosPickerButton
                case .cancel:
                    cancelButton
                case .retry:
                    retryButton
                case .none:
                    EmptyView()
                }
            }.padding(.bottom, 40)
        }
    }

    private var captureButton: some View {
        Button(action: beginCameraCapture) {
            Circle().fill(Color.white).frame(width: 72, height: 72)
                .overlay(Circle()
                    .stroke(Color.white.opacity(0.3), lineWidth: 4)
                    .frame(width: 84, height: 84))
        }
        .accessibilityLabel(MedicineCaptureCopy.capture)
    }

    private var photosPickerButton: some View {
        PhotosPicker(selection: $photosPickerItem,
                     matching: .images, photoLibrary: .shared()) {
            Image(systemName: "photo.on.rectangle")
                .font(.title2).foregroundColor(.white)
                .frame(width: 48, height: 48)
                .background(Color.white.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .accessibilityLabel(MedicineCaptureCopy.choosePhoto)
    }

    private var cancelButton: some View {
        Button(action: cancelCurrentOperation) {
            Text(MedicineCaptureCopy.cancel)
                .fontWeight(.semibold).foregroundColor(.white)
                .padding(.horizontal, 32).padding(.vertical, 14)
                .background(Color.white.opacity(0.15)).clipShape(Capsule())
        }
    }

    private var retryButton: some View {
        Button(action: { viewModel.reset() }) {
            Label(MedicineCaptureCopy.retake,
                  systemImage: "arrow.counterclockwise")
                .fontWeight(.semibold).foregroundColor(.white)
                .padding(.horizontal, 32).padding(.vertical, 14)
                .background(Color.white.opacity(0.15)).clipShape(Capsule())
        }
    }

    private var closeButton: some View {
        Button(action: closeCapture) {
            Image(systemName: "xmark")
                .font(.headline)
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(Color.black.opacity(0.45))
                .clipShape(Circle())
        }
        .accessibilityLabel(MedicineCaptureCopy.close)
    }

    private func beginCameraCapture() {
        photoLoadTask?.cancel()
        photoLoadTask = nil
        photoLoadGeneration &+= 1
        viewModel.capturePhoto()
    }

    private func cancelCurrentOperation() {
        photoLoadTask?.cancel()
        photoLoadTask = nil
        photoLoadGeneration &+= 1
        viewModel.cancel()
    }

    private func closeCapture() {
        cancelCurrentOperation()
        dismiss()
    }

    private func statusOverlay(icon: String?, text: String) -> some View {
        VStack(spacing: 12) {
            if let icon {
                Image(systemName: icon).font(.system(size: 36))
                    .foregroundColor(.white.opacity(0.5))
            }
            Text(text).foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
        }.padding(.bottom, 100)
    }

    private func successPanel(
        _ observations: [RecognizedTextObservation]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(MedicineCaptureCopy.recognizedText)
                .font(.headline).foregroundColor(.white)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(observations.enumerated()), id: \.offset) {
                        _, obs in
                        Text(obs.text).font(.body.monospaced())
                            .foregroundColor(.white.opacity(0.9))
                            .padding(.vertical, 2).padding(.horizontal, 8)
                            .background(Color.white.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
            }.frame(maxHeight: 200)
        }.padding(20).background(Color.black.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 20).padding(.bottom, 100)
    }

    // MARK: - Actions

    private func setupSession() async {
        let status = CameraCaptureService.authorizationStatus
        switch status {
        case .authorized:
            await startAuthorizedSession()
        case .notDetermined:
            viewModel.requestPermission()
            let granted = await CameraCaptureService.requestPermission()
            guard granted else {
                viewModel.setPermissionAuthorized(false)
                return
            }
            await startAuthorizedSession()
        case .denied, .restricted:
            viewModel.setPermissionAuthorized(false)
        @unknown default:
            viewModel.setCameraUnavailable()
        }
    }

    private func startAuthorizedSession() async {
        do {
            try await viewModel.startSession()
            try Task.checkCancellation()
            isSessionStarted = true
        } catch is CancellationError {
            return
        } catch {
            viewModel.setCameraUnavailable()
        }
    }

    private func beginLoadingPhoto(_ item: PhotosPickerItem) {
        photoLoadTask?.cancel()
        photoLoadGeneration &+= 1
        let generation = photoLoadGeneration
        photoLoadTask = Task {
            do {
                let data = try await item.loadTransferable(
                    type: Data.self
                )
                try Task.checkCancellation()
                guard generation == photoLoadGeneration,
                      let data, !data.isEmpty
                else { return }
                viewModel.capture(
                    imageData: data, orientation: .up, capturedAt: Date()
                )
                photosPickerItem = nil
            } catch is CancellationError { return }
            catch {
                guard generation == photoLoadGeneration else { return }
                viewModel.setPhotoLoadingFailed()
            }
        }
    }
}
