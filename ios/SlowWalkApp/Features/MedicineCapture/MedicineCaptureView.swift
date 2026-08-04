@preconcurrency import AVFoundation
import PhotosUI
import SlowWalkClientCore
import SwiftUI
import UIKit

enum MedicineCaptureCopy {
    static let assessmentStartFailed = "无法开始用药检查，请重试。"
    static let capturePrompt = "请拍摄药品标签"
    static let requestingCameraPermission = "正在请求相机权限\u{2026}"
    static let startingCamera = "正在打开相机\u{2026}"
    static let cameraPermissionDenied =
        "相机权限已关闭。可以前往设置开启，或从相册选择药品照片。"
    static let cameraRestricted =
        "此设备当前无法使用相机。可以改从相册选择药品照片。"
    static let capturing = "正在拍摄\u{2026}"
    static let loadingPhoto = "正在读取照片\u{2026}"
    static let processingImage = "正在处理药品图片\u{2026}"
    static let noTextFound = "没有识别到文字，请重拍。"
    static let recognitionFailed = "药品图片识别失败"
    static let cancelled = "已取消"
    static let cameraUnavailable =
        "此设备暂时无法使用相机。可以改从相册选择药品照片。"
    static let useCamera = "使用相机"
    static let capture = "拍摄"
    static let choosePhoto = "从相册选择"
    static let openSettings = "前往设置"
    static let retry = "重新尝试"
    static let cancel = "取消"
    static let retake = "重拍"
    static let close = "关闭用药检查"
    static let recognizedText = "识别到的文字"

