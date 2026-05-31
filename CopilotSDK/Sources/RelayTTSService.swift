import Foundation
import os.log

private let log = Logger(subsystem: "com.copilot-ios", category: "RelayTTS")

/// Client for the relay's Ali TTS proxy (cosyvoice-v2).
///
/// Relay endpoints:
///   - `POST /voice/clone`      – clone a voice from a reference audio URL
///   - `POST /voice/synthesize`  – synthesize text to audio bytes (mp3/wav)
///   - `GET  /voice/list`        – list cloned voices
///   - `DELETE /voice/{id}`      – delete a cloned voice
///   - `POST /cdn/upload`        – upload audio to CDN (for clone reference)
///
/// Auth: bearer token from CredentialStore (provider: .relay).
/// All Ali credentials and the WebSocket synthesis dance live server-side.
public final class RelayTTSService: @unchecked Sendable {

    public let relayBaseURL: URL
    private let credentialStore: CredentialStore

    public init(
        relayBaseURL: URL = URL(string: "https://relay.ai.qili2.com")!,
        credentialStore: CredentialStore = CredentialStore()
    ) {
        self.relayBaseURL = relayBaseURL
        self.credentialStore = credentialStore
    }

    // MARK: - Voice Clone

    /// Clone a voice from a public audio URL. Returns the Ali voice_id.
    /// The relay caches by prefix, so repeated calls with the same clone are cheap.
    public func cloneVoice(audioURL: String, prefix: String) async throws -> String {
        var req = makeRequest(path: "voice/clone")
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "url": audioURL,
            "prefix": prefix,
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        try ensureOK(resp, body: data, label: "/voice/clone")
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let voiceId = obj["voice_id"] as? String else {
            throw RelayTTSError.missingField("/voice/clone", "voice_id")
        }
        return voiceId
    }

    /// Resolve the Ali voice_id for a VoiceClone, cloning if needed.
    /// Updates `aliVoiceId` on the clone in-place.
    public func resolveVoiceId(for clone: inout VoiceClone) async throws -> String {
        if let cached = clone.aliVoiceId { return cached }
        let prefix = "intento\(String(clone.id.prefix(6)))"
        let voiceId = try await cloneVoice(audioURL: clone.sampleURL, prefix: prefix)
        clone.aliVoiceId = voiceId
        return voiceId
    }

    // MARK: - Synthesis

    /// Synthesize text to audio bytes. Returns raw audio data (mp3 or wav).
    public func synthesize(text: String, voiceId: String, format: String = "mp3") async throws -> Data {
        var req = makeRequest(path: "voice/synthesize")
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text,
            "voice_id": voiceId,
            "format": format,
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        try ensureOK(resp, body: data, label: "/voice/synthesize")
        return data
    }

    /// Synthesize text using a VoiceClone, resolving its voice_id first if needed.
    /// Writes audio to `outputDir` and returns the file URL.
    public func synthesize(text: String, clone: inout VoiceClone, outputDir: URL,
                           format: String = "mp3") async throws -> URL {
        let voiceId = try await resolveVoiceId(for: &clone)
        let data = try await synthesize(text: text, voiceId: voiceId, format: format)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let outURL = outputDir.appendingPathComponent("relay-tts-\(UUID().uuidString.prefix(8)).\(format)")
        try data.write(to: outURL, options: .atomic)
        return outURL
    }

    // MARK: - Voice Management

