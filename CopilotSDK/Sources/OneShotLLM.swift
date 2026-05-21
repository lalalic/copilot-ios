import Foundation

/// Lightweight one-shot LLM call — sends a single prompt (with optional image)
/// to a provider adapter and returns the response text. No tools, no agent loop.
public enum OneShotLLM {

    /// Make a one-shot LLM call with an optional image attachment.
    /// - Parameters:
    ///   - adapter: The provider adapter to use (e.g. OpenAIAdapter)
    ///   - model: Model ID (e.g. "gpt-4o")
    ///   - apiKey: API key for the provider
    ///   - baseURL: Optional base URL override
    ///   - prompt: The text prompt
    ///   - imageData: Optional image data to include
    ///   - imageMimeType: MIME type of the image (e.g. "image/jpeg")
    /// - Returns: The assistant's response text, or nil on error
    public static func call(
        adapter: ProviderAdapter,
        model: String,
        apiKey: String,
        baseURL: String? = nil,
        prompt: String,
        imageData: Data? = nil,
        imageMimeType: String = "image/jpeg"
    ) async -> String? {
        var contentParts: [ProviderMessage.ContentPart] = [.text(prompt)]
        if let imageData, !imageData.isEmpty {
            contentParts.append(.image(data: imageData, mimeType: imageMimeType))
        }

        let message = ProviderMessage(role: .user, content: contentParts)
        let config = ProviderRequestConfig(
            apiKey: apiKey,
            baseURL: baseURL,
            maxTokens: 1024,
            streaming: true
        )

        let collector = TextCollector()
        do {
            try await adapter.streamCompletion(
                messages: [message],
                model: model,
                systemMessage: nil,
                tools: [],
                config: config,
                onEvent: { event in
                    if case .assistantTextDelta(let delta) = event {
                        collector.append(delta.text)
                    }
                }
            )
        } catch {
            return nil
        }

        let result = collector.text
        return result.isEmpty ? nil : result
    }
}

/// Thread-safe text accumulator for streaming responses.
private final class TextCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _text = ""

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return _text
    }

    func append(_ str: String) {
        lock.lock()
        _text += str
        lock.unlock()
    }
}