    static let allUserVisibleText = [
        assessmentStartFailed, capturePrompt, requestingCameraPermission,
        startingCamera, cameraPermissionDenied, cameraRestricted, capturing,
        loadingPhoto, processingImage, noTextFound, recognitionFailed,
        cancelled, cameraUnavailable, useCamera, capture, choosePhoto,
        openSettings, retry, cancel, retake, close, recognizedText,
    ]
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
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel: MedicineCaptureViewModel
    @State private var photosPickerItem: PhotosPickerItem?
    @State private var isPhotosPickerPresented = false
    @State private var activePhotoLoadID: UUID?
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
        .onDisappear {
            photoLoadTask?.cancel()
            photoLoadTask = nil
            activePhotoLoadID = nil
            isPhotosPickerPresented = false
            viewModel.endPhotosPickerPresentation()
            photoLoadGeneration &+= 1
            Task { await viewModel.dismiss() }
        }
        .onChange(of: photosPickerItem) { _, newItem in
            guard let newItem else { return }
            beginLoadingPhoto(newItem)
        }
        .onChange(of: scenePhase) { _, newPhase in
            scenePhaseDidChange(newPhase)
        }
        .photosPicker(
            isPresented: photosPickerPresentationBinding,
            selection: $photosPickerItem,
            matching: .images
        )
    }

    @ViewBuilder private var backgroundView: some View {
        if viewModel.isCameraSessionStarted {
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
            case .cameraRestricted:
                statusOverlay(icon: "camera.slash.fill",
                              text: MedicineCaptureCopy.cameraRestricted)
            case .startingCamera:
                statusOverlay(icon: nil, text: MedicineCaptureCopy.startingCamera)
            case .ready:           EmptyView()
            case .capturing:
                statusOverlay(icon: nil, text: MedicineCaptureCopy.capturing)
            case .loadingPhoto:
                statusOverlay(icon: nil, text: MedicineCaptureCopy.loadingPhoto)
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
                switch viewModel.assessmentSubmissionStatus {
                case .submitted:
                    EmptyView()
                case .failed:
                    retryButton
                case .none:
                    switch viewModel.state {
                    case .idle:
                        cameraButton; photosPickerButton
                    case .ready:
                        captureButton; photosPickerButton
                    case .permissionDenied:
                        if canOpenSettings { settingsButton }
                        photosPickerButton
                    case .cameraRestricted:
                        photosPickerButton
                    case .cameraUnavailable:
                        retryCameraButton; photosPickerButton
                    case .requestingPermission, .startingCamera,
                         .capturing, .loadingPhoto, .recognizing:
                        cancelButton
                    case .success, .noTextFound,
                         .recognitionFailed, .cancelled:
                        retryButton
                    }
                }
            }.padding(.bottom, 40)
        }
    }

    private var cameraButton: some View {
        Button(action: beginCameraCapture) {
            Image(systemName: "camera.fill")
                .font(.title2).foregroundColor(.white)
                .frame(width: 48, height: 48)
                .background(Color.white.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityLabel(MedicineCaptureCopy.useCamera)
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
        Button(action: presentPhotosPicker) {
            Image(systemName: "photo.on.rectangle")
                .font(.title2).foregroundColor(.white)
                .frame(width: 48, height: 48)
                .background(Color.white.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityLabel(MedicineCaptureCopy.choosePhoto)
        .disabled(!viewModel.canChoosePhoto)
    }

    private var settingsButton: some View {
        Button(action: openSettings) {
            Label(MedicineCaptureCopy.openSettings, systemImage: "gearshape")
                .fontWeight(.semibold)
                .foregroundColor(.white)
                .padding(.horizontal, 20).padding(.vertical, 14)
                .background(Color.white.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var retryCameraButton: some View {
        Button(action: { viewModel.reset() }) {
            Label(MedicineCaptureCopy.retry, systemImage: "arrow.clockwise")
                .fontWeight(.semibold)
                .foregroundColor(.white)
                .padding(.horizontal, 20).padding(.vertical, 14)
                .background(Color.white.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
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
        switch viewModel.state {
        case .idle:
            viewModel.beginCameraPresentation()
        case .ready:
            viewModel.capturePhoto()
        default:
            break
        }
    }

    private func cancelCurrentOperation() {
        photoLoadTask?.cancel()
        photoLoadTask = nil
        activePhotoLoadID = nil
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

    private var photosPickerPresentationBinding: Binding<Bool> {
        Binding(
            get: { isPhotosPickerPresented },
            set: { isPresented in
                isPhotosPickerPresented = isPresented
                if !isPresented {
                    viewModel.endPhotosPickerPresentation()
                }
            }
        )
    }

    private func presentPhotosPicker() {
        guard viewModel.beginPhotosPickerPresentation() else { return }
        isPhotosPickerPresented = true
    }

    private func beginLoadingPhoto(_ item: PhotosPickerItem) {
        guard photoLoadTask == nil,
              let loadID = viewModel.beginPhotoLoading()
        else {
            photosPickerItem = nil
            return
        }
        activePhotoLoadID = loadID
        photosPickerItem = nil
        isPhotosPickerPresented = false
        viewModel.endPhotosPickerPresentation()
        photoLoadGeneration &+= 1
        let generation = photoLoadGeneration
        photoLoadTask = Task {
            defer {
                if activePhotoLoadID == loadID {
                    activePhotoLoadID = nil
                    photoLoadTask = nil
                }
            }
            do {
                let data = try await item.loadTransferable(
                    type: Data.self
                )
                try Task.checkCancellation()
                guard generation == photoLoadGeneration,
                      activePhotoLoadID == loadID
                else { return }
                guard let data, !data.isEmpty else {
                    viewModel.photoLoadingFailed(loadID: loadID)
                    return
                }
                _ = viewModel.submitLoadedPhoto(
                    loadID: loadID,
                    imageData: data,
                    orientation: .up,
                    capturedAt: Date()
                )
            } catch is CancellationError { return }
            catch {
                guard generation == photoLoadGeneration,
                      activePhotoLoadID == loadID
                else { return }
                viewModel.photoLoadingFailed(loadID: loadID)
            }
        }
    }

    private func scenePhaseDidChange(_ phase: ScenePhase) {
        switch phase {
        case .active:
            viewModel.appDidBecomeActive()
        case .background:
            photoLoadTask?.cancel()
            photoLoadTask = nil
            activePhotoLoadID = nil
            photoLoadGeneration &+= 1
            photosPickerItem = nil
            isPhotosPickerPresented = false
            viewModel.endPhotosPickerPresentation()
            let cleanup = viewModel.prepareForBackground()
            Task { await viewModel.finishBackgroundCleanup(cleanup) }
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    private var canOpenSettings: Bool {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            return false
        }
        return UIApplication.shared.canOpenURL(url)
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString),
              UIApplication.shared.canOpenURL(url)
        else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}
