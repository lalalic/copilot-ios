import Testing
import Foundation
@testable import CopilotSDK

// MARK: - AttachmentStore Tests

@Suite("AttachmentStore")
struct AttachmentStoreTests {
    
    /// Create a temporary file with content.
    private func tempFile(name: String, content: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("attach-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try? content.data(using: .utf8)?.write(to: url)
        return url
    }
    
    /// Create a temporary image-like binary file.
    private func tempBinaryFile(name: String, size: Int = 1024) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("attach-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        let data = Data(repeating: 0xFF, count: size)
        try? data.write(to: url)
        return url
    }
    
    @Test("Add file populates entry with correct metadata")
    func addFile() throws {
        let store = AttachmentStore()
        let url = tempFile(name: "readme.txt", content: "Hello, world!")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        
        store.add(url: url)
        #expect(store.entries.count == 1)
        #expect(store.entries[0].displayName == "readme.txt")
        #expect(store.entries[0].mimeType == "text/plain")
        #expect(store.entries[0].fileSize > 0)
    }
    
    @Test("Add multiple files")
    func addMultipleFiles() throws {
        let store = AttachmentStore()
        let url1 = tempFile(name: "a.txt", content: "AAA")
        let url2 = tempFile(name: "b.txt", content: "BBB")
        defer {
            try? FileManager.default.removeItem(at: url1.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: url2.deletingLastPathComponent())
        }
        
        store.add(url: url1)
        store.add(url: url2)
        #expect(store.entries.count == 2)
    }
    
    @Test("Remove file at index")
    func removeFile() throws {
        let store = AttachmentStore()
        let url1 = tempFile(name: "a.txt", content: "AAA")
        let url2 = tempFile(name: "b.txt", content: "BBB")
        defer {
            try? FileManager.default.removeItem(at: url1.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: url2.deletingLastPathComponent())
        }
        
        store.add(url: url1)
        store.add(url: url2)
        store.remove(at: 0)
        #expect(store.entries.count == 1)
        #expect(store.entries[0].displayName == "b.txt")
    }
    
    @Test("Clear removes all entries")
    func clearEntries() throws {
        let store = AttachmentStore()
        let url = tempFile(name: "a.txt", content: "AAA")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        
        store.add(url: url)
        store.add(url: url)
        store.clear()
        #expect(store.entries.isEmpty)
    }
    
    @Test("Prompt description format is correct")
    func promptDescription() throws {
        let store = AttachmentStore()
        let url1 = tempFile(name: "notes.txt", content: "Hello world contents")
        let url2 = tempBinaryFile(name: "photo.jpg", size: 2048)
        defer {
            try? FileManager.default.removeItem(at: url1.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: url2.deletingLastPathComponent())
        }
        
        store.add(url: url1)
        store.add(url: url2)
        
        let desc = store.promptDescription()
        #expect(desc != nil)
        #expect(desc!.contains("notes.txt"))
        #expect(desc!.contains("photo.jpg"))
        #expect(desc!.contains("get_attachment"))
        #expect(desc!.contains("1."))
        #expect(desc!.contains("2."))
    }
    
    @Test("Prompt description is nil when empty")
    func promptDescriptionEmpty() {
        let store = AttachmentStore()
        #expect(store.promptDescription() == nil)
    }
    
    @Test("Load text data by name")
    func loadTextData() throws {
        let store = AttachmentStore()
        let url = tempFile(name: "readme.txt", content: "Hello, world!")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        
        store.add(url: url)
        let (data, mimeType) = try store.loadData(name: "readme.txt")
        #expect(mimeType == "text/plain")
        #expect(String(data: data, encoding: .utf8) == "Hello, world!")
    }
    
    @Test("Load binary data by name")
    func loadBinaryData() throws {
        let store = AttachmentStore()
        let url = tempBinaryFile(name: "image.png", size: 512)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        
        store.add(url: url)
        let (data, mimeType) = try store.loadData(name: "image.png")
        #expect(mimeType == "image/png")
        #expect(data.count == 512)
    }
    
    @Test("Load data throws for unknown name")
    func loadDataNotFound() throws {
        let store = AttachmentStore()
        #expect(throws: AttachmentError.self) {
            _ = try store.loadData(name: "nonexistent.txt")
        }
    }
    
    @Test("MIME type detection for common extensions")
    func mimeTypeDetection() {
        #expect(AttachmentStore.mimeType(for: "jpg") == "image/jpeg")
        #expect(AttachmentStore.mimeType(for: "jpeg") == "image/jpeg")
        #expect(AttachmentStore.mimeType(for: "png") == "image/png")
        #expect(AttachmentStore.mimeType(for: "gif") == "image/gif")
        #expect(AttachmentStore.mimeType(for: "pdf") == "application/pdf")
        #expect(AttachmentStore.mimeType(for: "txt") == "text/plain")
        #expect(AttachmentStore.mimeType(for: "md") == "text/markdown")
        #expect(AttachmentStore.mimeType(for: "swift") == "text/x-swift")
        #expect(AttachmentStore.mimeType(for: "mp4") == "video/mp4")
        #expect(AttachmentStore.mimeType(for: "xyz") == "application/octet-stream")
    }
    
    @Test("Deduplicate same-name files")
    func deduplicateNames() throws {
        let store = AttachmentStore()
        let url1 = tempFile(name: "notes.txt", content: "First")
        let url2 = tempFile(name: "notes.txt", content: "Second")
        defer {
            try? FileManager.default.removeItem(at: url1.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: url2.deletingLastPathComponent())
        }
        
        store.add(url: url1)
        store.add(url: url2)
        
        // Should deduplicate with suffix
        let names = store.entries.map(\.displayName)
        #expect(names.count == 2)
        #expect(names[0] != names[1])
        #expect(names.contains("notes.txt"))
        #expect(names.contains("notes-2.txt"))
    }
}
