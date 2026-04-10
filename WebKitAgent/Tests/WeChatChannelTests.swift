import XCTest
@testable import WebKitAgent

// MARK: - WeChatTypes Tests

final class WeChatTypesTests: XCTestCase {

    // MARK: - ChannelState

    func testChannelStateRawValues() {
        XCTAssertEqual(WeChatChannelState.disconnected.rawValue, "disconnected")
        XCTAssertEqual(WeChatChannelState.loading.rawValue, "loading")
        XCTAssertEqual(WeChatChannelState.qrReady.rawValue, "qrReady")
        XCTAssertEqual(WeChatChannelState.loggingIn.rawValue, "loggingIn")
        XCTAssertEqual(WeChatChannelState.ready.rawValue, "ready")
        XCTAssertEqual(WeChatChannelState.dead.rawValue, "dead")
    }

    // MARK: - WeChatUser

    func testWeChatUserEquality() {
        let user1 = WeChatUser(id: "abc", name: "Test", userName: "@abc123")
        let user2 = WeChatUser(id: "abc", name: "Test", userName: "@abc123")
        XCTAssertEqual(user1, user2)
    }

    func testWeChatUserInequality() {
        let user1 = WeChatUser(id: "abc", name: "Test1", userName: "@abc")
        let user2 = WeChatUser(id: "abc", name: "Test2", userName: "@abc")
        XCTAssertNotEqual(user1, user2)
    }

    // MARK: - WeChatContact

    func testWeChatContactDefaults() {
        let contact = WeChatContact(id: "test", name: "Test", userName: "@test")
        XCTAssertNil(contact.nickName)
        XCTAssertNil(contact.remarkName)
        XCTAssertNil(contact.headImgUrl)
        XCTAssertFalse(contact.isRoom)
        XCTAssertEqual(contact.sex, 0)
    }

    func testWeChatContactEquality() {
        let c1 = WeChatContact(id: "a", name: "A", userName: "@a")
        let c2 = WeChatContact(id: "a", name: "A", userName: "@a")
        XCTAssertEqual(c1, c2)
    }

    func testWeChatContactIdentifiable() {
        let contact = WeChatContact(id: "myid", name: "Test", userName: "@test")
        XCTAssertEqual(contact.id, "myid")
    }

    // MARK: - WeChatMessage

    func testMessageTypeChecks() {
        let textMsg = WeChatMessage(msgId: "1", msgType: 1, content: "hi", fromUserName: "@a", toUserName: "@b")
        XCTAssertTrue(textMsg.isText)
        XCTAssertFalse(textMsg.isVoice)
        XCTAssertFalse(textMsg.isImage)

        let voiceMsg = WeChatMessage(msgId: "2", msgType: 34, content: "", fromUserName: "@a", toUserName: "@b")
        XCTAssertFalse(voiceMsg.isText)
        XCTAssertTrue(voiceMsg.isVoice)

        let imgMsg = WeChatMessage(msgId: "3", msgType: 3, content: "", fromUserName: "@a", toUserName: "@b")
        XCTAssertTrue(imgMsg.isImage)
    }

    func testMessageDefaultOptionals() {
        let msg = WeChatMessage(msgId: "1", msgType: 1, content: "test", fromUserName: "@a", toUserName: "@b")
        XCTAssertNil(msg.fromContact)
        XCTAssertNil(msg.toContact)
        XCTAssertFalse(msg.isRoom)
        XCTAssertNil(msg.createTime)
        XCTAssertNil(msg.voiceBase64)
        XCTAssertNil(msg.voiceLength)
    }

    // MARK: - BridgeEvent Parsing

    func testParseScanEvent() {
        let dict: [String: Any] = ["type": "scan", "data": ["code": 408, "url": "https://login.weixin.qq.com/l/abc123"]]
        let event = WeChatBridgeEvent.parse(dict)
        if case .scan(let code, let url) = event {
            XCTAssertEqual(code, 408)
            XCTAssertEqual(url, "https://login.weixin.qq.com/l/abc123")
        } else {
            XCTFail("Expected scan event, got \(String(describing: event))")
        }
    }

    func testParseLoginEvent() {
        let dict: [String: Any] = ["type": "login", "data": ["id": "test", "name": "Test User", "UserName": "@abc"]]
        let event = WeChatBridgeEvent.parse(dict)
        if case .login(let user) = event {
            XCTAssertEqual(user.id, "test")
            XCTAssertEqual(user.name, "Test User")
            XCTAssertEqual(user.userName, "@abc")
        } else {
            XCTFail("Expected login event")
        }
    }

    func testParseLogoutEvent() {
        let dict: [String: Any] = ["type": "logout", "data": NSNull()]
        let event = WeChatBridgeEvent.parse(dict)
        if case .logout = event {
            // OK
        } else {
            XCTFail("Expected logout event")
        }
    }

