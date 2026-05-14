// RelayDeviceBootstrap.swift
//
// On first launch (or when no relay bearer is stored), registers this device
// with the relay using a bootstrap token loaded from Info.plist key
// `RelayBootstrapToken`. The returned per-device bearer is stored in the
// `CredentialStore` under `.relay` so all subsequent relay calls can
// authenticate.
//
// Mirrors `bullx/core/relay-device.ts`. See also: docs/relay-device-bootstrap.md.
//
// Posts `Notification.Name("relayBearerAvailable")` after a successful
// registration so listeners (e.g. `RelayPushRegistration`) can re-attempt
// any actions that were waiting on a bearer.

import Foundation
#if canImport(UIKit)
import UIKit
#endif

public enum RelayDeviceBootstrap {
    public static let bearerAvailableNotification = Notification.Name("relayBearerAvailable")

    /// Register this device with the relay using a bootstrap token from
    /// Info.plist key `RelayBootstrapToken`. Returns the per-device bearer on
    /// success, or `nil` if no bootstrap token is available or registration
    /// fails. The caller is responsible for persisting the returned bearer
    /// (e.g. via `CredentialStore`).
    public static func register(
        relayBaseURL: String,
        platform: String,
        appVersion: String
    ) async -> String? {
        guard let bootstrap = Bundle.main.object(forInfoDictionaryKey: "RelayBootstrapToken") as? String,
              !bootstrap.isEmpty else {
            NSLog("[RelayDeviceBootstrap] no RelayBootstrapToken in Info.plist; skipping")
            return nil
        }

        let deviceId = stableDeviceId()
        let name = deviceName()
        let base = relayBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/llm/v1/register") else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "bootstrap": bootstrap,
            "deviceId": deviceId,
            "platform": platform,
            "version": appVersion,
            "name": name,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 15

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                let preview = String(data: data, encoding: .utf8)?.prefix(120) ?? ""
                NSLog("[RelayDeviceBootstrap] register failed HTTP \(status): \(preview)")
                return nil
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let bearer = obj["bearer"] as? String, !bearer.isEmpty else {
                NSLog("[RelayDeviceBootstrap] register response missing bearer")
                return nil
            }
            NSLog("[RelayDeviceBootstrap] registered: \(deviceId.prefix(8))… → bearer \(bearer.prefix(12))…")
            return bearer
        } catch {
            NSLog("[RelayDeviceBootstrap] register error: \(error.localizedDescription)")
            return nil
        }
    }

    /// Stable per-device id. Uses `identifierForVendor` (resets on uninstall but
    /// stable per app install). Persisted in UserDefaults so even an
    /// identifierForVendor reset doesn't churn the deviceId.
    private static func stableDeviceId() -> String {
        let key = "relayDeviceId"
        if let cached = UserDefaults.standard.string(forKey: key), !cached.isEmpty {
            return cached
        }
        #if canImport(UIKit)
        let id = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        #else
        let id = UUID().uuidString
        #endif
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    private static func deviceName() -> String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return ProcessInfo.processInfo.hostName
        #endif
    }
}
