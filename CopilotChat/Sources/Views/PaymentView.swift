import SwiftUI
import StoreKit
import CopilotSDK

// MARK: - Payment View

/// View for purchasing credit packs via Apple IAP.
public struct PaymentView: View {
    @ObservedObject var paymentManager: PaymentManager
    @ObservedObject var usageTracker: UsageTracker
    @Environment(\.dismiss) private var dismiss
    
    public init(paymentManager: PaymentManager, usageTracker: UsageTracker) {
        self.paymentManager = paymentManager
        self.usageTracker = usageTracker
    }
    
    public var body: some View {
        NavigationStack {
            List {
                // Balance section
                Section {
                    BalanceCardView(usageTracker: usageTracker)
                }
                
                // Credit topup
                Section("Top Up") {
                    if paymentManager.products.isEmpty {
                        HStack {
                            Spacer()
                            ProgressView("Loading products...")
                            Spacer()
                        }
                    } else {
                        ForEach(paymentManager.products, id: \.id) { product in
                            CreditPackRow(
                                product: product,
                                paymentManager: paymentManager,
                                isPurchasing: paymentManager.isPurchasing
                            ) {
                                Task {
                                    await paymentManager.purchase(product)
                                }
                            }
                        }
                    }
                }
                
                // Error
                if let error = paymentManager.lastError {
                    Section {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                
                // Usage stats
                Section("Usage") {
                    HStack {
                        Text("Session Cost")
                        Spacer()
                        Text(CostCalculator.formatCost(usageTracker.sessionCost))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Lifetime Cost")
                        Spacer()
                        Text(CostCalculator.formatCost(usageTracker.lifetimeCost))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Lifetime Tokens")
                        Spacer()
                        Text("\(usageTracker.lifetimeTokens.formatted())")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                
                // Info
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Credits are non-refundable and stored on this device.")
                            .font(.caption2)
                        Text("Balance does not sync between devices.")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Credits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await paymentManager.loadProducts()
            }
        }
    }
}

// MARK: - Balance Card

private struct BalanceCardView: View {
    @ObservedObject var usageTracker: UsageTracker
    
    var body: some View {
        VStack(spacing: 8) {
            Text("Balance")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            Text(String(format: "$%.2f", usageTracker.balance))
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(balanceColor)
            
            if usageTracker.hasInsufficientBalance {
                Text("Top up to continue using AI models")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if usageTracker.isLowBalance {
                Text("Low balance — consider topping up")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
    
    private var balanceColor: Color {
        if usageTracker.hasInsufficientBalance { return .red }
        if usageTracker.isLowBalance { return .orange }
        return .primary
    }
}

// MARK: - Credit Pack Row

private struct CreditPackRow: View {
    let product: Product
    let paymentManager: PaymentManager
    let isPurchasing: Bool
    let onPurchase: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: iconName)
                .font(.title2)
                .foregroundStyle(iconColor)
                .frame(width: 36)
            
            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(product.displayName)
                    .font(.body)
                    .fontWeight(.semibold)
                
                if let credits = paymentManager.creditValues[product.id] {
                    Text("\(String(format: "$%.2f", credits)) in credits")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                let desc = paymentManager.productDescription(for: product.id)
                if !desc.isEmpty {
                    Text(desc)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            
            Spacer()
            
            // Buy button
            Button(action: onPurchase) {
                if isPurchasing {
                    ProgressView()
                        .frame(width: 70)
                } else {
                    Text(product.displayPrice)
                        .font(.subheadline.weight(.semibold))
                        .frame(minWidth: 60)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.blue)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
            }
            .disabled(isPurchasing)
        }
        .padding(.vertical, 4)
    }
    
    private var iconName: String {
        return "plus.circle.fill"
    }
    
    private var iconColor: Color {
        return .green
    }
}

// MARK: - Low Balance Banner

/// A banner view to show when balance is low. Place above chat input.
public struct LowBalanceBannerView: View {
    @ObservedObject var usageTracker: UsageTracker
    let onTapTopUp: () -> Void
    
    public init(usageTracker: UsageTracker, onTapTopUp: @escaping () -> Void) {
        self.usageTracker = usageTracker
        self.onTapTopUp = onTapTopUp
    }
    
    public var body: some View {
        if usageTracker.hasInsufficientBalance {
            Button(action: onTapTopUp) {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text("No credits remaining")
                        .font(.caption.weight(.medium))
                    Spacer()
                    Text("Top Up")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.blue)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.red.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
        } else if usageTracker.isLowBalance {
            Button(action: onTapTopUp) {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Low balance: \(String(format: "$%.2f", usageTracker.balance))")
                        .font(.caption.weight(.medium))
                    Spacer()
                    Text("Top Up")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.blue)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.orange.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
        }
    }
}
