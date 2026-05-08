//
// FeedbackView.swift
// SwiftUI sheet for manual feedback submission. Pair with Feedback.swift.
//
// Usage:
//   .sheet(isPresented: $showFeedback) {
//       FeedbackView(
//           endpoint: URL(string: "https://relay.example.com/github/r/<enc>/issues")!,
//           app: "my-app",
//           appVersion: "1.2.3")
//   }
//

import SwiftUI

public struct FeedbackView: View {
    public let endpoint: URL
    public let app: String
    public let appVersion: String?

    @Environment(\.dismiss) private var dismiss
    @State private var kind: Feedback.Kind = .bug
    @State private var title: String = ""
    @State private var bodyText: String = ""
    @State private var sending = false
    @State private var bannerText: String?
    @State private var bannerOk = false

    public init(endpoint: URL, app: String, appVersion: String? = nil) {
        self.endpoint = endpoint
        self.app = app
        self.appVersion = appVersion
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $kind) {
                        Text("Bug").tag(Feedback.Kind.bug)
                        Text("Suggestion").tag(Feedback.Kind.suggestion)
                    }
                    .pickerStyle(.segmented)
                }

                Section("Title") {
                    TextField("Short summary", text: $title)
                }

                Section("Description") {
                    TextEditor(text: $bodyText)
                        .frame(minHeight: 140)
                }

                if let bannerText {
                    Section {
                        Text(bannerText)
                            .foregroundStyle(bannerOk ? .green : .red)
                    }
                }
            }
            .navigationTitle("Send feedback")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(sending ? "Sending…" : "Send") {
                        Task { await send() }
                    }
                    .disabled(sending || title.trimmingCharacters(in: .whitespaces).isEmpty
                                       || bodyText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func send() async {
        sending = true
        bannerText = nil
        let r = await Feedback.submit(
            endpoint: endpoint,
            app: app,
            appVersion: appVersion,
            title: title, body: bodyText,
            kind: kind, source: .user)
        sending = false
        if r.ok {
            bannerOk = true
            bannerText = "Thanks — your feedback was sent."
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            dismiss()
        } else {
            bannerOk = false
            bannerText = r.error ?? "Couldn't send feedback right now."
        }
    }
}