    /// List cloned voices, optionally filtering by prefix.
    public func listVoices(prefix: String? = nil) async throws -> [[String: Any]] {
        var comps = URLComponents(url: relayBaseURL.appendingPathComponent("voice/list"),
                                  resolvingAgainstBaseURL: false)!
        if let prefix {
            comps.queryItems = [URLQueryItem(name: "prefix", value: prefix)]
        }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        addAuth(to: &req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try ensureOK(resp, body: data, label: "/voice/list")
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let voices = obj["voices"] as? [[String: Any]] else {
            return []
        }
        return voices
    }

    /// Delete a cloned voice by its Ali voice_id.
    public func deleteVoice(voiceId: String) async throws {
        var req = makeRequest(path: "voice/\(voiceId)")
        req.httpMethod = "DELETE"
        req.setValue(nil, forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try ensureOK(resp, body: data, label: "/voice/\(voiceId)")
    }

    // MARK: - CDN Upload

    /// Upload audio bytes to CDN via relay. Returns the public URL.
    public func uploadToCDN(data: Data, filename: String, mimeType: String = "audio/m4a") async throws -> String {
        var comps = URLComponents(url: relayBaseURL.appendingPathComponent("cdn/upload"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "filename", value: filename)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        addAuth(to: &req)
        req.httpBody = data
        let (respData, resp) = try await URLSession.shared.data(for: req)
        try ensureOK(resp, body: respData, label: "/cdn/upload")
        guard let obj = try JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let url = obj["url"] as? String else {
            throw RelayTTSError.missingField("/cdn/upload", "url")
        }
        return url
    }

    // MARK: - Direct CDN Upload (Qiniu put-token pattern)

    public struct CDNUploadToken: Sendable {
        public let uploadToken: String
        public let key: String
        public let cdnUrl: String
        public let uploadHost: String
    }

    /// Fetch a Qiniu put token from the relay so the client can upload a
    /// single file directly to Qiniu. Body is small JSON only — no payload.
    public func requestUploadToken(filename: String, prefix: String = "neox/attachments") async throws -> CDNUploadToken {
        var comps = URLComponents(url: relayBaseURL.appendingPathComponent("cdn/token"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "filename", value: filename),
            URLQueryItem(name: "prefix", value: prefix),
        ]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        addAuth(to: &req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try ensureOK(resp, body: data, label: "/cdn/token")
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["uploadToken"] as? String,
              let key = obj["key"] as? String,
              let cdnUrl = obj["cdnUrl"] as? String,
              let host = obj["uploadHost"] as? String else {
            throw RelayTTSError.missingField("/cdn/token", "uploadToken/key/cdnUrl/uploadHost")
        }
        return CDNUploadToken(uploadToken: token, key: key, cdnUrl: cdnUrl, uploadHost: host)
    }

    /// Upload a local file directly to Qiniu via a put-token, streaming from
    /// disk (never holds the whole file in memory). Returns the CDN URL.
    ///
    /// - Parameters:
    ///   - fileURL: local file URL to upload.
    ///   - filename: original filename (used by relay to pick the extension).
    ///   - mimeType: content-type embedded in the multipart part.
    ///   - prefix: Qiniu key prefix (default `neox/attachments`).
    ///   - progress: optional callback `(sent, total)` invoked on a background queue.
    public func uploadFileDirect(
        fileURL: URL,
        filename: String,
        mimeType: String = "application/octet-stream",
        prefix: String = "neox/attachments",
        progress: ((Int64, Int64) -> Void)? = nil
    ) async throws -> String {
        let token = try await requestUploadToken(filename: filename, prefix: prefix)

        // Compose a multipart body to a temp file so the upload stays streaming.
        let boundary = "----neox-" + UUID().uuidString
        let tmpDir = FileManager.default.temporaryDirectory
        let bodyURL = tmpDir.appendingPathComponent("cdnup-\(UUID().uuidString).multipart")
        try? FileManager.default.removeItem(at: bodyURL)

        let crlf = "\r\n"
        func part(_ name: String, value: String) -> Data {
            var d = Data()
            d.append("--\(boundary)\(crlf)".data(using: .utf8)!)
            d.append("Content-Disposition: form-data; name=\"\(name)\"\(crlf)\(crlf)".data(using: .utf8)!)
            d.append("\(value)\(crlf)".data(using: .utf8)!)
            return d
        }

        guard let out = OutputStream(url: bodyURL, append: false) else {
            throw RelayTTSError.missingField("/cdn-direct", "tmp output stream")
        }
        out.open()
        defer { out.close() }

        func writeData(_ d: Data) throws {
            try d.withUnsafeBytes { rawBuf in
                guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                var remaining = d.count
                var offset = 0
                while remaining > 0 {
                    let written = out.write(base.advanced(by: offset), maxLength: remaining)
                    if written < 0 { throw out.streamError ?? RelayTTSError.missingField("/cdn-direct", "write") }
                    if written == 0 { break }
                    offset += written
                    remaining -= written
                }
            }
        }

        // Form fields
        try writeData(part("token", value: token.uploadToken))
        try writeData(part("key", value: token.key))

        // File header
        var fileHeader = Data()
        fileHeader.append("--\(boundary)\(crlf)".data(using: .utf8)!)
        fileHeader.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\(crlf)".data(using: .utf8)!)
        fileHeader.append("Content-Type: \(mimeType)\(crlf)\(crlf)".data(using: .utf8)!)
        try writeData(fileHeader)

        // File bytes — stream from source file in 64KB chunks
        guard let inFile = InputStream(url: fileURL) else {
            throw RelayTTSError.missingField("/cdn-direct", "source file")
        }
        inFile.open()
        let bufSize = 64 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate(); inFile.close() }
        while inFile.hasBytesAvailable {
            let n = inFile.read(buf, maxLength: bufSize)
            if n <= 0 { break }
            var written = 0
            while written < n {
                let w = out.write(buf.advanced(by: written), maxLength: n - written)
                if w <= 0 { throw out.streamError ?? RelayTTSError.missingField("/cdn-direct", "write-file") }
                written += w
            }
        }

        // File trailer + closing boundary
        try writeData("\(crlf)--\(boundary)--\(crlf)".data(using: .utf8)!)

        // POST to Qiniu upload host
        guard let hostURL = URL(string: token.uploadHost) else {
            throw RelayTTSError.missingField("/cdn-direct", "uploadHost URL")
        }
        var req = URLRequest(url: hostURL)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 600  // big videos may take a while on slow networks

        let session: URLSession
        let delegate: CDNUploadDelegate?
        if let progress {
            let d = CDNUploadDelegate(progress: progress)
            delegate = d
            session = URLSession(configuration: .default, delegate: d, delegateQueue: nil)
        } else {
            delegate = nil
            session = URLSession.shared
        }
        defer {
            if delegate != nil { session.finishTasksAndInvalidate() }
            try? FileManager.default.removeItem(at: bodyURL)
        }

        let (data, resp) = try await session.upload(for: req, fromFile: bodyURL)
        try ensureOK(resp, body: data, label: "qiniu-upload")
        // Success — Qiniu echoes the key but we already know the CDN URL.
        return token.cdnUrl
    }

    // MARK: - Helpers

    private func makeRequest(path: String) -> URLRequest {
        var req = URLRequest(url: relayBaseURL.appendingPathComponent(path))
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addAuth(to: &req)
        return req
    }

    private func addAuth(to req: inout URLRequest) {
        if let token = credentialStore.getAPIKey(for: .relay) {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    private func ensureOK(_ resp: URLResponse, body: Data, label: String) throws {
        guard let http = resp as? HTTPURLResponse else {
            throw RelayTTSError.noHTTPResponse(label)
        }
        if !(200..<300).contains(http.statusCode) {
            let txt = String(data: body, encoding: .utf8) ?? ""
            log.error("\(label) HTTP \(http.statusCode): \(txt)")
            throw RelayTTSError.httpError(label, http.statusCode, txt)
        }
    }
}

// MARK: - Errors

public enum RelayTTSError: LocalizedError {
    case noHTTPResponse(String)
    case httpError(String, Int, String)
    case missingField(String, String)

    public var errorDescription: String? {
        switch self {
        case .noHTTPResponse(let label):
            return "\(label): no HTTP response"
        case .httpError(let label, let code, let body):
            return "\(label) HTTP \(code): \(body)"
        case .missingField(let label, let field):
            return "\(label): missing \(field) in response"
        }
    }
}

private final class CDNUploadDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let progress: (Int64, Int64) -> Void
    init(progress: @escaping (Int64, Int64) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progress(totalBytesSent, totalBytesExpectedToSend)
    }
}
