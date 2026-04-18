import Foundation
import CopilotSDK

public struct AIAppInfoLink: Hashable, Sendable {
    public let title: String
    public let urlString: String
    public let systemImage: String?

    public init(title: String, urlString: String, systemImage: String? = nil) {
        self.title = title
        self.urlString = urlString
        self.systemImage = systemImage
    }

    public var url: URL? {
        URL(string: urlString)
    }
}

public struct AIAppRuntimeConfig: Sendable {
    public static let plistKey = "NeoxAppConfig"

    public let appId: String
    public let stripePaymentURL: String?
    public let stripeVerifyURL: String?
    public let iapPacks: [PaymentManager.CreditPack]
    public let aboutLinks: [AIAppInfoLink]

    public init(
        appId: String = "neox-core",
        stripePaymentURL: String? = nil,
        stripeVerifyURL: String? = nil,
        iapPacks: [PaymentManager.CreditPack] = [],
        aboutLinks: [AIAppInfoLink] = []
    ) {
        self.appId = appId
        self.stripePaymentURL = stripePaymentURL
        self.stripeVerifyURL = stripeVerifyURL
        self.iapPacks = iapPacks
        self.aboutLinks = aboutLinks
    }

    public static func load(from bundle: Bundle = .main) -> AIAppRuntimeConfig {
        guard let raw = bundle.object(forInfoDictionaryKey: plistKey) as? [String: Any] else {
            return AIAppRuntimeConfig()
        }

        let appId = (raw["appId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripePaymentURL = normalizeString(raw["stripePaymentURL"] as? String)
        let stripeVerifyURL = normalizeString(raw["stripeVerifyURL"] as? String)
        let iapPacks = parseIAPPacks(raw["iapPacks"])
        let aboutLinks = parseAboutLinks(raw["aboutLinks"])

        return AIAppRuntimeConfig(
            appId: appId?.isEmpty == false ? appId! : "neox-core",
            stripePaymentURL: stripePaymentURL,
            stripeVerifyURL: stripeVerifyURL,
            iapPacks: iapPacks,
            aboutLinks: aboutLinks
        )
    }

    private static func parseIAPPacks(_ raw: Any?) -> [PaymentManager.CreditPack] {
        guard let packs = raw as? [[String: Any]] else { return [] }

        return packs.compactMap { item in
            guard let productID = normalizeString(item["productID"] as? String) else { return nil }
            let description = normalizeString(item["description"] as? String) ?? ""

            let credits: Double
            if let value = item["credits"] as? NSNumber {
                credits = value.doubleValue
            } else if let value = item["credits"] as? String, let parsed = Double(value) {
                credits = parsed
            } else {
                return nil
            }

            return PaymentManager.CreditPack(productID: productID, credits: credits, description: description)
        }
    }

    private static func parseAboutLinks(_ raw: Any?) -> [AIAppInfoLink] {
        guard let links = raw as? [[String: Any]] else { return [] }

        return links.compactMap { item in
            guard let title = normalizeString(item["title"] as? String),
                  let urlString = normalizeString(item["url"] as? String) else {
                return nil
            }

            return AIAppInfoLink(
                title: title,
                urlString: urlString,
                systemImage: normalizeString(item["systemImage"] as? String)
            )
        }
    }

    private static func normalizeString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}