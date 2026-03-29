import Testing
@testable import MediaKit

@Suite struct MediaKitTests {
    @Test func providerCreation() {
        let provider = FFmpegToolProvider()
        #expect(provider.tools.count == 2)
        #expect(provider.tools[0].name == "ffmpeg")
        #expect(provider.tools[1].name == "ffprobe")
    }
}
