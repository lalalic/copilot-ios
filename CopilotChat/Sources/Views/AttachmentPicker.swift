import SwiftUI
#if canImport(UIKit)
import PhotosUI
import UniformTypeIdentifiers
#endif

// MARK: - Attachment Picker

/// File/photo picker that supports both document picking and photo library.
/// Supports multi-select for both photos and files.
public struct AttachmentPicker: View {

    private let onSelect: (URL) -> Void
    private let onDismiss: () -> Void
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false

    public init(onSelect: @escaping (URL) -> Void, onDismiss: @escaping () -> Void = {}) {
        self.onSelect = onSelect
        self.onDismiss = onDismiss
    }

    public var body: some View {
        NavigationView {
            List {
                Button {
                    showPhotoPicker = true
                } label: {
                    Label("Photo Library", systemImage: "photo.on.rectangle")
                }

                Button {
                    showFilePicker = true
                } label: {
                    Label("Files", systemImage: "folder")
                }
            }
            .navigationTitle("Attach")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }
                }
            }
            #endif
        }
        #if canImport(UIKit)
        .sheet(isPresented: $showPhotoPicker) {
            PhotoPickerView(onSelect: onSelect)
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                for url in urls {
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
                    try? FileManager.default.removeItem(at: temp)
                    try? FileManager.default.copyItem(at: url, to: temp)
                    onSelect(temp)
                }
            case .failure:
                break
            }
        }
        #endif
    }
}

// MARK: - Photo Picker (iOS)

#if canImport(UIKit)
private struct PhotoPickerView: UIViewControllerRepresentable {
    let onSelect: (URL) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.selectionLimit = 10
        config.filter = .any(of: [.images, .videos])
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> PhotoCoordinator {
        PhotoCoordinator(onSelect: onSelect)
    }

    class PhotoCoordinator: NSObject, PHPickerViewControllerDelegate {
        let onSelect: (URL) -> Void

        init(onSelect: @escaping (URL) -> Void) {
            self.onSelect = onSelect
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            
            for result in results {
                let provider = result.itemProvider
                
                // Try image first, then video
                let types = ["public.image", "public.movie"]
                for type in types {
                    if provider.hasRepresentationConforming(toTypeIdentifier: type) {
                        provider.loadFileRepresentation(forTypeIdentifier: type) { [weak self] url, _ in
                            if let url {
                                let temp = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
                                try? FileManager.default.removeItem(at: temp)
                                try? FileManager.default.copyItem(at: url, to: temp)
                                self?.onSelect(temp)
                            }
                        }
                        break
                    }
                }
            }
        }
    }
}

#endif