    func testParseMessageEvent() {
        let dict: [String: Any] = [
            "type": "message",
            "data": [
                "MsgId": "msg123",
                "MsgType": 1,
                "Content": "Hello!",
                "FromUserName": "@sender",
                "ToUserName": "@receiver",
                "from": ["id": "s", "name": "Sender", "UserName": "@sender"],
                "to": ["id": "r", "name": "Receiver", "UserName": "@receiver"]
            ] as [String: Any]
        ]
        let event = WeChatBridgeEvent.parse(dict)
        if case .message(let msg) = event {
            XCTAssertEqual(msg.msgId, "msg123")
            XCTAssertEqual(msg.msgType, 1)
            XCTAssertEqual(msg.content, "Hello!")
            XCTAssertEqual(msg.fromContact?.name, "Sender")
            XCTAssertEqual(msg.toContact?.name, "Receiver")
        } else {
            XCTFail("Expected message event")
        }
    }

    func testParseHeartbeatEvent() {
        let dict: [String: Any] = ["type": "heartbeat", "data": "heartbeat@browser"]
        let event = WeChatBridgeEvent.parse(dict)
        if case .heartbeat = event {
            // OK
        } else {
            XCTFail("Expected heartbeat event")
        }
    }

    func testParseContactsEvent() {
        let dict: [String: Any] = ["type": "contacts", "data": 42]
        let event = WeChatBridgeEvent.parse(dict)
        if case .contacts(let count) = event {
            XCTAssertEqual(count, 42)
        } else {
            XCTFail("Expected contacts event")
        }
    }

    func testParseUnknownEventReturnsNil() {
        let dict: [String: Any] = ["type": "unknown_event", "data": NSNull()]
        let event = WeChatBridgeEvent.parse(dict)
        XCTAssertNil(event)
    }

    func testParseMissingTypeReturnsNil() {
        let dict: [String: Any] = ["data": "something"]
        let event = WeChatBridgeEvent.parse(dict)
        XCTAssertNil(event)
    }
}

// MARK: - WeChatBridge Tests

final class WeChatBridgeTests: XCTestCase {

    func testInjectScriptNotEmpty() {
        XCTAssertFalse(WeChatBridge.injectScript.isEmpty)
    }

    func testInjectScriptContainsWechatyBro() {
        XCTAssertTrue(WeChatBridge.injectScript.contains("WechatyBro"))
    }

    func testBridgeSourceContainsMessageHandler() {
        XCTAssertTrue(WeChatBridge.bridgeSource.contains("messageHandlers.wechatEvent"))
    }

    func testBridgeSourceContainsPostMessage() {
        XCTAssertTrue(WeChatBridge.bridgeSource.contains("postMessage"))
    }

    func testBridgeSourceContainsSendToPuppeteer() {
        XCTAssertTrue(WeChatBridge.bridgeSource.contains("sendToPuppeteer"))
    }

    func testInjectScriptContainsWechatyBro2() {
        XCTAssertTrue(WeChatBridge.injectScript.contains("WechatyBro"))
    }
}

// MARK: - WeChatBridge Tests

@MainActor
final class WeChatBridgeTests: XCTestCase {

    func testInitialState() {
        let bridge = WeChatBridge()
        XCTAssertEqual(bridge.state, .disconnected)
        XCTAssertNil(bridge.qrCodeURL)
        XCTAssertNil(bridge.loggedInUser)
        XCTAssertTrue(bridge.contacts.isEmpty)
        XCTAssertEqual(bridge.messageCount, 0)
    }

    func testStartChangesStateToLoading() {
        let bridge = WeChatBridge()
        bridge.start()
        XCTAssertEqual(bridge.state, .loading)
    }

    func testStartFromDeadState() {
        let bridge = WeChatBridge()
        bridge.start()
        bridge.destroy()
        XCTAssertEqual(bridge.state, .disconnected)
        bridge.start()
        XCTAssertEqual(bridge.state, .loading)
    }

    func testDestroyResetsState() {
        let bridge = WeChatBridge()
        bridge.start()
        bridge.destroy()
        XCTAssertEqual(bridge.state, .disconnected)
        XCTAssertNil(bridge.qrCodeURL)
        XCTAssertNil(bridge.loggedInUser)
        XCTAssertTrue(bridge.contacts.isEmpty)
        XCTAssertEqual(bridge.messageCount, 0)
    }

    func testSendMessageRejectsWhenNotReady() async {
        let bridge = WeChatBridge()
        let result = await bridge.sendMessage(to: "@test", content: "hi")
        XCTAssertFalse(result)
    }

    func testGetContactsReturnsEmptyWhenNotReady() async {
        let bridge = WeChatBridge()
        let contacts = await bridge.getContacts()
        XCTAssertTrue(contacts.isEmpty)
    }

    func testRestartGoesToLoading() {
        let bridge = WeChatBridge()
        bridge.start()
        bridge.restart()
        XCTAssertEqual(bridge.state, .loading)
    }

