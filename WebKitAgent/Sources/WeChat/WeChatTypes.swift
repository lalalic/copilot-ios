import Foundation

// MARK: - Channel State

/// State machine for the WeChat channel lifecycle.
public enum WeChatChannelState: String, Sendable {
    case disconnected    // Channel not started
    case loading         // wx.qq.com loading
    case extractingQR    // Looking for QR code UUID
    case qrReady         // QR code available for scanning
    case loggingIn       // QR scanned, waiting for confirmation
    case ready           // Fully logged in, bridge active
    case dead            // Session expired or error
}

// MARK: - User

/// Logged-in WeChat user info.
public struct WeChatUser: Sendable, Equatable {
    public let id: String
    public let name: String
    public let userName: String

    public init(id: String, name: String, userName: String) {
        self.id = id
        self.name = name
        self.userName = userName
    }
}

// MARK: - Contact

/// A WeChat contact.
public struct WeChatContact: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let userName: String
    public let nickName: String?
    public let remarkName: String?
    public let headImgUrl: String?
    public let isRoom: Bool
    public let sex: Int  // 0=unknown, 1=male, 2=female

    public init(
        id: String, name: String, userName: String,
        nickName: String? = nil, remarkName: String? = nil,
        headImgUrl: String? = nil, isRoom: Bool = false, sex: Int = 0
    ) {
        self.id = id
        self.name = name
        self.userName = userName
        self.nickName = nickName
        self.remarkName = remarkName
        self.headImgUrl = headImgUrl
        self.isRoom = isRoom
        self.sex = sex
    }
}

// MARK: - Message

/// A WeChat message event from the bridge.
public struct WeChatMessage: Sendable {
    public let msgId: String
    public let msgType: Int
    public let content: String
    public let fromUserName: String
    public let toUserName: String
    public let fromContact: WeChatContact?
    public let toContact: WeChatContact?
    public let isRoom: Bool
    public let createTime: Int?
    public let voiceBase64: String?
    public let voiceLength: Int?

    public init(
        msgId: String, msgType: Int, content: String,
        fromUserName: String, toUserName: String,
        fromContact: WeChatContact? = nil, toContact: WeChatContact? = nil,
        isRoom: Bool = false, createTime: Int? = nil,
        voiceBase64: String? = nil, voiceLength: Int? = nil
    ) {
        self.msgId = msgId
        self.msgType = msgType
        self.content = content
        self.fromUserName = fromUserName
        self.toUserName = toUserName
        self.fromContact = fromContact
        self.toContact = toContact
        self.isRoom = isRoom
        self.createTime = createTime
        self.voiceBase64 = voiceBase64
        self.voiceLength = voiceLength
    }

    /// Whether this is a text message (MsgType 1).
    public var isText: Bool { msgType == 1 }

    /// Whether this is a voice message (MsgType 34).
    public var isVoice: Bool { msgType == 34 }

    /// Whether this is an image message (MsgType 3).
    public var isImage: Bool { msgType == 3 }
}

// MARK: - Bridge Event

/// Events emitted by the WechatyBro bridge (polled from JS).
public enum WeChatBridgeEvent: Sendable {
    case scan(code: Int, url: String)
    case login(user: WeChatUser)
    case logout
    case message(WeChatMessage)
    case heartbeat
    case contacts(count: Int)
    case error(String)

    /// Parse from a raw bridge event dictionary.
    public static func parse(_ dict: [String: Any]) -> WeChatBridgeEvent? {
        guard let type = dict["type"] as? String else { return nil }
        let data = dict["data"]

        switch type {
        case "scan":
            guard let scanData = data as? [String: Any],
                  let url = scanData["url"] as? String else { return nil }
            let code = scanData["code"] as? Int ?? 0
            return .scan(code: code, url: url)

        case "login":
            guard let userData = data as? [String: Any] else { return nil }
            let user = WeChatUser(
                id: userData["id"] as? String ?? "",
                name: userData["name"] as? String ?? userData["NickName"] as? String ?? "",
                userName: userData["UserName"] as? String ?? ""
            )
            return .login(user: user)

        case "logout":
            return .logout

        case "message":
            guard let msgData = data as? [String: Any] else { return nil }
            let msg = WeChatMessage(
                msgId: msgData["MsgId"] as? String ?? "",
                msgType: msgData["MsgType"] as? Int ?? 0,
                content: msgData["Content"] as? String ?? "",
                fromUserName: msgData["FromUserName"] as? String ?? "",
                toUserName: msgData["ToUserName"] as? String ?? "",
                fromContact: parseContact(msgData["from"] as? [String: Any]),
                toContact: parseContact(msgData["to"] as? [String: Any]),
                isRoom: msgData["MMIsChatRoom"] as? Bool ?? false,
                createTime: msgData["CreateTime"] as? Int,
                voiceBase64: msgData["voiceBase64"] as? String,
                voiceLength: msgData["voiceLength"] as? Int
            )
            return .message(msg)

        case "heartbeat":
            return .heartbeat

        case "contacts":
            let count = data as? Int ?? 0
            return .contacts(count: count)

        default:
            return nil
        }
    }

    private static func parseContact(_ dict: [String: Any]?) -> WeChatContact? {
        guard let dict else { return nil }
        return WeChatContact(
            id: dict["id"] as? String ?? "",
            name: dict["name"] as? String ?? "",
            userName: dict["UserName"] as? String ?? "",
            nickName: dict["NickName"] as? String,
            remarkName: dict["RemarkName"] as? String,
            headImgUrl: dict["HeadImgUrl"] as? String,
            isRoom: (dict["UserName"] as? String)?.hasPrefix("@@") ?? false,
            sex: dict["Sex"] as? Int ?? 0
        )
    }
}
