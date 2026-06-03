import Foundation
import os.log

private let log = Logger(subsystem: "com.copilot-ios", category: "RelayCDN")

/// Standalone CDN uploader that talks directly to Qiniu via relay-issued
/// put-tokens. Extracted from `RelayTTSService` so it can be reused by
/// any code that needs to push a file to CDN without pulling in the TTS
/// stack.
///
/// Supports two upload strategies:
/// - **Direct** (multipart form POST) — for files < 30 MB
/// - **Resumable** (Qiniu v2 chunked PUT) — for files ≥ 30 MB
///
/// Both strategies stream from disk and never hold the full file in memory.
public final class RelayCDNUploader: @unchecked Sendable {

    public let relayBaseURL: URL
    private let credentialStore: CredentialStore

    public init(
        relayBaseURL: URL = URL(string: "https://relay.ai.qili2.com")!,
        credentialStore: CredentialStore = CredentialStore()
    ) {
        self.relayBaseURL = relayBaseURL
        self.credentialStore = credentialStore
    }

    // MARK: - Public Types

    public struct CDNUploadToken: Sendable {
        public let uploadToken: String
        public let key: String
        public let bucket: String
        public let cdnUrl: String
        public let uploadHost: String
    }

    // MARK: - Token

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
            throw RelayCDNError.missingField("/cdn/token", "uploadToken/key/cdnUrl/uploadHost")
        }
        let bucket: String
        if let b = obj["bucket"] as? String, !b.isEmpty {
            bucket = b
        } else {
            let parts = token.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            var parsed = ""
            if parts.count == 3,
               let polData = Data(base64Encoded: padBase64(String(parts[2]))),
               let polObj = try? JSONSerialization.jsonObject(with: polData) as? [String: Any],
               let scope = polObj["scope"] as? String,
               let colon = scope.firstIndex(of: ":") {
                parsed = String(scope[..<colon])
            }
            bucket = parsed
        }
        return CDNUploadToken(uploadToken: token, key: key, bucket: bucket, cdnUrl: cdnUrl, uploadHost: host)
    }

    // MARK: - Upload

    /// Upload a local file directly to Qiniu via a put-token, streaming from
    /// disk (never holds the whole file in memory). Returns the CDN URL.
    public func upload(
        fileURL: URL,
        filename: String,
        mimeType: String = "application/octet-stream",
        prefix: String = "neox/attachments",
        progress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> String {
        let token = try await requestUploadToken(filename: filename, prefix: prefix)

        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        if size >= 30 * 1024 * 1024 {
            return try await uploadResumable(token: token, fileURL: fileURL, filename: filename, mimeType: mimeType, totalSize: size, progress: progress)
        }

        return try await uploadDirect(token: token, fileURL: fileURL, filename: filename, mimeType: mimeType, progress: progress)
    }

    // MARK: - Direct (multipart form POST, < 30 MB)

    private func uploadDirect(
        token: CDNUploadToken,
        fileURL: URL,
        filename: String,
        mimeType: String,
        progress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> String {
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
            throw RelayCDNError.missingField("/cdn-direct", "tmp output stream")
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
                    if written < 0 { throw out.streamError ?? RelayCDNError.missingField("/cdn-direct", "write") }
                    if written == 0 { break }
                    offset += written
                    remaining -= written
                }
            }
        }

        try writeData(part("token", value: token.uploadToken))
        try writeData(part("key", value: token.key))

        var fileHeader = Data()
        fileHeader.append("--\(boundary)\(crlf)".data(using: .utf8)!)
        fileHeader.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\(crlf)".data(using: .utf8)!)
        fileHeader.append("Content-Type: \(mimeType)\(crlf)\(crlf)".data(using: .utf8)!)
        try writeData(fileHeader)

        guard let inFile = InputStream(url: fileURL) else {
            throw RelayCDNError.missingField("/cdn-direct", "source file")
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
                if w <= 0 { throw out.streamError ?? RelayCDNError.missingField("/cdn-direct", "write-file") }
                written += w
            }
        }

        try writeData("\(crlf)--\(boundary)--\(crlf)".data(using: .utf8)!)

        guard let hostURL = URL(string: token.uploadHost) else {
            throw RelayCDNError.missingField("/cdn-direct", "uploadHost URL")
        }
        var req = URLRequest(url: hostURL)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 600

        let session: URLSession
        let delegate: CDNUploadProgressDelegate?
        if let progress {
            let d = CDNUploadProgressDelegate(progress: progress)
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
        return token.cdnUrl
    }

    // MARK: - Resumable (Qiniu v2, ≥ 30 MB)

    private func uploadResumable(
        token: CDNUploadToken,
        fileURL: URL,
        filename: String,
        mimeType: String,
        totalSize: Int,
        progress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> String {
        guard !token.bucket.isEmpty else {
            throw RelayCDNError.missingField("/cdn/token", "bucket (needed for resumable)")
        }
        let chunkSize = 8 * 1024 * 1024
        let maxConcurrent = 4
        let host = token.uploadHost
        let encodedKey: String = {
            let raw = Data(token.key.utf8).base64EncodedString()
            return raw.replacingOccurrences(of: "+", with: "-")
                      .replacingOccurrences(of: "/", with: "_")
        }()
        let baseObject = "\(host)/buckets/\(token.bucket)/objects/\(encodedKey)/uploads"
        let authHeader = "UpToken \(token.uploadToken)"

        // 1) Init upload
        let uploadId: String = try await {
            var r = URLRequest(url: URL(string: baseObject)!)
            r.httpMethod = "POST"
            r.setValue(authHeader, forHTTPHeaderField: "Authorization")
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.timeoutInterval = 60
            let (d, resp) = try await URLSession.shared.data(for: r)
            try ensureOK(resp, body: d, label: "qiniu-resumable-init")
            guard let o = try JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let id = o["uploadId"] as? String else {
                throw RelayCDNError.missingField("qiniu-resumable-init", "uploadId")
            }
            return id
        }()

        // 2) Upload parts in parallel
        let partCount = (totalSize + chunkSize - 1) / chunkSize
        var partResults = Array<(Int, String)?>(repeating: nil, count: partCount)
        let totalSize64 = Int64(totalSize)
        let progressBox = CDNProgressBox(total: totalSize64, progress: progress)

        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var nextPart = 1
            var inFlight = 0
            while nextPart <= partCount || inFlight > 0 {
                while inFlight < maxConcurrent && nextPart <= partCount {
                    let pn = nextPart
                    let offset = Int64(pn - 1) * Int64(chunkSize)
                    let thisChunkSize = min(chunkSize, totalSize - Int(offset))
                    let url = URL(string: "\(baseObject)/\(uploadId)/\(pn)")!
                    let fileURLCopy = fileURL
                    let auth = authHeader
                    group.addTask {
                        let handle = try FileHandle(forReadingFrom: fileURLCopy)
                        defer { try? handle.close() }
                        try handle.seek(toOffset: UInt64(offset))
                        let chunk = handle.readData(ofLength: thisChunkSize)
                        var r = URLRequest(url: url)
                        r.httpMethod = "PUT"
                        r.setValue(auth, forHTTPHeaderField: "Authorization")
                        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                        r.timeoutInterval = 300
                        let (data, resp) = try await URLSession.shared.upload(for: r, from: chunk)
                        guard let http = resp as? HTTPURLResponse else {
                            throw RelayCDNError.noHTTPResponse("qiniu-resumable-part-\(pn)")
                        }
                        if !(200..<300).contains(http.statusCode) {
                            let txt = String(data: data, encoding: .utf8) ?? ""
                            throw RelayCDNError.httpError("qiniu-resumable-part-\(pn)", http.statusCode, txt)
                        }
                        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let etag = o["etag"] as? String else {
                            throw RelayCDNError.missingField("qiniu-resumable-part-\(pn)", "etag")
                        }
                        await progressBox.add(Int64(chunk.count))
                        return (pn, etag)
                    }
                    inFlight += 1
                    nextPart += 1
                }
                if let (pn, etag) = try await group.next() {
                    partResults[pn - 1] = (pn, etag)
                    inFlight -= 1
                } else {
                    break
                }
            }
        }

        let parts: [[String: Any]] = partResults.compactMap { pair in
            guard let (pn, etag) = pair else { return nil }
            return ["partNumber": pn, "etag": etag]
        }

        // 3) Complete
        var completeReq = URLRequest(url: URL(string: "\(baseObject)/\(uploadId)")!)
        completeReq.httpMethod = "POST"
        completeReq.setValue(authHeader, forHTTPHeaderField: "Authorization")
        completeReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        completeReq.timeoutInterval = 120
        let completeBody: [String: Any] = [
            "parts": parts,
            "mimeType": mimeType,
            "fname": filename,
        ]
        completeReq.httpBody = try JSONSerialization.data(withJSONObject: completeBody)
        let (cdata, cresp) = try await URLSession.shared.data(for: completeReq)
        try ensureOK(cresp, body: cdata, label: "qiniu-resumable-complete")
        return token.cdnUrl
    }

    // MARK: - Simple Data Upload (via relay proxy)

    /// Upload raw bytes to CDN via relay proxy. Returns the public URL.
    /// Prefer `upload(fileURL:...)` for large files — this variant loads
    /// everything into memory.
    public func uploadData(_ data: Data, filename: String, mimeType: String = "audio/m4a") async throws -> String {
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
            throw RelayCDNError.missingField("/cdn/upload", "url")
        }
        return url
    }

    // MARK: - Helpers

    private func addAuth(to req: inout URLRequest) {
        if let token = credentialStore.getAPIKey(for: .relay) {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    private func ensureOK(_ resp: URLResponse, body: Data, label: String) throws {
        guard let http = resp as? HTTPURLResponse else {
            throw RelayCDNError.noHTTPResponse(label)
        }
        if !(200..<300).contains(http.statusCode) {
            let txt = String(data: body, encoding: .utf8) ?? ""
            log.error("\(label) HTTP \(http.statusCode): \(txt)")
            throw RelayCDNError.httpError(label, http.statusCode, txt)
        }
    }

    private func padBase64(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let rem = t.count % 4
        if rem > 0 { t.append(String(repeating: "=", count: 4 - rem)) }
        return t
    }
}

// MARK: - Errors

public enum RelayCDNError: LocalizedError {
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

// MARK: - Internal Helpers

private final class CDNUploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let progress: (Int64, Int64) -> Void
    init(progress: @escaping (Int64, Int64) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progress(totalBytesSent, totalBytesExpectedToSend)
    }
}

private actor CDNProgressBox {
    let total: Int64
    let progress: (@Sendable (Int64, Int64) -> Void)?
    private var sent: Int64 = 0
    init(total: Int64, progress: (@Sendable (Int64, Int64) -> Void)?) {
        self.total = total
        self.progress = progress
    }
    func add(_ n: Int64) {
        sent += n
        progress?(sent, total)
    }
}
