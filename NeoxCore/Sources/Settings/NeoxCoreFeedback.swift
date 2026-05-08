//
// NeoxCoreFeedback.swift
// Bootstrap helper that wires the Feedback target into a NeoxCore-based app.
// Apps call `bootstrap(endpoint:app:appVersion:)` once at launch; from that
// point on:
//   - the endpoint is persisted in UserDefaults under
//     `NeoxCoreSettings.feedbackEndpointKey` so SharedFeedbackSettingsSection
//     can read it
//   - the crash handler is installed (respecting the user's
//     `feedbackAutoCrashReportKey` toggle, default ON)
//   - any pending crash from a previous launch is flushed
//
// Why a wrapper? The Feedback target is intentionally generic / zero-deps.
// This file is the NeoxCore-specific glue: settings keys, default toggle
// behavior, and one place to call from `@main`.
//

import Foundation
import Feedback

public enum NeoxCoreFeedback {

    /// Call once at app launch (typically `App.init` or
    /// `application(_:didFinishLaunchingWithOptions:)`). Idempotent: safe to
    /// call again on subsequent launches with the same arguments.
    ///
    /// - Parameters:
    ///   - endpoint: URL the app POSTs feedback / crash reports to. Use the
    ///     encoded-repo form (e.g. `https://relay.example.com/github/r/<enc>/issues`).
    ///   - app: App identifier sent as `X-App` (e.g. "Neox", "Intento").
    ///   - appVersion: App version sent as `X-App-Version`. Pass nil to skip.
    public static func bootstrap(endpoint: URL, app: String, appVersion: String? = nil) {
        let defaults = UserDefaults.standard
        defaults.set(endpoint.absoluteString, forKey: NeoxCoreSettings.feedbackEndpointKey)
        // Default the toggle to ON the first time only; preserve user choice afterwards.
        if defaults.object(forKey: NeoxCoreSettings.feedbackAutoCrashReportKey) == nil {
            defaults.set(true, forKey: NeoxCoreSettings.feedbackAutoCrashReportKey)
        }
        if defaults.bool(forKey: NeoxCoreSettings.feedbackAutoCrashReportKey) {
            Feedback.installCrashHandler(endpoint: endpoint, app: app, appVersion: appVersion)
        }
    }

    /// Toggle auto-crash-reporting at runtime. Persists the new value and
    /// installs / no-ops the crash handler accordingly. Note: a previously
    /// installed handler can't be uninstalled mid-process — disabling here
    /// takes effect on the next launch.
    public static func setAutoCrashReportEnabled(_ enabled: Bool, app: String, appVersion: String? = nil) {
        UserDefaults.standard.set(enabled, forKey: NeoxCoreSettings.feedbackAutoCrashReportKey)
        if enabled, let str = UserDefaults.standard.string(forKey: NeoxCoreSettings.feedbackEndpointKey),
           let url = URL(string: str) {
            Feedback.installCrashHandler(endpoint: url, app: app, appVersion: appVersion)
        }
    }
}
