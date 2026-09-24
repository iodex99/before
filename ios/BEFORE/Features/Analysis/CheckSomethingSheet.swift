import AVFoundation
import PhotosUI
import SwiftUI
import BeforeKit

// =============================================================================
// BEFORE — the input sheet.
//
// Four ways in (spec §10): photos, camera, a link, or a screenshot arriving
// from the share extension. The user may supply both an image and a URL; when
// they do, both are sent, because the page gives facts and the image gives
// context.
// =============================================================================

enum CheckEntryPoint: Identifiable, Hashable {
    case menu
    case photos
    case camera
    case url
    case shared(SharedPayload)

    var id: String {
        switch self {
        case .menu: "menu"
        case .photos: "photos"
        case .camera: "camera"
        case .url: "url"
        case .shared(let payload): "shared-\(payload.id.uuidString)"
        }
    }
}

struct CheckSomethingSheet: View {
    let entryPoint: CheckEntryPoint
    let onReady: (AnalysisRequestDraft) -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var photoItem: PhotosPickerItem?
    @State private var processed: ProcessedImage?
    @State private var previewImage: UIImage?
    @State private var linkText = ""
    @State private var note = ""
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var showingCamera = false
    @State private var cameraDenied = false

    private var hasInput: Bool { processed != nil || validatedURL != nil }

