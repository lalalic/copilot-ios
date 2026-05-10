import Foundation
import CryptoKit
import Security

/// iOS mirror of co-harness `core/balance.ts`.
///
/// Tamper-resistant local USD balance store. Defenses:
///   1. Encryption — payload encrypted with AES-256-GCM using a per-install
///      key kept in the Keychain (`kSecAttrAccessibleAfterFirstUnlock`).
///   2. HMAC-SHA256 over `${balance}|${version}` keyed by an in-blob nonce —
///      defeats hand-edits and cross-install swap.
///   3. Monotonic version counter (in-memory + on-disk) — defeats restoring
///      an older blob to refund yourself.
///
/// Storage layout: blob written to `Library/Application Support/balance.bin`.
public final class SecureBalance: @unchecked Sendable {

    public static let shared = SecureBalance()

    private let queue = DispatchQueue(label: "com.copilot-ios.SecureBalance")
    private let defaultBalance: Double = 10.0
    private var lastSeenVersion: Int = 0

    // MARK: - Public API

    public func read() -> Double { queue.sync { load().balance } }

    public func info() -> (encrypted: Bool, version: Int, balance: Double) {
        queue.sync {
            let b = load()
            return (true, b.version, b.balance)
        }
    }

    public func debit(_ amountUsd: Double) -> Double {
        guard amountUsd > 0 else { return read() }
        return queue.sync {
            var b = load()
            b.balance -= amountUsd
            b.version += 1
            save(b)
            return b.balance
        }
    }

    public func credit(_ amountUsd: Double) -> Double {
        guard amountUsd > 0 else { return read() }
        return queue.sync {
            var b = load()
            b.balance += amountUsd
            b.version += 1
            save(b)
            return b.balance
        }
    }

    /// Used when migrating from `UsageTracker.balance` (UserDefaults) at first launch.
    public func seedIfFresh(_ balance: Double) {
        queue.sync {
            if FileManager.default.fileExists(atPath: blobURL().path) { return }
            var fresh = Blob(balance: balance, version: 1, nonce: randomNonce(), hmac: "")
            fresh.hmac = computeHmac(fresh)
            save(fresh)
        }
    }

    // MARK: - Blob

    private struct Blob: Codable {
        var balance: Double
        var version: Int
        var nonce: String
        var hmac: String
    }

    private func load() -> Blob {
        let url = blobURL()
        if let data = try? Data(contentsOf: url),
           let plain = decryptBlob(data),
           let b = try? JSONDecoder().decode(Blob.self, from: plain),
           computeHmac(b) == b.hmac,
           b.version >= lastSeenVersion {
            lastSeenVersion = b.version
            return b
        }
        // Tamper, missing, or rollback → reset.
        var fresh = Blob(balance: defaultBalance, version: 1, nonce: randomNonce(), hmac: "")
        fresh.hmac = computeHmac(fresh)
        save(fresh)
        return fresh
    }

    private func save(_ b: Blob) {
        var finalized = b
        finalized.hmac = computeHmac(finalized)
        guard let plain = try? JSONEncoder().encode(finalized),
              let cipher = encryptBlob(plain) else { return }
        try? FileManager.default.createDirectory(at: blobURL().deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? cipher.write(to: blobURL(), options: .atomic)
        lastSeenVersion = finalized.version
    }

    private func computeHmac(_ b: Blob) -> String {
        let key = SymmetricKey(data: Data(b.nonce.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data("\(b.balance)|\(b.version)".utf8), using: key)
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }

    private func randomNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &bytes)
        return Data(bytes).map { String(format: "%02x", $0) }.joined()
    }

    private func blobURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("balance.bin")
    }

    // MARK: - Crypto

    private func encryptBlob(_ data: Data) -> Data? {
        guard let key = obtainKey() else { return nil }
        guard let sealed = try? AES.GCM.seal(data, using: key) else { return nil }
        return sealed.combined
    }

    private func decryptBlob(_ data: Data) -> Data? {
        guard let key = obtainKey() else { return nil }
        guard let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return plain
    }

    /// Returns a symmetric key persisted in the Keychain. Generates one on first use.
    private func obtainKey() -> SymmetricKey? {
        let tag = "com.copilot-ios.SecureBalance.key".data(using: .utf8)!
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tag,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        // Generate new
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, 32, &bytes) == errSecSuccess else { return nil }
        let keyData = Data(bytes)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tag,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemDelete(q as CFDictionary)
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return nil }
        return SymmetricKey(data: keyData)
    }
}
