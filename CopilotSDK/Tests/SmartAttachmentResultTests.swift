import Testing
import Foundation
@testable import CopilotSDK

// MARK: - SmartAttachmentResult Tests

@Suite("SmartAttachmentResult")
struct SmartAttachmentResultTests {
    
    // MARK: - Text Case
    
    @Test("text case modelDescription returns content directly")
    func textModelDescription() {
        let result = SmartAttachmentResult.text("Hello, world!")
        #expect(result.modelDescription == "Hello, world!")
    }
    
    @Test("text case handles empty content")
    func textEmptyContent() {
        let result = SmartAttachmentResult.text("")
        #expect(result.modelDescription == "")
    }
    
    @Test("text case handles multiline content")
    func textMultilineContent() {
        let result = SmartAttachmentResult.text("Line 1\nLine 2\nLine 3")
        #expect(result.modelDescription.contains("Line 1"))
        #expect(result.modelDescription.contains("Line 2"))
        #expect(result.modelDescription.contains("Line 3"))
    }
    
    // MARK: - Image Case
    
    @Test("image case includes dimensions")
    func imageIncludesDimensions() {
        let data = Data("test".utf8)
        let result = SmartAttachmentResult.image(data, mimeType: "image/jpeg", width: 800, height: 600)
        let desc = result.modelDescription
        
        #expect(desc.contains("800×600"))
        #expect(desc.contains("image"))
    }
    
    @Test("image case includes base64 data")
    func imageIncludesBase64() {
        let data = Data("test".utf8)
        let result = SmartAttachmentResult.image(data, mimeType: "image/png", width: 100, height: 100)
        let desc = result.modelDescription
        
        #expect(desc.contains("base64,"))
        #expect(desc.contains("image/png"))
    }
    
    @Test("image case includes data URL format")
    func imageDataUrlFormat() {
        let data = Data("x".utf8)
        let result = SmartAttachmentResult.image(data, mimeType: "image/jpeg", width: 50, height: 50)
        let desc = result.modelDescription
        
        #expect(desc.contains("data:image/jpeg;base64,"))
    }
    
    // MARK: - PDF Text Case
    
    @Test("pdfText case includes page count")
    func pdfTextIncludesPageCount() {
        let result = SmartAttachmentResult.pdfText("Document content here", pageCount: 10)
        let desc = result.modelDescription
        
        #expect(desc.contains("10 pages"))
        #expect(desc.contains("PDF"))
    }
    
    @Test("pdfText case includes text content")
    func pdfTextIncludesContent() {
        let result = SmartAttachmentResult.pdfText("Important document text", pageCount: 1)
        let desc = result.modelDescription
        
        #expect(desc.contains("Important document text"))
    }
    
    @Test("pdfText case format")
    func pdfTextFormat() {
        let result = SmartAttachmentResult.pdfText("Content", pageCount: 5)
        let desc = result.modelDescription
        
        #expect(desc.hasPrefix("[PDF, 5 pages]"))
    }
    
    // MARK: - Video Metadata Case
    
    @Test("videoMetadata includes resolution")
    func videoMetadataResolution() {
        let result = SmartAttachmentResult.videoMetadata(
            duration: 30.0, width: 1920, height: 1080, hasAudio: true, thumbnail: nil
        )
        let desc = result.modelDescription
        
        #expect(desc.contains("1920×1080"))
    }
    
    @Test("videoMetadata includes duration")
    func videoMetadataDuration() {
        let result = SmartAttachmentResult.videoMetadata(
            duration: 65.5, width: 640, height: 480, hasAudio: false, thumbnail: nil
        )
        let desc = result.modelDescription
        
        #expect(desc.contains("65.5s"))
    }
    
    @Test("videoMetadata indicates audio presence")
    func videoMetadataAudio() {
        let withAudio = SmartAttachmentResult.videoMetadata(
            duration: 10.0, width: 640, height: 480, hasAudio: true, thumbnail: nil
        )
        let withoutAudio = SmartAttachmentResult.videoMetadata(
            duration: 10.0, width: 640, height: 480, hasAudio: false, thumbnail: nil
        )
        
        #expect(withAudio.modelDescription.contains("has audio"))
        #expect(!withoutAudio.modelDescription.contains("has audio"))
    }
    
    @Test("videoMetadata includes thumbnail when present")
    func videoMetadataWithThumbnail() {
        let thumbnailData = Data("thumb".utf8)
        let result = SmartAttachmentResult.videoMetadata(
            duration: 10.0, width: 640, height: 480, hasAudio: false, thumbnail: thumbnailData
        )
        let desc = result.modelDescription
        
        #expect(desc.contains("Thumbnail:"))
        #expect(desc.contains("image/jpeg;base64,"))
    }
    
    @Test("videoMetadata without thumbnail has no thumbnail line")
    func videoMetadataNoThumbnail() {
        let result = SmartAttachmentResult.videoMetadata(
            duration: 10.0, width: 640, height: 480, hasAudio: false, thumbnail: nil
        )
        let desc = result.modelDescription
        
        #expect(!desc.contains("Thumbnail:"))
    }
    
    // MARK: - Binary Case
    
    @Test("binary case includes mimeType")
    func binaryIncludesMimeType() {
        let data = Data([0x00, 0x01, 0x02])
        let result = SmartAttachmentResult.binary(data, mimeType: "application/octet-stream")
        let desc = result.modelDescription
        
        #expect(desc.contains("application/octet-stream"))
    }
    
    @Test("binary case includes base64 data")
    func binaryIncludesBase64() {
        let data = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let result = SmartAttachmentResult.binary(data, mimeType: "application/zip")
        let desc = result.modelDescription
        
        #expect(desc.contains("base64:"))
        // The base64 of [0xDE, 0xAD, 0xBE, 0xEF] is "3q2+7w=="
        let base64 = data.base64EncodedString()
        #expect(desc.contains(base64))
    }
    
    @Test("binary case empty data")
    func binaryEmptyData() {
        let result = SmartAttachmentResult.binary(Data(), mimeType: "application/x-empty")
        let desc = result.modelDescription
        
        #expect(desc.contains("application/x-empty"))
        // Empty data base64 is empty
        #expect(desc.contains("base64:"))
    }
    
    // MARK: - Sendable Conformance
    
    @Test("SmartAttachmentResult is Sendable")
    func sendableConformance() async {
        let result = SmartAttachmentResult.text("test")
        
        // Send across task boundaries
        let description = await Task.detached {
            result.modelDescription
        }.value
        
        #expect(description == "test")
    }
}
