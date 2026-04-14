import Testing
import Foundation
@testable import CopilotSDK

// MARK: - Payment Manager Tests

@Suite("PaymentManager")
struct PaymentManagerTests {

    // Helper: create a PaymentManager with Neox-style packs for testing
    private static let testPacks: [PaymentManager.CreditPack] = [
        .init(productID: "com.neox.credits.starter", credits: 3.50, description: "$3.50 credits · ~700K GPT-4.1 tokens"),
        .init(productID: "com.neox.credits.standard", credits: 7.50, description: "$7.50 credits · ~1.5M tokens"),
        .init(productID: "com.neox.credits.pro", credits: 25.00, description: "$25 credits · ~5M tokens"),
    ]

    private static func makeManager() -> PaymentManager {
        PaymentManager(
            usageTracker: UsageTracker(),
            iapPacks: testPacks,
            stripePaymentURL: nil,
            stripeVerifyURL: nil,
            clientID: "test-client"
        )
    }

    // MARK: - Product IDs

    @Test("Product IDs are derived from packs")
    func productIDsAreDefined() {
        let pm = Self.makeManager()
        #expect(pm.productIDs.count == 3)
        #expect(pm.productIDs.contains("com.neox.credits.starter"))
        #expect(pm.productIDs.contains("com.neox.credits.standard"))
        #expect(pm.productIDs.contains("com.neox.credits.pro"))
    }

    // MARK: - Credit Values

    @Test("Credit values are mapped correctly")
    func creditValuesMapped() {
        let pm = Self.makeManager()
        #expect(pm.creditValues["com.neox.credits.starter"] == 3.50)
        #expect(pm.creditValues["com.neox.credits.standard"] == 7.50)
        #expect(pm.creditValues["com.neox.credits.pro"] == 25.00)
    }

    @Test("Credit values have positive amounts")
    func creditValuesPositive() {
        let pm = Self.makeManager()
        for (_, value) in pm.creditValues {
            #expect(value > 0)
        }
    }

    @Test("All product IDs have credit values")
    func allProductsHaveCreditValues() {
        let pm = Self.makeManager()
        for productId in pm.productIDs {
            #expect(pm.creditValues[productId] != nil)
        }
    }

    // MARK: - Credit String

    @Test("creditString formats correctly for starter")
    func creditStringStarter() {
        let pm = Self.makeManager()
        let str = pm.creditString(for: "com.neox.credits.starter")
        #expect(str == "$3.50")
    }

    @Test("creditString formats correctly for standard")
    func creditStringStandard() {
        let pm = Self.makeManager()
        let str = pm.creditString(for: "com.neox.credits.standard")
        #expect(str == "$7.50")
    }

    @Test("creditString formats correctly for pro")
    func creditStringPro() {
        let pm = Self.makeManager()
        let str = pm.creditString(for: "com.neox.credits.pro")
        #expect(str == "$25.00")
    }

    @Test("creditString returns ? for unknown product")
    func creditStringUnknown() {
        let pm = Self.makeManager()
        let str = pm.creditString(for: "com.neox.credits.unknown")
        #expect(str == "?")
    }

    // MARK: - Product Description

    @Test("productDescription for starter")
    func productDescriptionStarter() {
        let pm = Self.makeManager()
        let desc = pm.productDescription(for: "com.neox.credits.starter")
        #expect(desc.contains("700K"))
        #expect(desc.contains("GPT-4.1"))
    }

    @Test("productDescription for standard")
    func productDescriptionStandard() {
        let pm = Self.makeManager()
        let desc = pm.productDescription(for: "com.neox.credits.standard")
        #expect(desc.contains("1.5M"))
    }

    @Test("productDescription for pro")
    func productDescriptionPro() {
        let pm = Self.makeManager()
        let desc = pm.productDescription(for: "com.neox.credits.pro")
        #expect(desc.contains("5M"))
    }

    @Test("productDescription for unknown returns empty")
    func productDescriptionUnknown() {
        let pm = Self.makeManager()
        let desc = pm.productDescription(for: "com.neox.credits.unknown")
        #expect(desc.isEmpty)
    }

    // MARK: - Value Progression

    @Test("Credit value increases with product tier")
    func creditValueProgression() {
        let pm = Self.makeManager()
        let starter = pm.creditValues["com.neox.credits.starter"] ?? 0
        let standard = pm.creditValues["com.neox.credits.standard"] ?? 0
        let pro = pm.creditValues["com.neox.credits.pro"] ?? 0

        #expect(starter < standard)
        #expect(standard < pro)
    }

    // MARK: - Empty Packs

    @Test("Empty packs yields no product IDs")
    func emptyPacks() {
        let pm = PaymentManager(
            usageTracker: UsageTracker(),
            iapPacks: [],
            clientID: "test"
        )
        #expect(pm.productIDs.isEmpty)
        #expect(pm.creditValues.isEmpty)
    }

    // MARK: - Stripe Config

    @Test("Stripe URLs stored correctly")
    func stripeConfig() {
        let pm = PaymentManager(
            usageTracker: UsageTracker(),
            iapPacks: Self.testPacks,
            stripePaymentURL: "https://buy.stripe.com/test",
            stripeVerifyURL: "https://relay.ai.qili2.com/stripe/verify",
            clientID: "test-id"
        )
        #expect(pm.stripePaymentURL == "https://buy.stripe.com/test")
        #expect(pm.stripeVerifyURL == "https://relay.ai.qili2.com/stripe/verify")
        #expect(pm.clientID == "test-id")
    }
}
