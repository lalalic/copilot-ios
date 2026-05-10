import Foundation
import CryptoKit

/// iOS mirror of co-harness `core/relay-billing.ts`.
///
/// Decrypts the per-request `x-llm-trace-id` header sent by the upstream
/// the relay so we can debit the **real** USD cost (relay-defined prices
/// per 1M tokens) against the local balance instead of trusting whatever
/// model id the client requested.
///
/// Format (matches relay):
///   key = SHA256(bearer)
///   blob = IV(12) || tag(16) || ciphertext   (base64url, no padding)
///   ciphertext = JSON `{"in": <usd_per_M>, "out": <usd_per_M>}`
///                — legacy `{"prices": {"input":..., "output":...}}` also accepted.
public struct RelayBilling {

    public struct Prices: Equatable, Sendable {
        public let input: Double  // USD per 1M input tokens
        public let output: Double // USD per 1M output tokens
    }

    /// Decrypt a `x-llm-trace-id` header into prices, or return nil on any error.
    public static func decryptTraceId(_ header: String, bearer: String) -> Prices? {
        guard !header.isEmpty, !bearer.isEmpty,
              let blob = base64URLDecode(header),
              blob.count > 12 + 16 else { return nil }
        let key = SymmetricKey(data: SHA256.hash(data: Data(bearer.utf8)))
        let iv = blob.prefix(12)
        let tag = blob.dropFirst(12).prefix(16)
        let ct = blob.dropFirst(12 + 16)
        guard let nonce = try? AES.GCM.Nonce(data: iv),
              let sealed = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag),
              let plain = try? AES.GCM.open(sealed, using: key),
              let json = try? JSONSerialization.jsonObject(with: plain) as? [String: Any] else { return nil }
        // New shape: {"in": x, "out": y}
        if let i = (json["in"] as? Double) ?? (json["in"] as? Int).map(Double.init),
           let o = (json["out"] as? Double) ?? (json["out"] as? Int).map(Double.init) {
            return Prices(input: i, output: o)
        }
        // Legacy shape: {"prices":{"input":x,"output":y}}
        if let p = json["prices"] as? [String: Any],
           let i = (p["input"] as? Double) ?? (p["input"] as? Int).map(Double.init),
           let o = (p["output"] as? Double) ?? (p["output"] as? Int).map(Double.init) {
            return Prices(input: i, output: o)
        }
        return nil
    }

    /// Cost in USD for the given token counts at the given prices.
    public static func computeCost(_ prices: Prices, inputTokens: Int, outputTokens: Int) -> Double {
        (Double(inputTokens) * prices.input + Double(outputTokens) * prices.output) / 1_000_000.0
    }

    /// True when the model id resolves through the relay provider.
    public static func isRelayModel(_ providerId: String) -> Bool {
        providerId == "relay"
    }

    private static func base64URLDecode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t.append("=") }
        return Data(base64Encoded: t)
    }
}
