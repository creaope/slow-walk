@preconcurrency import AVFoundation
import PhotosUI
import SlowWalkClientCore
import SwiftUI
import UIKit
import VisionKit

nonisolated enum MedicineCaptureCopy {
    static let assessmentStartFailed = "无法开始用药检查，请重试。"
    static let medicineCompanionTitle = "用药陪伴"
    static let capturePrompt = "选择药品图片"
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
        "此设备不支持系统扫描器。可以改从相册选择药品照片。"
    static let useCamera = "拍照识别"
    static let choosePhoto = "相册导入"
    static let openSettings = "前往设置"
    static let retry = "重新尝试"
    static let cancel = "取消"
    static let retake = "重拍"
    static let close = "关闭用药检查"
    static let recognizedText = "识别到的文字"
    static let photoLoadFailed = "无法读取这张照片，请重新选择。"
    static let scannerFailed =
        "系统扫描器暂时无法完成拍摄，请重新尝试或从相册导入。"
    static let scannerReturnedNoPage =
        "没有收到扫描图片，请重新拍摄或从相册导入。"
    static let singlePageRequired =
        "一次只拍摄一个药品包装面，请保留一页后重新提交。"
    static let imageEncodingFailed =
        "无法处理这张扫描图片，请重新拍摄或从相册导入。"
    static let captureInstructions =
        "对准药品名称所在的一面，使用系统扫描器拍摄。"
    static let cameraAccessibilityHint = "打开系统扫描器拍摄药品包装。"
    static let photoAccessibilityHint = "打开系统相册选择药品照片。"

    static let allUserVisibleText = [
        assessmentStartFailed, medicineCompanionTitle, capturePrompt,
        requestingCameraPermission,
        startingCamera, cameraPermissionDenied, cameraRestricted, capturing,
        loadingPhoto, processingImage, noTextFound, recognitionFailed,
        cancelled, cameraUnavailable, useCamera, choosePhoto,
        openSettings, retry, cancel, retake, close, recognizedText,
        photoLoadFailed, scannerFailed,
        scannerReturnedNoPage, singlePageRequired, imageEncodingFailed,
        captureInstructions, cameraAccessibilityHint, photoAccessibilityHint,
    ]
}

nonisolated enum MedicineCaptureInputFailure: Error, Equatable, Sendable {
    case scannerFailed
    case permissionDenied
    case permissionRestricted
    case cameraUnavailable
    case scannerReturnedNoPage
    case multiplePages
    case imageEncodingFailed
    case photoLoadFailed

    var message: String {
        switch self {
        case .scannerFailed:
            MedicineCaptureCopy.scannerFailed
        case .permissionDenied:
            MedicineCaptureCopy.cameraPermissionDenied
        case .permissionRestricted:
            MedicineCaptureCopy.cameraRestricted
        case .cameraUnavailable:
            MedicineCaptureCopy.cameraUnavailable
        case .scannerReturnedNoPage:
            MedicineCaptureCopy.scannerReturnedNoPage
        case .multiplePages:
            MedicineCaptureCopy.singlePageRequired
        case .imageEncodingFailed:
            MedicineCaptureCopy.imageEncodingFailed
        case .photoLoadFailed:
            MedicineCaptureCopy.photoLoadFailed
        }
    }

    var systemImage: String {
        switch self {
        case .permissionDenied, .permissionRestricted, .cameraUnavailable:
            "camera.slash"
        case .multiplePages:
            "doc.on.doc"
        case .scannerReturnedNoPage:
            "doc.badge.ellipsis"
        case .scannerFailed, .imageEncodingFailed, .photoLoadFailed:
            "exclamationmark.triangle"
        }
    }

    var offersSettings: Bool { self == .permissionDenied }
}

nonisolated enum MedicineDocumentScanContract {
    static func failure(forPageCount pageCount: Int) -> MedicineCaptureInputFailure? {
        switch pageCount {
        case 1:
            nil
        case ...0:
            .scannerReturnedNoPage
        default:
            .multiplePages
        }
    }

    static func failure(
        for authorizationStatus: AVAuthorizationStatus,
        isScannerSupported: Bool
    ) -> MedicineCaptureInputFailure? {
        guard isScannerSupported else { return .cameraUnavailable }
        switch authorizationStatus {
        case .denied:
            return .permissionDenied
        case .restricted:
            return .permissionRestricted
        case .notDetermined, .authorized:
            return nil
        @unknown default:
            return .scannerFailed
        }
    }
}