    /// Only an http(s) URL counts. Anything else is treated as no link at all
    /// rather than sent to the server to fail.
    private var validatedURL: URL? {
        let trimmed = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil
        else { return nil }
        return url
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BeforeTheme.Spacing.xl) {
                    if let previewImage {
                        imagePreview(previewImage)
                    } else {
                        sourceButtons
                    }

                    linkField
                    noteField

                    if let errorMessage {
                        Text(errorMessage)
                            .font(BeforeTheme.Typeface.callout)
                            .foregroundStyle(BeforeTheme.destructive)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, BeforeTheme.Spacing.l)
            }
            .beforeScreen()
            .navigationTitle("Check something")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Check") { submit() }
                        .disabled(!hasInput || isProcessing)
                        .accessibilityIdentifier("check.submit")
                }
            }
            .photosPicker(
                isPresented: photoPickerBinding,
                selection: $photoItem,
                matching: .images,
                // Native picker, so BEFORE never asks for full library access
                // (spec §11).
                photoLibrary: .shared()
            )
            .fullScreenCover(isPresented: $showingCamera) {
                CameraPicker { image in
                    Task { await process(image: image) }
                }
                .ignoresSafeArea()
            }
            .alert("Camera access is off", isPresented: $cameraDenied) {
                Button("Open Settings") { openSettings() }
                Button("Not now", role: .cancel) {}
            } message: {
                Text("Turn on camera access in Settings to photograph something in a shop.")
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task { await process(pickerItem: item) }
            }
            .task { await applyEntryPoint() }
        }
        .interactiveDismissDisabled(isProcessing)
    }

    // MARK: Sections

    private var sourceButtons: some View {
        VStack(spacing: BeforeTheme.Spacing.m) {
            SourceButton(title: "Choose from Photos", systemImage: "photo.on.rectangle") {
                photoPickerPresented = true
            }
            SourceButton(title: "Take Photo", systemImage: "camera") {
                requestCamera()
            }
        }
    }

    @State private var photoPickerPresented = false
    private var photoPickerBinding: Binding<Bool> {
        Binding(get: { photoPickerPresented }, set: { photoPickerPresented = $0 })
    }

    private func imagePreview(_ image: UIImage) -> some View {
        VStack(alignment: .leading, spacing: BeforeTheme.Spacing.s) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 280)
                .clipShape(RoundedRectangle(cornerRadius: BeforeTheme.Radius.card, style: .continuous))
                .accessibilityLabel("Selected photo")

            HStack {
                if let processed {
                    Text("\(Int(processed.pixelSize.width))×\(Int(processed.pixelSize.height)) · \(processed.byteCount / 1024) KB")
                        .font(BeforeTheme.Typeface.caption)
                        .foregroundStyle(BeforeTheme.tertiaryText)
                }
                Spacer()
                BeforeTextButton("Replace") {
                    self.processed = nil
                    self.previewImage = nil
                    self.photoItem = nil
                }
            }
        }
    }

    private var linkField: some View {
        VStack(alignment: .leading, spacing: BeforeTheme.Spacing.s) {
            SectionHeader("Product link", accessory: "Optional")
            TextField("Paste a link", text: $linkText)
                .textFieldStyle(.plain)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(BeforeTheme.Spacing.l)
                .background(
                    RoundedRectangle(cornerRadius: BeforeTheme.Radius.control, style: .continuous)
                        .fill(BeforeTheme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: BeforeTheme.Radius.control, style: .continuous)
                        .stroke(BeforeTheme.divider, lineWidth: 1)
                )
                .accessibilityIdentifier("check.linkField")

            if !linkText.isEmpty && validatedURL == nil {
                Text("That doesn't look like a web address.")
                    .font(BeforeTheme.Typeface.caption)
                    .foregroundStyle(BeforeTheme.warning)
            }
        }
    }

    private var noteField: some View {
        VStack(alignment: .leading, spacing: BeforeTheme.Spacing.s) {
            SectionHeader("Anything BEFORE should know?", accessory: "Optional")
            TextField("For a wedding in June…", text: $note, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...4)
                .padding(BeforeTheme.Spacing.l)
                .background(
                    RoundedRectangle(cornerRadius: BeforeTheme.Radius.control, style: .continuous)
                        .fill(BeforeTheme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: BeforeTheme.Radius.control, style: .continuous)
                        .stroke(BeforeTheme.divider, lineWidth: 1)
                )
        }
    }

    // MARK: Actions

    private func applyEntryPoint() async {
        switch entryPoint {
        case .menu:
            break
        case .photos:
            photoPickerPresented = true
        case .camera:
            requestCamera()
        case .url:
            break
        case .shared(let payload):
            await apply(payload)
        }
    }

    private func apply(_ payload: SharedPayload) async {
        if let urlString = payload.urlString { linkText = urlString }
        if payload.kind == .image, let data = environment.sharedInbox.imageData(for: payload) {
            await process(data: data)
        }
    }

    private func requestCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showingCamera = true
        case .notDetermined:
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                if granted { showingCamera = true } else { cameraDenied = true }
            }
        default:
            cameraDenied = true
        }
    }

    private func process(pickerItem: PhotosPickerItem) async {
        isProcessing = true
        defer { isProcessing = false }
        do {
            guard let data = try await pickerItem.loadTransferable(type: Data.self) else {
                errorMessage = ImageProcessingError.unreadable.errorDescription
                return
            }
            await process(data: data)
        } catch {
            errorMessage = ImageProcessingError.unreadable.errorDescription
        }
    }

    private func process(data: Data) async {
        isProcessing = true
        defer { isProcessing = false }
        do {
            let result = try await ImageProcessor.process(data: data)
            processed = result
            // Downsample again for display: the preview does not need the
            // upload-resolution bitmap in memory (spec §82).
            previewImage = ImageProcessor.thumbnail(from: result.data, maxPixelSize: 900)
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "That image couldn't be read. Try another photo."
        }
    }

    private func process(image: UIImage) async {
        isProcessing = true
        defer { isProcessing = false }
        do {
            let result = try await ImageProcessor.process(image)
            processed = result
            previewImage = ImageProcessor.thumbnail(from: result.data, maxPixelSize: 900)
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "That image couldn't be read. Try another photo."
        }
    }

    private func submit() {
        let inputType: InputType = {
            if case .shared = entryPoint { return .shareExtension }
            if processed != nil { return entryPoint == .camera ? .camera : .photo }
            return .url
        }()

        let draft = AnalysisRequestDraft(
            imageData: processed?.data,
            productUrl: validatedURL?.absoluteString,
            userNote: note.isEmpty ? nil : note,
            inputType: inputType
        )

        if case .shared(let payload) = entryPoint {
            environment.consumeSharedPayload(payload)
        }

        onReady(draft)
    }

    private func cancel() {
        if case .shared(let payload) = entryPoint {
            // The user declined this one; do not re-present it every launch.
            environment.consumeSharedPayload(payload)
        }
        dismiss()
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Pieces

struct SourceButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: BeforeTheme.Spacing.m) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(BeforeTheme.accent)
                    .frame(width: 28)
                Text(title)
                    .font(BeforeTheme.Typeface.body)
                    .foregroundStyle(BeforeTheme.primaryText)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(BeforeTheme.tertiaryText)
            }
            .padding(BeforeTheme.Spacing.l)
            .frame(minHeight: BeforeTheme.Sizing.minimumTouchTarget)
            .background(
                RoundedRectangle(cornerRadius: BeforeTheme.Radius.control, style: .continuous)
                    .fill(BeforeTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: BeforeTheme.Radius.control, style: .continuous)
                    .stroke(BeforeTheme.divider, lineWidth: BeforeTheme.Sizing.hairline)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Apple's own camera UI. Spec §12: no custom camera where the system one does
/// the job.
struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, dismiss: { dismiss() })
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onCapture: (UIImage) -> Void
        private let dismiss: () -> Void

        init(onCapture: @escaping (UIImage) -> Void, dismiss: @escaping () -> Void) {
            self.onCapture = onCapture
            self.dismiss = dismiss
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage { onCapture(image) }
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }
    }
}

#Preview("Check something") {
    CheckSomethingSheet(entryPoint: .menu) { _ in }
        .environment(AppEnvironment.preview)
}