    func testDoubleStartIgnored() {
        let bridge = WeChatBridge()
        bridge.start()
        XCTAssertEqual(bridge.state, .loading)
        bridge.start()
        XCTAssertEqual(bridge.state, .loading)
    }
}

// MARK: - WeChatRouter Tests

@MainActor
final class WeChatRouterTests: XCTestCase {

    func testInitialBindingsEmpty() {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let router = WeChatRouter(storageDirectory: tmpDir)
        XCTAssertTrue(router.bindings.isEmpty)
    }

    func testBindContact() {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let router = WeChatRouter(storageDirectory: tmpDir)
        router.bind(contactUserName: "@abc", contactName: "Alice", sessionId: "session1")
        XCTAssertEqual(router.bindings.count, 1)
        XCTAssertEqual(router.bindings[0].contactUserName, "@abc")
        XCTAssertEqual(router.bindings[0].sessionId, "session1")
    }

    func testBindReplacesExisting() {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let router = WeChatRouter(storageDirectory: tmpDir)
        router.bind(contactUserName: "@abc", contactName: "Alice", sessionId: "s1")
        router.bind(contactUserName: "@abc", contactName: "Alice", sessionId: "s2")
        XCTAssertEqual(router.bindings.count, 1)
        XCTAssertEqual(router.bindings[0].sessionId, "s2")
    }

    func testUnbind() {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let router = WeChatRouter(storageDirectory: tmpDir)
        router.bind(contactUserName: "@abc", contactName: "Alice", sessionId: "s1")
        router.unbind(contactUserName: "@abc")
        XCTAssertTrue(router.bindings.isEmpty)
    }

    func testRouteBoundContact() {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let router = WeChatRouter(storageDirectory: tmpDir)
        router.bind(contactUserName: "@abc", contactName: "Alice", sessionId: "session1")

        let alice = WeChatContact(id: "alice", name: "Alice", userName: "@abc")
        let msg = WeChatMessage(msgId: "1", msgType: 1, content: "hi", fromUserName: "@abc", toUserName: "@me", fromContact: alice)
        let result = router.route(msg)

        if case .bound(let sessionId, let name) = result {
            XCTAssertEqual(sessionId, "session1")
            XCTAssertEqual(name, "Alice")
        } else {
            XCTFail("Expected bound route")
        }
    }

    func testRouteWorkspaceContact() {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let router = WeChatRouter(storageDirectory: tmpDir)
        router.bindToWorkspace(contactUserName: "@xyz", contactName: "Bob", workspace: "my-project")

        let bob = WeChatContact(id: "bob", name: "Bob", userName: "@xyz")
        let msg = WeChatMessage(msgId: "2", msgType: 1, content: "hey", fromUserName: "@xyz", toUserName: "@me", fromContact: bob)
        let result = router.route(msg)

        if case .workspace(let ws, let name) = result {
            XCTAssertEqual(ws, "my-project")
            XCTAssertEqual(name, "Bob")
        } else {
            XCTFail("Expected workspace route")
        }
    }

    func testRouteUnknownContact() {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let router = WeChatRouter(storageDirectory: tmpDir)
        let msg = WeChatMessage(msgId: "3", msgType: 1, content: "hello?", fromUserName: "@unknown", toUserName: "@me")
        let result = router.route(msg)

        if case .unrouted = result {
            XCTAssertEqual(router.unroutedMessages.count, 1)
        } else {
            XCTFail("Expected unrouted result")
        }
    }

    func testClearUnrouted() {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let router = WeChatRouter(storageDirectory: tmpDir)
        let msg = WeChatMessage(msgId: "3", msgType: 1, content: "test", fromUserName: "@x", toUserName: "@me")
        _ = router.route(msg)
        XCTAssertEqual(router.unroutedMessages.count, 1)
        router.clearUnrouted()
        XCTAssertTrue(router.unroutedMessages.isEmpty)
    }

    func testGetBinding() {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let router = WeChatRouter(storageDirectory: tmpDir)
        router.bind(contactUserName: "@abc", contactName: "Alice", sessionId: "s1")
        let binding = router.getBinding(for: "@abc")
        XCTAssertNotNil(binding)
        XCTAssertEqual(binding?.contactName, "Alice")
    }

    func testGetBindingReturnsNilForUnbound() {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let router = WeChatRouter(storageDirectory: tmpDir)
        XCTAssertNil(router.getBinding(for: "@nonexistent"))
    }

    func testBindingsPersistence() {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Write bindings
        let router1 = WeChatRouter(storageDirectory: tmpDir)
        router1.bind(contactUserName: "@abc", contactName: "Alice", sessionId: "s1")
        router1.bind(contactUserName: "@def", contactName: "Bob", sessionId: "s2")

        // Read bindings in new instance
        let router2 = WeChatRouter(storageDirectory: tmpDir)
        XCTAssertEqual(router2.bindings.count, 2)
    }
}