nonisolated struct MedicineCaptureInputState: Equatable, Sendable {
    private(set) var failure: MedicineCaptureInputFailure?

    mutating func accept(
        _ data: Data?,
        failure failureIfInvalid: MedicineCaptureInputFailure
    ) -> Data? {
        guard let data, !data.isEmpty else {
            failure = failureIfInvalid
            return nil
        }
        failure = nil
        return data
    }

    mutating func reject(_ newFailure: MedicineCaptureInputFailure) {
        failure = newFailure
    }

    mutating func clear() { failure = nil }
}

nonisolated struct MedicineCaptureCloseGate: Equatable, Sendable {
    private(set) var hasRequestedDismissal = false

    mutating func requestDismissal() -> Bool {
        guard !hasRequestedDismissal else { return false }
        hasRequestedDismissal = true
        return true
    }
}

enum MedicineCaptureAccessibilityFocusTarget: Hashable {
    case status
    case recognizedResult
}

enum MedicineCaptureAccessibilityFocusResolver {
    static func target(
        for state: MedicineCaptureState,
        submissionStatus: MedicineAssessmentSubmissionStatus
    ) -> MedicineCaptureAccessibilityFocusTarget {
        guard submissionStatus == .none else { return .status }
        if case .success = state { return .recognizedResult }
        return .status
    }
}

private struct MedicineDocumentScanner: UIViewControllerRepresentable {
    let onComplete: @MainActor (UIImage) -> Void
    let onCancel: @MainActor () -> Void
    let onFailure: @MainActor (MedicineCaptureInputFailure) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onComplete: onComplete,
            onCancel: onCancel,
            onFailure: onFailure
        )
    }

    func makeUIViewController(
        context: Context
    ) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(
        _ uiViewController: VNDocumentCameraViewController,
        context: Context
    ) {}

    @MainActor
    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        private let onComplete: @MainActor (UIImage) -> Void
        private let onCancel: @MainActor () -> Void
        private let onFailure: @MainActor (MedicineCaptureInputFailure) -> Void

        init(
            onComplete: @escaping @MainActor (UIImage) -> Void,
            onCancel: @escaping @MainActor () -> Void,
            onFailure: @escaping @MainActor (MedicineCaptureInputFailure) -> Void
        ) {
            self.onComplete = onComplete
            self.onCancel = onCancel
            self.onFailure = onFailure
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            guard let failure = MedicineDocumentScanContract.failure(
                forPageCount: scan.pageCount
            ) else {
                let image = scan.imageOfPage(at: 0)
                controller.dismiss(animated: true)
                onComplete(image)
                return
            }
            controller.dismiss(animated: true)
            onFailure(failure)
        }

        func documentCameraViewControllerDidCancel(
            _ controller: VNDocumentCameraViewController
        ) {
            controller.dismiss(animated: true)
            onCancel()
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            controller.dismiss(animated: true)
            let failure = MedicineDocumentScanContract.failure(
                for: AVCaptureDevice.authorizationStatus(for: .video),
                isScannerSupported: VNDocumentCameraViewController.isSupported
            ) ?? .scannerFailed
            onFailure(failure)
        }
    }
}

/// Native image-source controls embedded in the existing companion detail page.
/// It acquires image bytes only; assessment ownership stays with CompanionView.
struct MedicineCaptureSourceActions: View {
    @Environment(\.scenePhase) private var scenePhase
    private let onImageSelected: @MainActor (Data) -> Void
    @State private var photosPickerItem: PhotosPickerItem?
    @State private var isPhotosPickerPresented = false
    @State private var isDocumentScannerPresented = false
    @State private var isLoadingPhoto = false
    @State private var inputState = MedicineCaptureInputState()
    @State private var photoLoadGeneration = 0
    @State private var photoLoadTask: Task<Void, Never>?

