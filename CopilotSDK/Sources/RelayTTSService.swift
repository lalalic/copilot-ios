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
    /// Delegates to `RelayCDNUploader.uploadData`.
    public func uploadToCDN(data: Data, filename: String, mimeType: String = "audio/m4a") async throws -> String {
        let cdn = RelayCDNUploader(relayBaseURL: relayBaseURL, credentialStore: credentialStore)
        return try await cdn.uploadData(data, filename: filename, mimeType: mimeType)
    }

    // MARK: - Direct CDN Upload (delegated to RelayCDNUploader)

    /// Upload a local file directly to Qiniu via a put-token, streaming from
    /// disk (never holds the whole file in memory). Returns the CDN URL.
    /// Delegates to `RelayCDNUploader.upload`.
    public func uploadFileDirect(
        fileURL: URL,
        filename: String,
        mimeType: String = "application/octet-stream",
        prefix: String = "neox/attachments",
        progress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> String {
        let cdn = RelayCDNUploader(relayBaseURL: relayBaseURL, credentialStore: credentialStore)
        return try await cdn.upload(fileURL: fileURL, filename: filename, mimeType: mimeType, prefix: prefix, progress: progress)
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
