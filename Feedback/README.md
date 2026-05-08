# Feedback

A Swift Package target for adding feedback (manual reports + automatic
crash reports) to iOS / macOS apps. Reports become GitHub issues in a
repo controlled by the maintainer — but the end user never sees the
repo, never needs a token, and never installs `gh`.

iOS 18+, macOS 15+. Two files, no external dependencies, uses
`URLSession` + `UserDefaults`.

```swift
.product(name: "Feedback", package: "copilot-ios"),
```

The cross-platform contract (wire protocol, encoded-repo URL form,
privacy guarantees) lives in the
[`feedback` skill in copilot-infinite](https://github.com/lalalic/copilot-infinite/tree/main/skills/feedback).

## Files

- `Feedback.swift` — `Feedback.submit(...)`, `Feedback.installCrashHandler(...)`,
  `Feedback.reportError(...)`, `Feedback.anonId(suite:)`.
- `FeedbackView.swift` — SwiftUI sheet with Bug/Suggestion picker, Send
  button, generic banner. Pair with `Feedback.swift`.

## Integrate (manual feedback button)

```swift
struct ContentView: View {
    @State private var showFeedback = false

    var body: some View {
        VStack {
            Button("Send feedback") { showFeedback = true }
        }
        .sheet(isPresented: $showFeedback) {
            FeedbackView(
                endpoint: URL(string: "https://relay.example.com/github/r/<encoded>/issues")!,
                app: "my-app",
                appVersion: Bundle.main.shortVersion)
        }
    }
}
```

## Integrate (auto crash report at app launch)

```swift
@main
struct MyApp: App {
    init() {
        Feedback.installCrashHandler(
            endpoint: URL(string: "https://relay.example.com/github/r/<encoded>/issues")!,
            app: "my-app",
            appVersion: Bundle.main.shortVersion)
    }
    var body: some Scene { WindowGroup { ContentView() } }
}
```

This catches uncaught `NSException`s. To also catch low-level POSIX
signals (SIGABRT, SIGSEGV, …) use a real crash reporter such as
[KSCrash](https://github.com/kstenerud/KSCrash) or
[PLCrashReporter](https://github.com/microsoft/plcrashreporter) and call
`Feedback.reportError(...)` from its callback.

## Encoded-repo URL

Generate once on a dev machine:

```sh
node -e 'const r="OWNER/REPO";\
  console.log(Buffer.from(r).toString("base64")\
    .replace(/\+/g,"-").replace(/\//g,"_").replace(/=+$/,""))'
```

Concatenate: `https://<your-relay>/github/r/<output>/issues`. Bake it
into your app's config; never expose the decoded form in the UI.

## Convenience: `Bundle.shortVersion`

Add this small helper somewhere in your app:

```swift
extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
    }
}
```

## What MUST stay invisible to end users

- The endpoint URL
- The decoded repo (`OWNER/REPO`)
- Any GitHub-specific terminology in error messages
- The `X-Anon-Id` value
