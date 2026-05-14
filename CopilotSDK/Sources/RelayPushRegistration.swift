// RelayPushRegistration.swift
//
// Registers the device's APNs push token with the relay so the relay can
// forward `report_to_channel` / status pushes to this device when the live
// SSE stream isn't connected (app backgrounded / phone offline).
//
// Usage:
//   1. AppDelegate stores the hex APNs token in
//      UserDefaults.standard.set(token, forKey: "apnsDeviceToken") and posts
//      `Notification.Name("deviceTokenReceived")` with `object: hexToken`.
//   2. Call `RelayPushRegistration.shared.start(credentials: ...)` at app
//      launch (e.g. from BaseCoordinator.init). It listens for the
//      notification and re-registers whenever the token changes.
//
// Relay endpoint contract:
//   POST {RELAY_BASE}/llm/v1/register-push-token
//     Authorization: Bearer <relay-bearer>
//     Content-Type:  application/json
//     Body: { "apnsToken": "<hex>", "apnsEnv": "production"|"sandbox" }
//   → 200 { "ok": true }

import Foundation

public final class RelayPushRegistration: @unchecked Sendable {
    public static let shared = RelayPushRegistration()

    private let queue = DispatchQueue(label: "relay-push-registration", qos: .utility)
    private var observer: NSObjectProtocol?
    private var bearerObserver: NSObjectProtocol?
    private var bearerProvider: (() -> String?)?
    private var relayBaseURL: String = "https://relay.ai.qili2.com"
    private var apnsEnv: String = {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }()
    private var lastRegisteredToken: String?

    private init() {}

    /// Start listening for APNs token notifications and registering with the relay.
    /// - Parameters:
    ///   - relayBaseURL: e.g. "https://relay.ai.qili2.com"
    ///   - bearerProvider: closure that returns the current relay bearer (from CredentialStore)
    ///   - apnsEnv: "production" or "sandbox". Defaults to sandbox in DEBUG, production otherwise.
    public func start(
        relayBaseURL: String = "https://relay.ai.qili2.com",
        apnsEnv: String? = nil,
        bearerProvider: @escaping () -> String?
    ) {
        self.relayBaseURL = relayBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.bearerProvider = bearerProvider
        if let env = apnsEnv { self.apnsEnv = env }

        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: Notification.Name("deviceTokenReceived"),
                object: nil,
                queue: nil
            ) { [weak self] note in
                guard let token = note.object as? String, !token.isEmpty else { return }
                self?.register(token: token)
            }
        }

        // Listen for relay-bearer-available so we can retry registration when
        // the bootstrap flow completes after we already received the APN token.
        if bearerObserver == nil {
            bearerObserver = NotificationCenter.default.addObserver(
                forName: Notification.Name("relayBearerAvailable"),
                object: nil,
                queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                if let cached = UserDefaults.standard.string(forKey: "apnsDeviceToken"), !cached.isEmpty {
                    self.lastRegisteredToken = nil // force resend
                    self.register(token: cached)
                }
            }
        }

        // If the token was already received before start() was called, register now.
        if let cached = UserDefaults.standard.string(forKey: "apnsDeviceToken"), !cached.isEmpty {
            register(token: cached)
        }
    }

    /// POST the token to the relay. Safe to call repeatedly — only re-sends if
    /// the token actually changed since the last successful registration.
    public func register(token: String) {
        queue.async { [weak self] in
            guard let self else { return }
            if token == self.lastRegisteredToken { return }
            guard let bearer = self.bearerProvider?(), !bearer.isEmpty else {
                NSLog("[RelayPushRegistration] no relay bearer yet; skipping")
                return
            }
            guard let url = URL(string: "\(self.relayBaseURL)/llm/v1/register-push-token") else { return }

            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            let body: [String: Any] = ["apnsToken": token, "apnsEnv": self.apnsEnv]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            req.timeoutInterval = 15

            URLSession.shared.dataTask(with: req) { _, resp, err in
                if let err = err {
                    NSLog("[RelayPushRegistration] error: \(err.localizedDescription)")
                    return
                }
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200 {
                    NSLog("[RelayPushRegistration] registered apnsToken")
                    RelayPushRegistration.shared.queue.async {
                        RelayPushRegistration.shared.lastRegisteredToken = token
                    }
                } else {
                    NSLog("[RelayPushRegistration] register failed: HTTP \(status)")
                }
            }.resume()
        }
    }

    /// Stop listening for token notifications. Useful for tests.
    public func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let bearerObserver { NotificationCenter.default.removeObserver(bearerObserver) }
        observer = nil
        bearerObserver = nil
        bearerProvider = nil
        lastRegisteredToken = nil
    }
}
