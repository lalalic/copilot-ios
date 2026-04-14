import Foundation
import StoreKit

// MARK: - PaymentManager

/// Manages credit purchases via Apple IAP and Stripe.
/// Host app configures SKUs and Stripe URL at init time.
public class PaymentManager: ObservableObject, @unchecked Sendable {
    
    // MARK: - Published State
    
    @Published public private(set) var products: [Product] = []
    @Published public private(set) var isPurchasing: Bool = false
    @Published public private(set) var lastError: String?
    
    // MARK: - Configuration
    
    /// A credit pack definition — maps a product ID to its credit value.
    public struct CreditPack: Sendable {
        public let productID: String
        public let credits: Double
        public let description: String
        
        public init(productID: String, credits: Double, description: String = "") {
            self.productID = productID
            self.credits = credits
            self.description = description
        }
    }
    
    /// Apple IAP credit packs configured by the host app.
    public let iapPacks: [CreditPack]
    
    /// Stripe payment link URL (nil = Stripe disabled).
    /// Should include `{CLIENT_ID}` placeholder for client_reference_id substitution.
    public let stripePaymentURL: String?
    
    /// Stripe relay verification URL (e.g., "https://relay.ai.qili2.com/stripe/verify").
    public let stripeVerifyURL: String?
    
    /// Client ID for Stripe (typically device UUID).
    public let clientID: String
    
    /// Lookup: product ID → credit value.
    public var creditValues: [String: Double] {
        var map: [String: Double] = [:]
        for pack in iapPacks {
            map[pack.productID] = pack.credits
        }
        return map
    }
    
    // MARK: - Backward Compatibility
    
    /// Product IDs for StoreKit fetch.
    public var productIDs: Set<String> {
        Set(iapPacks.map(\.productID))
    }
    
    // MARK: - Dependencies
    
    private let usageTracker: UsageTracker
    private var transactionListener: Task<Void, Never>?
    
    // MARK: - Init
    
    /// Create a PaymentManager with configurable packs and optional Stripe support.
    /// - Parameters:
    ///   - usageTracker: The usage tracker for crediting balance.
    ///   - iapPacks: Apple IAP credit packs (product IDs + credit values).
    ///   - stripePaymentURL: Stripe Payment Link URL template (nil to disable).
    ///   - stripeVerifyURL: Relay endpoint for verifying Stripe sessions.
    ///   - clientID: Device/user identifier for Stripe client_reference_id.
    /// Default device identifier for Stripe client reference.
    private static let defaultClientID: String = {
        // Evaluated once at class load time — safe outside main actor.
        UUID().uuidString
    }()

    public init(
        usageTracker: UsageTracker,
        iapPacks: [CreditPack] = [],
        stripePaymentURL: String? = nil,
        stripeVerifyURL: String? = nil,
        clientID: String? = nil
    ) {
        self.usageTracker = usageTracker
        self.iapPacks = iapPacks
        self.stripePaymentURL = stripePaymentURL
        self.stripeVerifyURL = stripeVerifyURL
        self.clientID = clientID ?? Self.defaultClientID
        transactionListener = listenForTransactions()
    }
    
    deinit {
        transactionListener?.cancel()
    }
    
    // MARK: - Load Products
    
    /// Fetch products from App Store Connect.
    public func loadProducts() async {
        guard !productIDs.isEmpty else { return }
        do {
            let storeProducts = try await Product.products(for: productIDs)
            products = storeProducts.sorted {
                ($0.price as NSDecimalNumber).doubleValue < ($1.price as NSDecimalNumber).doubleValue
            }
            lastError = nil
        } catch {
            lastError = "Failed to load products: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Apple IAP Purchase
    
    /// Purchase a product and add credits to balance.
    @MainActor
    public func purchase(_ product: Product) async {
        isPurchasing = true
        lastError = nil
        defer { isPurchasing = false }
        
        do {
            let result = try await product.purchase()
            
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                
                if let credits = creditValues[product.id] {
                    usageTracker.addCredits(credits)
                }
                
                await transaction.finish()
                
            case .userCancelled:
                break
                
            case .pending:
                lastError = "Purchase is pending approval"
                
            @unknown default:
                lastError = "Unknown purchase result"
            }
        } catch {
            lastError = "Purchase failed: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Stripe
    
    /// Whether Stripe checkout is available.
    public var isStripeEnabled: Bool {
        stripePaymentURL != nil
    }
    
    /// Build the Stripe checkout URL with client reference ID.
    public func stripeCheckoutURL() -> URL? {
        guard let template = stripePaymentURL else { return nil }
        let urlString = template.replacingOccurrences(of: "{CLIENT_ID}", with: clientID)
        return URL(string: urlString)
    }
    
    /// Verify a Stripe session after redirect and grant credits.
    /// Call this from your deep link handler.
    @MainActor
    public func verifyStripeSession(sessionID: String) async -> Bool {
        guard let verifyURL = stripeVerifyURL,
              let url = URL(string: verifyURL) else { return false }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["session_id": sessionID])
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  response["ok"] as? Bool == true,
                  let productId = response["productId"] as? String else {
                return false
            }
            
            if let credits = creditValues[productId] {
                usageTracker.addCredits(credits)
                return true
            }
        } catch {
            lastError = "Stripe verification failed: \(error.localizedDescription)"
        }
        return false
    }
    
    /// Check for pending Stripe sessions on foreground resume.
    @MainActor
    public func checkPendingStripeSession() async -> Bool {
        guard let verifyURL = stripeVerifyURL,
              let url = URL(string: verifyURL) else { return false }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["client_reference_id": clientID])
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  response["ok"] as? Bool == true,
                  response["duplicate"] as? Bool != true,
                  let productId = response["productId"] as? String else {
                return false
            }
            
            if let credits = creditValues[productId] {
                usageTracker.addCredits(credits)
                return true
            }
        } catch {
            // Silent — this is a background check
        }
        return false
    }
    
    // MARK: - Transaction Listener
    
    private func listenForTransactions() -> Task<Void, Never> {
        Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                do {
                    let transaction = try self.checkVerified(result)
                    
                    if let credits = self.creditValues[transaction.productID] {
                        await MainActor.run {
                            self.usageTracker.addCredits(credits)
                        }
                    }
                    
                    await transaction.finish()
                } catch {
                    // Verification failed — skip
                }
            }
        }
    }
    
    // MARK: - Verification
    
    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw error
        case .verified(let safe):
            return safe
        }
    }
    
    // MARK: - Helpers
    
    /// Formatted credit value for a product.
    public func creditString(for productId: String) -> String {
        guard let credits = creditValues[productId] else { return "?" }
        return String(format: "$%.2f", credits)
    }
    
    /// Human-readable description of what a product gives.
    public func productDescription(for productId: String) -> String {
        iapPacks.first { $0.productID == productId }?.description ?? ""
    }
}
