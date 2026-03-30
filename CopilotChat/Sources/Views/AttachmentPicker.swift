import SwiftUI
#if canImport(UIKit)
import PhotosUI
#endif

// MARK: - Attachment Picker

/// File/photo picker that supports both document picking and photo library.
public struct AttachmentPicker: View {

    private let onSelect: (URL) -> Void
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false

    public init(onSelect: @escaping (URL) -> Void) {
        self.onSelect = onSelect
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
            #endif
        }
        #if canImport(UIKit)
        .sheet(isPresented: $showPhotoPicker) {
            PhotoPickerView(onSelect: onSelect)
        }
        .sheet(isPresented: $showFilePicker) {
            DocumentPickerView(onSelect: onSelect)
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
        config.selectionLimit = 1
        config.filter = .images
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
            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else { return }

            provider.loadFileRepresentation(forTypeIdentifier: "public.image") { [weak self] url, _ in
                if let url {
                    // Copy to temp location since the provided URL is temporary
                    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
                    try? FileManager.default.copyItem(at: url, to: temp)
                    self?.onSelect(temp)
                }
            }
        }
    }
}

// MARK: - Document Picker (iOS)

private struct DocumentPickerView: UIViewControllerRepresentable {
    let onSelect: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> DocumentCoordinator {
        DocumentCoordinator(onSelect: onSelect)
    }

    class DocumentCoordinator: NSObject, UIDocumentPickerDelegate {
        let onSelect: (URL) -> Void

        init(onSelect: @escaping (URL) -> Void) {
            self.onSelect = onSelect
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first {
                onSelect(url)
            }
        }
    }
}
#endif
