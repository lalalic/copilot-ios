import Foundation
#if canImport(Security)
import Security
#endif

// MARK: - CredentialStore

/// Local secure credential storage for BYOK mode.
/// Provider keys are stored in the Keychain.
public final class CredentialStore: @unchecked Sendable {

    /// Known provider identifiers.
    public enum Provider: String, CaseIterable, Sendable {
        case openai = "openai"
        case anthropic = "anthropic"
        case google = "google"
        case xai = "xai"
        case deepseek = "deepseek"
        case copilot = "copilot"
        case relay = "relay"
        case custom = "custom"
    }

    private let keychainServicePrefix: String

    public init(keychainServicePrefix: String = "com.copilot-ios.credentials") {
        self.keychainServicePrefix = keychainServicePrefix
    }

    // MARK: - Public API

    /// Store an API key for a provider.
    public func setAPIKey(_ key: String, for provider: Provider) throws {
        try setAPIKey(key, forProviderKey: provider.rawValue)
    }

    /// Retrieve the API key for a provider.
    public func getAPIKey(for provider: Provider) -> String? {
        getAPIKey(forProviderKey: provider.rawValue)
    }

    /// Remove the API key for a provider.
    public func removeAPIKey(for provider: Provider) throws {
        try removeAPIKey(forProviderKey: provider.rawValue)
    }

    /// Store an API key for a custom provider identifier.
    public func setAPIKey(_ key: String, forProviderKey providerKey: String) throws {
        let service = keychainService(for: providerKey)
        let account = providerKey

        // Delete existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new item
        guard let data = key.data(using: .utf8) else {
            throw CredentialStoreError.encodingFailed
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            // Keychain unavailable (e.g. simulator without entitlements) — fall back to UserDefaults
            UserDefaults.standard.set(key, forKey: userDefaultsKey(for: providerKey))
        }
    }

    /// Retrieve an API key for a custom provider identifier.
    public func getAPIKey(forProviderKey providerKey: String) -> String? {
        let service = keychainService(for: providerKey)
        let account = providerKey

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess,
           let data = result as? Data,
           let key = String(data: data, encoding: .utf8) {
            return key
        }
        // Keychain unavailable — check UserDefaults fallback
        return UserDefaults.standard.string(forKey: userDefaultsKey(for: providerKey))
    }

    /// Remove an API key for a custom provider identifier.
    public func removeAPIKey(forProviderKey providerKey: String) throws {
        let service = keychainService(for: providerKey)
        let account = providerKey

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychainError(status)
        }
    }

    /// Check if any provider has a stored API key.
    public func hasAnyCredentials() -> Bool {
        Provider.allCases.contains { getAPIKey(for: $0) != nil }
    }

    /// List all providers that have stored credentials.
    public func configuredProviders() -> [Provider] {
        Provider.allCases.filter { getAPIKey(for: $0) != nil }
    }

    /// Store a custom base URL for a provider (stored in UserDefaults, not Keychain).
    public func setBaseURL(_ url: String, for provider: Provider) {
        UserDefaults.standard.set(url, forKey: baseURLKey(for: provider.rawValue))
    }

    /// Retrieve the custom base URL for a provider.
    public func getBaseURL(for provider: Provider) -> String? {
        UserDefaults.standard.string(forKey: baseURLKey(for: provider.rawValue))
    }

    /// Build a RuntimeProviderConfig for a given provider.
    public func providerConfig(for provider: Provider) -> RuntimeProviderConfig? {
        guard let apiKey = getAPIKey(for: provider) else { return nil }
        return RuntimeProviderConfig(
            baseURL: getBaseURL(for: provider),
            apiKey: apiKey
        )
    }

    // MARK: - Private

    private func keychainService(for providerKey: String) -> String {
        "\(keychainServicePrefix).\(providerKey)"
    }

    private func userDefaultsKey(for providerKey: String) -> String {
        "\(keychainServicePrefix).fallback.\(providerKey)"
    }

    private func baseURLKey(for providerKey: String) -> String {
        "credential.baseURL.\(providerKey)"
    }
}

// MARK: - Errors

public enum CredentialStoreError: Error, LocalizedError {
    case encodingFailed
    case keychainError(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode API key"
        case .keychainError(let status):
            return "Keychain error: \(status)"
        }
    }
}
