import Foundation
import Combine

// MARK: - UsageTracker

/// Client-authoritative usage and balance tracker.
/// Persists all data to UserDefaults — no server sync needed.
public class UsageTracker: ObservableObject, @unchecked Sendable {
    
    // MARK: - Published State
    
    /// Current credit balance in USD. Starts at $2.00 for new installs.
    @Published public private(set) var balance: Double
    
    /// Cost accumulated in the current session.
    @Published public private(set) var sessionCost: Double = 0.0
    
    /// Tokens consumed in the current session.
    @Published public private(set) var sessionTokens: Int = 0
    
    /// Total cost consumed over the lifetime of the app.
    @Published public private(set) var lifetimeCost: Double = 0.0
    
    /// Total tokens consumed over the lifetime of the app.
    @Published public private(set) var lifetimeTokens: Int = 0
    
    /// Per-model token breakdown for the current session.
    @Published public private(set) var sessionUsageByModel: [String: TokenUsage] = [:]

    /// True once the server has reported a balance via `X-Balance-Cents`.
    /// When set, the client no longer locally debits `balance` from `record(...)` —
    /// the relay is authoritative and pushes balance via response headers.
    @Published public private(set) var serverManaged: Bool = false

    private var walletObserver: NSObjectProtocol?

    // MARK: - Types
    
    public struct TokenUsage: Codable, Sendable {
        public var promptTokens: Int = 0
        public var completionTokens: Int = 0
        public var cost: Double = 0.0
        
        public init(promptTokens: Int = 0, completionTokens: Int = 0, cost: Double = 0.0) {
            self.promptTokens = promptTokens
            self.completionTokens = completionTokens
            self.cost = cost
        }
    }
    
    // MARK: - Persistence
    
    private let defaults: UserDefaults
    
    private static let balanceKey = "neox.balance"
    private static let lifetimeCostKey = "neox.lifetime.cost"
    private static let lifetimeTokensKey = "neox.lifetime.tokens"
    private static let defaultBalance: Double = 2.00
    
    // MARK: - Init
    
    /// Create a UsageTracker with the given UserDefaults store.
    /// Pass a fresh UserDefaults instance for testing.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        
        // Load persisted state
        if defaults.object(forKey: Self.balanceKey) != nil {
            self.balance = defaults.double(forKey: Self.balanceKey)
        } else {
            self.balance = Self.defaultBalance
        }
        self.lifetimeCost = defaults.double(forKey: Self.lifetimeCostKey)
        self.lifetimeTokens = defaults.integer(forKey: Self.lifetimeTokensKey)

        // Subscribe to relay v4 server-side wallet updates.
        // `OpenAIAdapter` posts this notification with userInfo["cents"] on every
        // /llm/v1/chat/completions response that carries an `X-Balance-Cents` header.
        let center = NotificationCenter.default
        self.walletObserver = center.addObserver(
            forName: Notification.Name("CopilotSDK.WalletBalanceDidChange"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard let cents = note.userInfo?["cents"] as? Int else { return }
            self.applyServerBalance(cents: cents)
        }
    }

    deinit {
        if let obs = walletObserver { NotificationCenter.default.removeObserver(obs) }
    }

    /// Apply a server-authoritative balance (in cents) to this tracker.
    /// Flips `serverManaged` to true; subsequent `record(...)` calls will skip
    /// local debit and only update session/lifetime counters.
    public func applyServerBalance(cents: Int) {
        self.serverManaged = true
        self.balance = Double(cents) / 100.0
        persist()
    }
    
    // MARK: - Recording
    
    /// Record a single usage event with a pre-calculated cost (from server).
    public func record(
        model: String,
        promptTokens: Int,
        completionTokens: Int,
        cost: Double
    ) {
        // Update per-model breakdown
        var usage = sessionUsageByModel[model] ?? TokenUsage()
        usage.promptTokens += promptTokens
        usage.completionTokens += completionTokens
        usage.cost += cost
        sessionUsageByModel[model] = usage
        
        // Update session totals
        sessionCost += cost
        sessionTokens += promptTokens + completionTokens
        
        // Update lifetime totals
        lifetimeCost += cost
        lifetimeTokens += promptTokens + completionTokens
        
        // Deduct from balance (skip when relay is authoritative).
        if !serverManaged {
            balance -= cost
            if balance < 0 { balance = 0 }
        }

        persist()
    }

    // MARK: - Credits
    
    /// Add purchased credits to balance.
    public func addCredits(_ amount: Double) {
        balance += amount
        persist()
    }
    
    // MARK: - Session Management
    
    /// Reset session counters (e.g., on new conversation).
    public func resetSession() {
        sessionCost = 0
        sessionTokens = 0
        sessionUsageByModel = [:]
    }
    
    // MARK: - Status
    
    /// Whether the balance is zero or below.
    public var hasInsufficientBalance: Bool {
        balance <= 0
    }
    
    /// Whether the balance is below the low-balance threshold ($0.50).
    public var isLowBalance: Bool {
        balance < 0.50
    }
    
    // MARK: - Persistence
    
    private func persist() {
        defaults.set(balance, forKey: Self.balanceKey)
        defaults.set(lifetimeCost, forKey: Self.lifetimeCostKey)
        defaults.set(lifetimeTokens, forKey: Self.lifetimeTokensKey)
    }
}
