import Testing
import Foundation
@testable import CopilotSDK

// MARK: - Payment Manager Tests

@Suite("PaymentManager")
struct PaymentManagerTests {
    
    // MARK: - Product IDs
    
    @Test("Product IDs are defined")
    func productIDsAreDefined() {
        #expect(PaymentManager.productIDs.count == 3)
        #expect(PaymentManager.productIDs.contains("com.neox.credits.starter"))
        #expect(PaymentManager.productIDs.contains("com.neox.credits.standard"))
        #expect(PaymentManager.productIDs.contains("com.neox.credits.pro"))
    }
    
    // MARK: - Credit Values
    
    @Test("Credit values are mapped correctly")
    func creditValuesMapped() {
        #expect(PaymentManager.creditValues["com.neox.credits.starter"] == 3.50)
        #expect(PaymentManager.creditValues["com.neox.credits.standard"] == 7.50)
        #expect(PaymentManager.creditValues["com.neox.credits.pro"] == 25.00)
    }
    
    @Test("Credit values have positive amounts")
    func creditValuesPositive() {
        for (_, value) in PaymentManager.creditValues {
            #expect(value > 0)
        }
    }
    
    @Test("All product IDs have credit values")
    func allProductsHaveCreditValues() {
        for productId in PaymentManager.productIDs {
            #expect(PaymentManager.creditValues[productId] != nil)
        }
    }
    
    // MARK: - Credit String
    
    @Test("creditString formats correctly for starter")
    func creditStringStarter() {
        let str = PaymentManager.creditString(for: "com.neox.credits.starter")
        #expect(str == "$3.50")
    }
    
    @Test("creditString formats correctly for standard")
    func creditStringStandard() {
        let str = PaymentManager.creditString(for: "com.neox.credits.standard")
        #expect(str == "$7.50")
    }
    
    @Test("creditString formats correctly for pro")
    func creditStringPro() {
        let str = PaymentManager.creditString(for: "com.neox.credits.pro")
        #expect(str == "$25.00")
    }
    
    @Test("creditString returns ? for unknown product")
    func creditStringUnknown() {
        let str = PaymentManager.creditString(for: "com.neox.credits.unknown")
        #expect(str == "?")
    }
    
    // MARK: - Product Description
    
    @Test("productDescription for starter")
    func productDescriptionStarter() {
        let desc = PaymentManager.productDescription(for: "com.neox.credits.starter")
        #expect(desc.contains("700K"))
        #expect(desc.contains("GPT-4.1"))
    }
    
    @Test("productDescription for standard")
    func productDescriptionStandard() {
        let desc = PaymentManager.productDescription(for: "com.neox.credits.standard")
        #expect(desc.contains("1.5M"))
    }
    
    @Test("productDescription for pro")
    func productDescriptionPro() {
        let desc = PaymentManager.productDescription(for: "com.neox.credits.pro")
        #expect(desc.contains("5M"))
    }
    
    @Test("productDescription for unknown returns empty")
    func productDescriptionUnknown() {
        let desc = PaymentManager.productDescription(for: "com.neox.credits.unknown")
        #expect(desc.isEmpty)
    }
    
    // MARK: - Value Progression
    
    @Test("Credit value increases with product tier")
    func creditValueProgression() {
        let starter = PaymentManager.creditValues["com.neox.credits.starter"] ?? 0
        let standard = PaymentManager.creditValues["com.neox.credits.standard"] ?? 0
        let pro = PaymentManager.creditValues["com.neox.credits.pro"] ?? 0
        
        #expect(starter < standard)
        #expect(standard < pro)
    }
}
