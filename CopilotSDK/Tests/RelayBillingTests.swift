import XCTest
import CryptoKit
@testable import CopilotSDK

final class RelayBillingTests: XCTestCase {

    /// Round-trip an encrypted trace-id end-to-end so we know the iOS
    /// decryption matches the Node-side relay encryption byte for byte.
    func testDecryptRoundTrip() throws {
        let bearer = "test-bearer-abc"
        let prices = RelayBilling.Prices(input: 0.27, output: 1.10)
        let header = encryptForTest(json: "{\"in\":\(prices.input),\"out\":\(prices.output)}", bearer: bearer)
        XCTAssertEqual(RelayBilling.decryptTraceId(header, bearer: bearer), prices)
    }

    func testWrongBearerReturnsNil() throws {
        let header = encryptForTest(json: "{\"in\":1,\"out\":2}", bearer: "right")
        XCTAssertNil(RelayBilling.decryptTraceId(header, bearer: "wrong"))
    }

    func testLegacyShape() {
        let bearer = "abc"
        let header = encryptForTest(json: "{\"prices\":{\"input\":2.5,\"output\":7.5}}", bearer: bearer)
        let p = RelayBilling.decryptTraceId(header, bearer: bearer)
        XCTAssertEqual(p?.input, 2.5)
        XCTAssertEqual(p?.output, 7.5)
    }

    func testComputeCost() {
        let p = RelayBilling.Prices(input: 0.27, output: 1.10)
        XCTAssertEqual(RelayBilling.computeCost(p, inputTokens: 1_000_000, outputTokens: 1_000_000), 1.37, accuracy: 1e-9)
    }

    // MARK: - Helpers

    /// Encrypt exactly the way the Node relay does: AES-256-GCM, key=SHA256(bearer),
    /// blob=iv(12)||tag(16)||ct, base64url (no padding).
    private func encryptForTest(json: String, bearer: String) -> String {
        let key = SymmetricKey(data: SHA256.hash(data: Data(bearer.utf8)))
        let sealed = try! AES.GCM.seal(Data(json.utf8), using: key)
        var blob = Data()
        blob.append(sealed.nonce.withUnsafeBytes { Data($0) })
        blob.append(sealed.tag)
        blob.append(sealed.ciphertext)
        return blob.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