    init(onImageSelected: @escaping @MainActor (Data) -> Void) {
        self.onImageSelected = onImageSelected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: presentDocumentScanner) {
                Label(
                    MedicineCaptureCopy.useCamera,
                    systemImage: "doc.text.viewfinder"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(minHeight: SlowWalkLayout.minimumTapTarget)
            .disabled(!canScanDocuments || isLoadingPhoto)
            .accessibilityHint(MedicineCaptureCopy.cameraAccessibilityHint)

            Button(action: presentPhotosPicker) {
                Label(
                    MedicineCaptureCopy.choosePhoto,
                    systemImage: "photo.on.rectangle"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .frame(minHeight: SlowWalkLayout.minimumTapTarget)
            .disabled(isLoadingPhoto)
            .accessibilityHint(MedicineCaptureCopy.photoAccessibilityHint)

            if isLoadingPhoto {
                ProgressView(MedicineCaptureCopy.loadingPhoto)
                    .controlSize(.large)
                    .accessibilityElement(children: .combine)
            }

            if let failure = inputState.failure {
                Label(
                    failure.message,
                    systemImage: failure.systemImage
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if failure.offersSettings, canOpenSettings {
                    Button(MedicineCaptureCopy.openSettings, action: openSettings)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .frame(minHeight: SlowWalkLayout.minimumTapTarget)
                }
            }

            if !canScanDocuments {
                Label(
                    MedicineCaptureCopy.cameraUnavailable,
                    systemImage: "iphone.slash"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .photosPicker(
            isPresented: $isPhotosPickerPresented,
            selection: $photosPickerItem,
            matching: .images
        )
        .fullScreenCover(isPresented: $isDocumentScannerPresented) {
            MedicineDocumentScanner(
                onComplete: submitScannedImage,
                onCancel: { isDocumentScannerPresented = false },
                onFailure: handleScannerFailure
            )
            .ignoresSafeArea()
        }
        .onChange(of: photosPickerItem) { _, item in
            guard let item else { return }
            loadPhoto(item)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshScannerAvailability() }
        }
        .onDisappear {
            photoLoadTask?.cancel()
            photoLoadTask = nil
            photoLoadGeneration &+= 1
            photosPickerItem = nil
            isPhotosPickerPresented = false
            isLoadingPhoto = false
        }
    }

    private var canScanDocuments: Bool {
        VNDocumentCameraViewController.isSupported
    }

    private func presentDocumentScanner() {
        guard canScanDocuments else { return }
        if let failure = MedicineDocumentScanContract.failure(
            for: AVCaptureDevice.authorizationStatus(for: .video),
            isScannerSupported: canScanDocuments
        ) {
            inputState.reject(failure)
            return
        }
        inputState.clear()
        isDocumentScannerPresented = true
    }

    private func presentPhotosPicker() {
        inputState.clear()
        isPhotosPickerPresented = true
    }

    private func submitScannedImage(_ image: UIImage) {
        isDocumentScannerPresented = false
        let encodedData = image.jpegData(compressionQuality: 0.92)
            ?? image.pngData()
        guard let data = inputState.accept(
            encodedData,
            failure: .imageEncodingFailed
        ) else { return }
        onImageSelected(data)
    }

    private func handleScannerFailure(_ failure: MedicineCaptureInputFailure) {
        isDocumentScannerPresented = false
        inputState.reject(failure)
    }

    private func loadPhoto(_ item: PhotosPickerItem) {
        photoLoadTask?.cancel()
        photoLoadGeneration &+= 1
        let generation = photoLoadGeneration
        isLoadingPhoto = true
        inputState.clear()
        photosPickerItem = nil

        photoLoadTask = Task { @MainActor in
            defer {
                if generation == photoLoadGeneration {
                    isLoadingPhoto = false
                    photoLoadTask = nil
                }
            }
            do {
                let data = try await item.loadTransferable(type: Data.self)
                try Task.checkCancellation()
                guard generation == photoLoadGeneration,
                      let data = inputState.accept(
                          data,
                          failure: .photoLoadFailed
                      )
                else { return }
                onImageSelected(data)
            } catch is CancellationError {
                return
            } catch {
                guard generation == photoLoadGeneration else { return }
                inputState.reject(.photoLoadFailed)
            }
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

    private func refreshScannerAvailability() {
        guard inputState.failure == .permissionDenied
                || inputState.failure == .permissionRestricted
        else { return }
        if let failure = MedicineDocumentScanContract.failure(
            for: AVCaptureDevice.authorizationStatus(for: .video),
            isScannerSupported: canScanDocuments
        ) {
            inputState.reject(failure)
        } else {
            inputState.clear()
        }
    }
}

struct MedicineCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel: MedicineCaptureViewModel
    @State private var photosPickerItem: PhotosPickerItem?
    @State private var isPhotosPickerPresented = false
    @State private var isDocumentScannerPresented = false
    @State private var activePhotoLoadID: UUID?
    @State private var photoLoadTask: Task<Void, Never>?
    @State private var photoLoadGeneration = 0
    @State private var inputState = MedicineCaptureInputState()
    @State private var closeGate = MedicineCaptureCloseGate()
    @AccessibilityFocusState private var accessibilityFocus:
        MedicineCaptureAccessibilityFocusTarget?

    private enum StatusAction {
        case openSettings
        case retry
    }

    private let onDismissRequest: (@MainActor () -> Void)?

    init(
        viewModel: MedicineCaptureViewModel,
        onDismissRequest: (@MainActor () -> Void)? = nil
    ) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.onDismissRequest = onDismissRequest
    }

    var body: some View {
        NavigationStack {
            captureContent
                .navigationTitle(MedicineCaptureCopy.medicineCompanionTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(action: closeCapture) {
                            Label(
                                MedicineCaptureCopy.close,
                                systemImage: "xmark"
                            )
                        }
                        .labelStyle(.iconOnly)
                        .accessibilityLabel(MedicineCaptureCopy.close)
                        .accessibilityIdentifier("medicine-capture-close")
                    }
                }
        }
        .onDisappear {
            photoLoadTask?.cancel()
            photoLoadTask = nil
            activePhotoLoadID = nil
            isPhotosPickerPresented = false
            isDocumentScannerPresented = false
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
        .onChange(of: viewModel.state) { _, newState in
            moveAccessibilityFocus(for: newState)
        }
        .onChange(of: viewModel.assessmentSubmissionStatus) { _, _ in
            moveAccessibilityFocus(for: viewModel.state)
        }
        .onChange(of: inputState.failure) { _, _ in
            moveAccessibilityFocus(for: viewModel.state)
        }
        .photosPicker(
            isPresented: photosPickerPresentationBinding,
            selection: $photosPickerItem,
            matching: .images
        )
        .fullScreenCover(isPresented: $isDocumentScannerPresented) {
            MedicineDocumentScanner(
                onComplete: submitScannedImage,
                onCancel: { isDocumentScannerPresented = false },
                onFailure: handleScannerFailure
            )
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var captureContent: some View {
        if let failure = inputState.failure {
            inputFailurePage(failure)
        } else {
            switch viewModel.assessmentSubmissionStatus {
            case .submitted:
                progressPage(MedicineCaptureCopy.processingImage)
            case .failed:
                statusPage(
                    title: MedicineCaptureCopy.recognitionFailed,
                    systemImage: "exclamationmark.triangle",
                    description: MedicineCaptureCopy.assessmentStartFailed,
                    primaryAction: .retry
                )
            case .none:
                stateContent
            }
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch viewModel.state {
        case .idle:
            sourceSelectionPage
        case .requestingPermission:
            progressPage(MedicineCaptureCopy.requestingCameraPermission)
        case .permissionDenied:
            statusPage(
                title: MedicineCaptureCopy.useCamera,
                systemImage: "camera.slash",
                description: MedicineCaptureCopy.cameraPermissionDenied,
                primaryAction: canOpenSettings ? .openSettings : nil,
                offersPhotosPicker: true
            )
        case .cameraRestricted:
            statusPage(
                title: MedicineCaptureCopy.useCamera,
                systemImage: "camera.slash",
                description: MedicineCaptureCopy.cameraRestricted,
                offersPhotosPicker: true
            )
        case .startingCamera:
            progressPage(MedicineCaptureCopy.startingCamera)
        case .ready:
            sourceSelectionPage
        case .capturing:
            progressPage(MedicineCaptureCopy.capturing)
        case .loadingPhoto:
            progressPage(MedicineCaptureCopy.loadingPhoto)
        case .recognizing:
            progressPage(MedicineCaptureCopy.processingImage)
        case let .success(observations):
            recognizedTextPage(observations)
        case .noTextFound:
            statusPage(
                title: MedicineCaptureCopy.noTextFound,
                systemImage: "text.magnifyingglass",
                primaryAction: .retry
            )
        case .recognitionFailed:
            statusPage(
                title: MedicineCaptureCopy.recognitionFailed,
                systemImage: "exclamationmark.triangle",
                primaryAction: .retry
            )
        case .cancelled:
            statusPage(
                title: MedicineCaptureCopy.cancelled,
                systemImage: "xmark.circle",
                primaryAction: .retry
            )
        case .cameraUnavailable:
            statusPage(
                title: MedicineCaptureCopy.useCamera,
                systemImage: "camera.slash",
                description: MedicineCaptureCopy.cameraUnavailable,
                primaryAction: .retry,
                offersPhotosPicker: true
            )
        }
    }

    private var sourceSelectionPage: some View {
        standardList {
            Section {
                ContentUnavailableView {
                    Label(
                        MedicineCaptureCopy.capturePrompt,
                        systemImage: "doc.text.viewfinder"
                    )
                } description: {
                    Text(MedicineCaptureCopy.captureInstructions)
                }
                .accessibilityFocused(
                    $accessibilityFocus,
                    equals: .status
                )
                .slowWalkReadableContent()
            }

            Section {
                Button(action: presentDocumentScanner) {
                    Label(
                        MedicineCaptureCopy.useCamera,
                        systemImage: "doc.text.viewfinder"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(minHeight: SlowWalkLayout.minimumTapTarget)
                .disabled(!canScanDocuments)
                .accessibilityHint(MedicineCaptureCopy.cameraAccessibilityHint)
                .slowWalkReadableContent()

                photosPickerButton
                    .slowWalkReadableContent()
            }

            if !canScanDocuments {
                Section {
                    Label(
                        MedicineCaptureCopy.cameraUnavailable,
                        systemImage: "iphone.slash"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .slowWalkReadableContent()
                }
            }
        }
    }

    private var photosPickerButton: some View {
        Button(action: presentPhotosPicker) {
            Label(
                MedicineCaptureCopy.choosePhoto,
                systemImage: "photo.on.rectangle"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .frame(minHeight: SlowWalkLayout.minimumTapTarget)
        .disabled(!viewModel.canChoosePhoto)
        .accessibilityHint(MedicineCaptureCopy.photoAccessibilityHint)
    }

    private func inputFailurePage(
        _ failure: MedicineCaptureInputFailure
    ) -> some View {
        statusPage(
            title: inputFailureTitle(failure),
            systemImage: failure.systemImage,
            description: failure.message,
            primaryAction: failure.offersSettings && canOpenSettings
                ? .openSettings
                : .retry,
            offersPhotosPicker: true
        )
    }

    private func inputFailureTitle(
        _ failure: MedicineCaptureInputFailure
    ) -> String {
        switch failure {
        case .permissionDenied, .permissionRestricted, .cameraUnavailable:
            MedicineCaptureCopy.useCamera
        case .multiplePages:
            MedicineCaptureCopy.capturePrompt
        case .scannerFailed, .scannerReturnedNoPage, .imageEncodingFailed,
             .photoLoadFailed:
            MedicineCaptureCopy.recognitionFailed
        }
    }

    private func progressPage(_ text: String) -> some View {
        standardList {
            Section {
                ProgressView(text)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityFocused(
                        $accessibilityFocus,
                        equals: .status
                    )
                    .slowWalkReadableContent()
            }

            if viewModel.assessmentSubmissionStatus != .submitted {
                Section {
                    Button(role: .cancel, action: cancelCurrentOperation) {
                        Label(
                            MedicineCaptureCopy.cancel,
                            systemImage: "xmark"
                        )
                    }
                    .frame(minHeight: SlowWalkLayout.minimumTapTarget)
                    .slowWalkReadableContent()
                }
            }
        }
    }

    private func statusPage(
        title: String,
        systemImage: String,
        description: String? = nil,
        primaryAction: StatusAction? = nil,
        offersPhotosPicker: Bool = false
    ) -> some View {
        standardList {
            Section {
                ContentUnavailableView {
                    Label(title, systemImage: systemImage)
                } description: {
                    if let description {
                        Text(description)
                    }
                }
                .accessibilityFocused(
                    $accessibilityFocus,
                    equals: .status
                )
                .slowWalkReadableContent()
            }

            if primaryAction != nil || offersPhotosPicker {
                Section {
                    if let primaryAction {
                        statusActionButton(primaryAction)
                            .slowWalkReadableContent()
                    }
                    if offersPhotosPicker {
                        photosPickerButton
                            .slowWalkReadableContent()
                    }
                }
            }
        }
    }

    private func statusActionButton(_ action: StatusAction) -> some View {
        Button {
            switch action {
            case .openSettings:
                openSettings()
            case .retry:
                inputState.clear()
                viewModel.reset()
            }
        } label: {
            switch action {
            case .openSettings:
                Label(
                    MedicineCaptureCopy.openSettings,
                    systemImage: "gear"
                )
            case .retry:
                Label(
                    MedicineCaptureCopy.retry,
                    systemImage: "arrow.clockwise"
                )
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .frame(minHeight: SlowWalkLayout.minimumTapTarget)
    }

    private func recognizedTextPage(
        _ observations: [RecognizedTextObservation]
    ) -> some View {
        standardList {
            Section {
                ForEach(Array(observations.enumerated()), id: \.offset) {
                    _, observation in
                    Text(observation.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .slowWalkReadableContent()
                }
            } header: {
                Text(MedicineCaptureCopy.recognizedText)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused(
                        $accessibilityFocus,
                        equals: .recognizedResult
                    )
            }

            Section {
                Button {
                    viewModel.reset()
                } label: {
                    Label(
                        MedicineCaptureCopy.retake,
                        systemImage: "arrow.counterclockwise"
                    )
                }
                .frame(minHeight: SlowWalkLayout.minimumTapTarget)
                .slowWalkReadableContent()
            }
        }
    }

    private func standardList<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        List {
            content()
        }
        .listStyle(.insetGrouped)
    }

    private var canScanDocuments: Bool {
        VNDocumentCameraViewController.isSupported
    }

    private func presentDocumentScanner() {
        guard canScanDocuments else { return }
        if let failure = MedicineDocumentScanContract.failure(
            for: AVCaptureDevice.authorizationStatus(for: .video),
            isScannerSupported: canScanDocuments
        ) {
            inputState.reject(failure)
            return
        }
        inputState.clear()
        isDocumentScannerPresented = true
    }

    private func submitScannedImage(_ image: UIImage) {
        isDocumentScannerPresented = false
        let encodedData = image.jpegData(compressionQuality: 0.92)
            ?? image.pngData()
        guard let data = inputState.accept(
            encodedData,
            failure: .imageEncodingFailed
        ) else { return }
        viewModel.capture(
            imageData: data,
            orientation: .up,
            capturedAt: Date()
        )
    }

    private func handleScannerFailure(_ failure: MedicineCaptureInputFailure) {
        isDocumentScannerPresented = false
        inputState.reject(failure)
    }

    private func cancelCurrentOperation() {
        photoLoadTask?.cancel()
        photoLoadTask = nil
        activePhotoLoadID = nil
        photoLoadGeneration &+= 1
        inputState.clear()
        viewModel.cancel()
    }

    private func closeCapture() {
        guard closeGate.requestDismissal() else { return }
        cancelCurrentOperation()
        if let onDismissRequest {
            onDismissRequest()
        } else {
            dismiss()
        }
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
        inputState.clear()
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
                    viewModel.reset()
                    inputState.reject(.photoLoadFailed)
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
                viewModel.reset()
                inputState.reject(.photoLoadFailed)
            }
        }
    }

    private func scenePhaseDidChange(_ phase: ScenePhase) {
        switch phase {
        case .active:
            viewModel.appDidBecomeActive()
            refreshScannerAvailability()
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

    private func refreshScannerAvailability() {
        guard inputState.failure == .permissionDenied
                || inputState.failure == .permissionRestricted
        else { return }
        if let failure = MedicineDocumentScanContract.failure(
            for: AVCaptureDevice.authorizationStatus(for: .video),
            isScannerSupported: canScanDocuments
        ) {
            inputState.reject(failure)
        } else {
            inputState.clear()
        }
    }

    private func moveAccessibilityFocus(for state: MedicineCaptureState) {
        Task { @MainActor in
            await Task.yield()
            accessibilityFocus = MedicineCaptureAccessibilityFocusResolver.target(
                for: state,
                submissionStatus: viewModel.assessmentSubmissionStatus
            )
        }
    }
}
