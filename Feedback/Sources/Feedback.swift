//
// Feedback.swift
// Drop-in feedback client for iOS / macOS apps. ~200 LoC, zero deps.
//
// Posts a GitHub-native issue payload to a relay endpoint that handles
// server-side authentication and decodes an opaque encoded repo segment.
// End users never see the repo, the token, or which transport is being used.
//
// Usage (manual feedback):
//   let r = await Feedback.submit(
//     endpoint: URL(string: "https://relay.example.com/github/r/<enc>/issues")!,
//     app: "my-app",
//     appVersion: "1.2.3",
//     title: "Crash on save",
//     body: "Steps...",
//     kind: .bug,
//     source: .user)
//   showToast(r.ok ? "Sent." : "Couldn't send feedback right now.")
//
// Usage (crash auto-report — call once at app launch):
//   Feedback.installCrashHandler(
//     endpoint: URL(string: "https://...")!,
//     app: "my-app",
//     appVersion: Bundle.main.version)
//

import Foundation

public enum Feedback {

    public enum Kind: String { case bug, suggestion }
    public enum Source: String { case user, agent, auto }

    public struct Result {
        public let ok: Bool
        public let url: URL?
        public let number: Int?
        /// Generic, user-safe message. Never includes the endpoint or repo.
        public let error: String?
    }

    // MARK: – Anonymous client identity

    /// Persisted UUID, written once to UserDefaults under the given suite.
    /// Sent as `X-Anon-Id` so the relay can rate-limit per client without
    /// ever collecting PII.
    public static func anonId(suite: String = "feedback") -> String {
        let key = "\(suite).anonId"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    // MARK: – Manual submit

    public static func submit(
        endpoint: URL,
        app: String,
        appVersion: String? = nil,
        title: String,
        body: String,
        kind: Kind,
        source: Source,
        labels: [String] = []
    ) async -> Result {
        guard endpoint.scheme == "https"
                || endpoint.host == "127.0.0.1"
                || endpoint.host == "localhost"
        else {
            return Result(ok: false, url: nil, number: nil,
                          error: "Couldn't send feedback right now.")
        }

        let allLabels = ([kind == .bug ? "bug" : "enhancement",
                          "from:\(source.rawValue)"] + labels).deduped()
        let stamp = ISO8601DateFormatter().string(from: Date())
        let composedBody =
            "\(body)\n\n---\n_kind: \(kind.rawValue)_\n" +
            "_source: \(source.rawValue)_\n_reported: \(stamp)_\n" +
            "_app: \(app)\(appVersion.map { " \($0)" } ?? "")_\n"

        let payload: [String: Any] = [
            "title": title,
            "body":  composedBody,
            "labels": allLabels,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            return Result(ok: false, url: nil, number: nil,
                          error: "Couldn't send feedback right now.")
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.httpBody = data
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("\(app)-feedback", forHTTPHeaderField: "User-Agent")
        req.setValue(anonId(suite: app), forHTTPHeaderField: "X-Anon-Id")
        req.setValue(app, forHTTPHeaderField: "X-App")
        if let v = appVersion { req.setValue(v, forHTTPHeaderField: "X-App-Version") }

        do {
            let (respData, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                return Result(ok: false, url: nil, number: nil,
                              error: "Couldn't send feedback right now.")
            }
            if (200..<300).contains(http.statusCode) {
                let parsed = try? JSONSerialization.jsonObject(with: respData) as? [String: Any]
                let url    = (parsed?["html_url"] as? String).flatMap(URL.init(string:))
                let number = parsed?["number"] as? Int
                return Result(ok: true, url: url, number: number, error: nil)
            } else {
                // NEVER surface raw upstream error to end users.
                NSLog("[Feedback] upstream %d", http.statusCode)
                return Result(ok: false, url: nil, number: nil,
                              error: "Couldn't send feedback right now.")
            }
        } catch {
            NSLog("[Feedback] network error: %@", String(describing: error))
            return Result(ok: false, url: nil, number: nil,
                          error: "Couldn't send feedback right now.")
        }
    }

    // MARK: – Auto crash report

    /// Install a top-level NSException handler + Swift Task error trap.
    /// Reports are dedupe'd within `dedupeWindow` seconds.
    ///
    /// Note: catching low-level signals (SIGABRT, SIGSEGV, ...) is left to
    /// a real crash reporter (KSCrash, PLCrashReporter) — this only catches
    /// uncaught Objective-C exceptions and explicit reports.
    public static func installCrashHandler(
        endpoint: URL,
        app: String,
        appVersion: String? = nil,
        dedupeWindow: TimeInterval = 600
    ) {
        SharedCrashState.shared.configure(
            endpoint: endpoint, app: app, appVersion: appVersion,
            dedupeWindow: dedupeWindow)

        NSSetUncaughtExceptionHandler { ex in
            SharedCrashState.shared.report(ex)
        }
    }

    /// Manually report a caught error / exception.
    public static func reportError(
        _ error: Error,
        context: [String: Any] = [:]
    ) {
        SharedCrashState.shared.report(error, context: context)
    }
}

// MARK: – Internal

private final class SharedCrashState {
    static let shared = SharedCrashState()
    private let lock = NSLock()
    private var recent: [String: Date] = [:]
    private var endpoint: URL?
    private var app: String?
    private var appVersion: String?
    private var dedupeWindow: TimeInterval = 600

    func configure(endpoint: URL, app: String, appVersion: String?, dedupeWindow: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        self.endpoint = endpoint
        self.app = app
        self.appVersion = appVersion
        self.dedupeWindow = dedupeWindow
    }

    private func shouldSend(sig: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        if let last = recent[sig], now.timeIntervalSince(last) < dedupeWindow { return false }
        recent[sig] = now
        return true
    }

    func report(_ ex: NSException) {
        let title = "[auto] \(ex.name.rawValue): \(ex.reason ?? "")"
        let body  = """
        **Auto-reported NSException**

        ```
        \(ex.name.rawValue): \(ex.reason ?? "")
        \((ex.callStackSymbols).joined(separator: "\n"))
        ```
        """
        send(title: String(title.prefix(180)), body: body)
    }

    func report(_ err: Error, context: [String: Any] = [:]) {
        let title = "[auto] \(type(of: err)): \(err.localizedDescription)"
        var body = """
        **Auto-reported Swift error**

        ```
        \(err)
        ```
        """
        if !context.isEmpty,
           let json = try? JSONSerialization.data(withJSONObject: context, options: [.prettyPrinted]),
           let str  = String(data: json, encoding: .utf8) {
            body += "\n\n**Context**\n```json\n\(str)\n```"
        }
        send(title: String(title.prefix(180)), body: body)
    }

    private func send(title: String, body: String) {
        guard let endpoint, let app else { return }
        let sig = title
        guard shouldSend(sig: sig) else { return }
        Task.detached {
            _ = await Feedback.submit(
                endpoint: endpoint,
                app: app,
                appVersion: self.appVersion,
                title: title, body: body,
                kind: .bug, source: .auto)
        }
    }
}

private extension Array where Element: Hashable {
    func deduped() -> [Element] {
        var seen = Set<Element>()
        return self.filter { seen.insert($0).inserted }
    }
}
