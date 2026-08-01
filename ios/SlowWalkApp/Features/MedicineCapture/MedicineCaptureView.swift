@preconcurrency import AVFoundation
import PhotosUI
import SlowWalkClientCore
import SwiftUI

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
        Group {
            switch viewModel.state {
            case .idle:
                statusOverlay(icon: "camera.fill",
                              text: "Tap to capture a medicine label")
            case .requestingPermission:
                statusOverlay(icon: nil,
                              text: "Requesting camera access\u{2026}")
            case .permissionDenied:
                statusOverlay(icon: "camera.slash.fill",
                              text: "Camera access denied")
            case .ready:           EmptyView()
            case .capturing:
                statusOverlay(icon: nil, text: "Capturing\u{2026}")
            case .recognizing:
                statusOverlay(icon: nil, text: "Recognizing text\u{2026}")
            case .success(let observations):
                successPanel(observations)
            case .noTextFound:
                statusOverlay(icon: "text.magnifyingglass",
                              text: "No text found. Try again.")
            case .recognitionFailed:
                statusOverlay(icon: "exclamationmark.triangle.fill",
                              text: "Recognition failed")
            case .cancelled:
                statusOverlay(icon: "xmark.circle.fill", text: "Cancelled")
            case .cameraUnavailable:
                statusOverlay(icon: "camera.fill",
                              text: "Camera unavailable")
            }
        }
    }

    @ViewBuilder private var controlsView: some View {
        VStack {
            Spacer()
            HStack(spacing: 24) {
                switch viewModel.state {
                case .ready, .idle:
                    captureButton; photosPickerButton
                case .capturing, .recognizing:
                    cancelButton
                case .success, .noTextFound,
                     .recognitionFailed, .cancelled:
                    retryButton
                default: EmptyView()
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
    }

    private var cancelButton: some View {
        Button(action: cancelCurrentOperation) {
            Text("Cancel").fontWeight(.semibold).foregroundColor(.white)
                .padding(.horizontal, 32).padding(.vertical, 14)
                .background(Color.white.opacity(0.15)).clipShape(Capsule())
        }
    }

    private var retryButton: some View {
        Button(action: { viewModel.reset() }) {
            Label("Retake", systemImage: "arrow.counterclockwise")
                .fontWeight(.semibold).foregroundColor(.white)
                .padding(.horizontal, 32).padding(.vertical, 14)
                .background(Color.white.opacity(0.15)).clipShape(Capsule())
        }
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
            Text("Recognized Text").font(.headline).foregroundColor(.white)
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
