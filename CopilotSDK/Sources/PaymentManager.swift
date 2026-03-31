import Foundation
import StoreKit

// MARK: - PaymentManager

/// Manages Apple IAP credit purchases using StoreKit 2.
/// Credits are consumable products that add to the local balance.
public class PaymentManager: ObservableObject, @unchecked Sendable {
    
    // MARK: - Published State
    
    @Published public private(set) var products: [Product] = []
    @Published public private(set) var isPurchasing: Bool = false
    @Published public private(set) var lastError: String?
    
    // MARK: - Product IDs
    
    public static let productIDs: Set<String> = [
        "com.neox.credits.starter",   // $4.99 → $3.50 credits
        "com.neox.credits.standard",  // $9.99 → $7.50 credits
        "com.neox.credits.pro",       // $29.99 → $25.00 credits
    ]
    
    /// How much credit (in USD equivalent) each product grants.
    public static let creditValues: [String: Double] = [
        "com.neox.credits.starter": 3.50,
        "com.neox.credits.standard": 7.50,
        "com.neox.credits.pro": 25.00,
    ]
    
    // MARK: - Dependencies
    
    private let usageTracker: UsageTracker
    private var transactionListener: Task<Void, Never>?
    
    // MARK: - Init
    
    public init(usageTracker: UsageTracker) {
        self.usageTracker = usageTracker
        transactionListener = listenForTransactions()
    }
    
    deinit {
        transactionListener?.cancel()
    }
    
    // MARK: - Load Products
    
    /// Fetch products from App Store Connect.
    public func loadProducts() async {
        do {
            let storeProducts = try await Product.products(for: Self.productIDs)
            products = storeProducts.sorted {
                ($0.price as NSDecimalNumber).doubleValue < ($1.price as NSDecimalNumber).doubleValue
            }
            lastError = nil
        } catch {
            lastError = "Failed to load products: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Purchase
    
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
                
                // Add credits to balance
                if let credits = Self.creditValues[product.id] {
                    usageTracker.addCredits(credits)
                }
                
                // Finish the transaction
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
    
    // MARK: - Transaction Listener
    
    /// Listen for transaction updates (e.g., pending purchases that complete later).
    private func listenForTransactions() -> Task<Void, Never> {
        Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                do {
                    let transaction = try self.checkVerified(result)
                    
                    // Add credits if not already credited
                    if let credits = Self.creditValues[transaction.productID] {
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
    public static func creditString(for productId: String) -> String {
        guard let credits = creditValues[productId] else { return "?" }
        return String(format: "$%.2f", credits)
    }
    
    /// Human-readable description of what a product gives.
    public static func productDescription(for productId: String) -> String {
        switch productId {
        case "com.neox.credits.starter":
            return "~700K tokens on GPT-4.1"
        case "com.neox.credits.standard":
            return "~1.5M tokens on GPT-4.1"
        case "com.neox.credits.pro":
            return "~5M tokens on GPT-4.1"
        default:
            return ""
        }
    }
}
