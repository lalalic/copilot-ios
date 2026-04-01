# Site Auth & WeChat Channel — Design v2

## Overview

Two tiers of site integration in Neox iPhone app:

1. **Site Auth** — Cookie-based login for content sites (XHS, Twitter, Bilibili, etc.). Agent navigates to login page → user logs in manually → cookies persist → adapters work.

2. **WeChat Channel** — Persistent bidirectional bridge. WeChat Web runs in background WKWebView with WechatyBro injection. Contacts message the AI, AI replies through WeChat.

---

## Tier 1: Site Auth (Cookie Login)

### Architecture

```
┌─────────────────────────────────────────┐
│  Neox iPhone App                        │
│                                         │
│  ┌─────────────┐   ┌────────────────┐   │
│  │ Browser Tab  │   │  Site Adapters │   │
│  │ (WKWebView)  │◄──│  (JS scripts)  │   │
│  │              │   │                │   │
│  │  User types  │   │  Use same      │   │
│  │  credentials │   │  cookie jar    │   │
│  └──────┬───────┘   └────────┬───────┘   │
│         │                    │           │
│         ▼                    ▼           │
│  ┌─────────────────────────────────┐     │
│  │   WKWebsiteDataStore.default()  │     │
│  │   Persistent cookie jar         │     │
│  │   Shared across all requests    │     │
│  └─────────────────────────────────┘     │
└─────────────────────────────────────────┘
```

### Flow

1. `site action=sessions` → shows login status for all known sites
2. `site action=login site=xiaohongshu` → navigates to login page in browser tab
3. User enters credentials or scans QR code
4. `site action=auth_check site=xiaohongshu` → checks for `web_session` cookie → "logged in"
5. `site action=explore site=xiaohongshu` → adapter runs JS with full auth cookies

### Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| User Agent | Desktop Safari (always) | Sites show full-featured pages; QR login works for most sites |
| Login detection | Manual (agent checks via auth_check) | Simplest; no polling or observation needed |
| Cookie check | Look for known cookie names per site | More reliable than DOM check; works when not on the site |
| Auth gate | Before adapter JS execution | Early failure with helpful login instructions |
| Logout | Delete all cookies for domain | Clean slate for re-login |

### Known Sites (v1)

| Site | Login URL | Auth Cookie(s) | Adapters |
|---|---|---|---|
| xiaohongshu | xiaohongshu.com/login | `web_session` | explore, search, profile, post |
| twitter | x.com/i/flow/login | `ct0`, `auth_token` | (future) |
| bilibili | passport.bilibili.com/login | `SESSDATA` | (future) |
| zhihu | zhihu.com/signin | `z_c0` | (future) |
| weibo | passport.weibo.com/signin/login | `SUB` | (future) |
| github | github.com/login | `user_session` | (future) |
| reddit | reddit.com/login | `reddit_session` | (future) |
| douyin | douyin.com | (TBD) | (future) |
| youtube | accounts.google.com/signin | (TBD) | (future) |

### What's Built

- `WebViewManager.swift` — `getCookies`, `checkAuth`, `sessionStatus`, `clearCookies`
- `WebAgentToolProvider.swift` — `login`/`logout`/`auth_check`/`sessions` dispatch, auth gate in `executeBrowserAdapter`
- `AdapterRegistry.swift` — 4 XHS adapters (explore/search/profile/post)
- Skill prompt updated with auth commands

### Open Issues

1. **XHS DOM selectors untested** — The JS scripts in explore/search adapters use CSS selectors that may be wrong. Need to test against the real site.
2. **Cookie expiry** — We check presence but not expiry. Some sites rotate session cookies. Low priority for v1.
3. **QR code login on iPhone** — XHS shows QR on desktop login. Since we use desktop UA, user sees QR. They can scan with XHS app on the same phone (deep link `xhsdiscover://`), or use phone number login if available on the page.

---

## Tier 2: WeChat as Bidirectional Channel

### Prior Art: bullx (Electron Desktop)

bullx's `wechat.ts` (929 lines) runs WeChat Web in a hidden Electron `WebContentsView`:

- **Persistent session**: `session.fromPartition('persist:wechat')` keeps cookies across app launches
- **WechatyBro injection**: Hooks AngularJS internals (`contactFactory`, `chatFactory`, `rootScope.$on`)
- **CDP QR interception**: Intercepts `login.weixin.qq.com/jslogin` network requests to extract login UUID
- **Message bridge**: Injected code pushes events to `window.__wechatBridge`, main process polls every 500ms
- **Contact router**: 3-tier routing (bound session → workspace → unrouted) routes WeChat messages to Copilot sessions
- **Send API**: `sendMessage(to, content)` calls `WechatyBro.send()` → `chatFactory.sendMessage()`
- **Voice transcription**: Captures base64 AMR audio, converts via ffmpeg, transcribes via whisper
- **Heartbeat/auto-refresh**: Monitors bridge liveness, auto-refreshes expired QR codes

### The Same-Device QR Problem

wx.qq.com login shows a QR code. On desktop, you scan it with WeChat on your phone. But on the iPhone, WeChat is on the same device.

**Solution: Display QR code in Neox UI for scanning from another device.**

```
iPhone (Neox)                           Another device (iPad/phone/Mac)
┌──────────────────┐                    ┌──────────────────┐
│ WKWebView loads   │                    │                  │
│ wx.qq.com (hidden)│                    │                  │
│                   │                    │                  │
│ Extract UUID from │                    │                  │
│ login page via JS │                    │                  │
│                   │                    │                  │
│ Render QR code:   │   User scans with  │  WeChat app      │
│ ┌──────────┐     │   WeChat on ──────►│  confirms login  │
│ │ QR CODE  │     │   another device    │                  │
│ │ login.   │     │                    │                  │
│ │ weixin.  │     │                    │                  │
│ │ qq.com/l/│     │                    │                  │
│ │ UUID     │     │                    │                  │
│ └──────────┘     │                    │                  │
│                   │                    │                  │
│ wx.qq.com detects │                    │                  │
│ login success →   │                    │                  │
│ inject bridge →   │                    │                  │
│ channel is live!  │                    │                  │
└──────────────────┘                    └──────────────────┘
```

The iPhone acts as the "desktop" running WeChat Web. The QR code is displayed in the Neox app UI for any other device with WeChat to scan.

### UI: WeChat Toggle Button

A WeChat button in the top navigation bar enables/disables the channel:

```
┌─────────────────────────────────────────────┐
│  ◀  Neox            [WeChat 💬]  [⚙]  [+]  │
│─────────────────────────────────────────────│
│                                             │
│  Chat / Browser / etc.                      │
│                                             │
└─────────────────────────────────────────────┘
```

**Button states:**

| State | Icon | Tap Action |
|---|---|---|
| Off (channel disabled) | `💬` (gray) | Start WeChat channel → show QR code |
| QR shown (waiting for scan) | `💬` (yellow pulse) | Show/hide QR overlay |
| Logged in (channel active) | `💬` (green dot) | Show WeChat status / contacts |
| Error / disconnected | `💬` (red) | Retry connection |

**QR code overlay** — When user taps the WeChat button and channel is not logged in:

```
┌─────────────────────────────────────────────┐
│  ◀  Neox            [WeChat 💬]  [⚙]  [+]  │
│─────────────────────────────────────────────│
│                                             │
│     ┌─────────────────────────────────┐     │
│     │                                 │     │
│     │         ┌───────────┐           │     │
│     │         │  QR CODE  │           │     │
│     │         │           │           │     │
│     │         │  Scan with│           │     │
│     │         │  WeChat on│           │     │
│     │         │  another  │           │     │
│     │         │  device   │           │     │
│     │         └───────────┘           │     │
│     │                                 │     │
│     │   Scan this code with WeChat    │     │
│     │   on your iPad, Mac, or         │     │
│     │   another phone to connect.     │     │
│     │                                 │     │
│     │        [Disable WeChat]         │     │
│     └─────────────────────────────────┘     │
│                                             │
└─────────────────────────────────────────────┘
```

**Logged-in status view** — When tapping the green button:

```
┌─────────────────────────────────────────────┐
│  WeChat Connected                    [Done] │
│─────────────────────────────────────────────│
│  ✓ Logged in as: 李程                       │
│  Contacts: 127                              │
│  Messages today: 14                         │
│                                             │
│  Bound contacts:                            │
│  • 张三 → Session "project-alpha"           │
│  • 李四 → Session "daily-tasks"             │
│                                             │
│  [Manage Contacts]   [Disconnect]           │
└─────────────────────────────────────────────┘
```

### Architecture on iOS

```
┌─────────────────────────────────────────────────────┐
│  Neox iPhone App                                     │
│                                                      │
│  ┌──────────────────────────────────────────────┐    │
│  │  Top Bar: [WeChat 💬] toggle button           │    │
│  │  → enables/disables WeChatChannel             │    │
│  └──────────────────────────────────────────────┘    │
│                                                      │
│  ┌─────────────────┐    ┌─────────────────────────┐  │
│  │  WeChat WebView  │    │  WeChatChannel          │  │
│  │  (WKWebView,     │    │                         │  │
│  │   background,    │    │  - init/destroy          │  │
│  │   persistent     │    │  - state (qr/login/     │  │
│  │   cookies)       │    │    ready/dead)           │  │
│  │                  │    │  - sendMessage(to, text) │  │
│  │  wx.qq.com       │    │  - getContacts()         │  │
│  │  + WechatyBro    │    │  - onMessage callback    │  │
│  │    injection     │    │  - QR code URL           │  │
│  └────────┬─────────┘    └────────────┬────────────┘  │
│           │                           │               │
│           │   evaluateJavaScript()    │               │
│           ◄───────────────────────────┘               │
│                                                      │
│  ┌─────────────────────────────────────────────────┐  │
│  │  Message Router                                  │  │
│  │  WeChat message → find session → send to agent   │  │
│  │  Agent reply → sendMessage(contact, reply)       │  │
│  └─────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

### Key Components

#### 1. WeChatChannel (new Swift class, ~300 lines)

Port of bullx's `WechatManager` to WKWebView:

```swift
@MainActor
public final class WeChatChannel: NSObject, ObservableObject {
    // State
    @Published var state: ChannelState = .disconnected  // disconnected → qr → scanning → ready → dead
    @Published var qrCodeURL: String?                    // For UI to render QR code
    @Published var loggedInUser: WeChatUser?
    @Published var contacts: [WeChatContact] = []
    
    // Internal
    private let webView: WKWebView                       // Dedicated WebView, NOT the browser tab
    private var bridgeInjected = false
    private var messagePollingTimer: Timer?
    
    // Callbacks
    var onMessage: ((WeChatMessage) -> Void)?
    
    // Public API
    func start()                                         // Load wx.qq.com, begin QR flow
    func sendMessage(to: String, content: String) async -> Bool
    func getContacts() async -> [WeChatContact]
    func destroy()
    
    // Internal
    private func injectBridge()                          // Port WechatyBro code
    private func pollForMessages()                       // Poll __wechatBridge every 500ms
    private func extractQRUuid()                         // Find login UUID from page
}
```

**Key difference from bullx**: No CDP (WKWebView doesn't expose Chrome DevTools Protocol). All communication via `evaluateJavaScript()`. QR UUID extraction must use DOM inspection instead of network interception.

#### 2. QR Code Display

Two options:
- **Native**: Use `CoreImage` `CIQRCodeGenerator` to render the QR URL as UIImage
- **Web**: Navigate the browser tab to a QR generator page

Native is better — no external dependency, instant rendering:
```swift
func generateQRCode(from string: String) -> UIImage? {
    let data = string.data(using: .utf8)
    let filter = CIFilter(name: "CIQRCodeGenerator")!
    filter.setValue(data, forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let ciImage = filter.outputImage else { return nil }
    let transform = CGAffineTransform(scaleX: 10, y: 10)
    return UIImage(ciImage: ciImage.transformed(by: transform))
}
```

#### 3. WechatyBro Bridge (port to WKWebView)

The bullx `wechat-inject.js` (514 lines) hooks AngularJS internals. On iOS, we inject the same code via `WKWebView.evaluateJavaScript()`, but with adaptations:

- **No `window.sendToPuppeteer`**: Instead, accumulate events in `window.__wechatBridge` array, poll from Swift side
- **No CDP**: Can't intercept network requests. Extract QR UUID from DOM only
- **Same AngularJS hooks**: `contactFactory`, `chatFactory`, `rootScope.$on('message:add:success')`

The injection code from bullx can be reused almost verbatim. The bridge initialization pattern is identical:

```javascript
// Set up message channel
window.sendToPuppeteer = function(type, data) {
    window.__wechatBridge = window.__wechatBridge || [];
    window.__wechatBridge.push({ type, data, ts: Date.now() });
};

// Inject WechatyBro
WechatyBro.init();
```

Swift polls:
```swift
private func pollForMessages() {
    Task { @MainActor in
        let events = try? await webView.evaluateJavaScript("""
            (function() {
                const bridge = window.__wechatBridge || [];
                window.__wechatBridge = [];
                return bridge;
            })()
        """)
        // Process events: scan, login, logout, message, heartbeat
    }
}
```

#### 4. Message Router Integration

Once WeChat is a live channel, incoming messages need to route to the AI agent:

```
WeChat message arrives
    │
    ▼
Is contact bound to a session?  ──yes──► Send message to that session
    │no
    ▼
Is contact in a workspace contact list? ──yes──► Auto-create session, route
    │no
    ▼
Show notification in UI (unrouted)
```

This mirrors bullx's `ContactRouter` but adapted for CopilotSDK sessions on iOS.

### State Machine

```
disconnected ──start()──► loading ──dom-ready──► extracting_qr
                                                      │
                                                      ▼
                                              qr_ready (emit QR URL)
                                                      │
                                          user scans from another device
                                                      │
                                                      ▼
                                              logging_in (bridge detects)
                                                      │
                                                      ▼
                                              ready (channel live)
                                                      │
                                          heartbeat timeout / logout
                                                      │
                                                      ▼
                                              dead ──restart──► loading
```

### Differences from bullx

| Aspect | bullx (Electron) | Neox (iOS) |
|---|---|---|
| WebView | `WebContentsView` + CDP | `WKWebView` + `evaluateJavaScript` |
| Persistent session | `session.fromPartition('persist:wechat')` | `WKWebsiteDataStore.default()` |
| QR code interception | CDP network request interception | DOM polling for QR UUID |
| QR display | Render in Electron UI | Render via CoreImage QR generator |
| Message bridge | CDP + bridge polling | evaluateJS polling only |
| Background execution | Hidden window, no throttling | iOS background limits — need `beginBackgroundTask` |
| Voice transcription | ffmpeg + whisper locally | Use iOS Speech framework or skip for v1 |
| Contact avatars | Fetch via Electron session + disk cache | Fetch via URLSession + disk cache |

### iOS-Specific Challenges

1. **Background execution**: iOS suspends apps. WeChat channel dies when app goes to background.
   - Mitigation: Use `BGTaskScheduler` for periodic wake-ups, reconnect on foreground
   - Accept: WeChat channel is best-effort, not guaranteed persistent

2. **WKWebView lifecycle**: iOS can reclaim WKWebView memory under pressure.
   - Mitigation: Detect `webViewWebContentProcessDidTerminate`, reinitialize

3. **No CDP**: Can't intercept network requests or use debugger API.
   - Mitigation: All observation via `evaluateJavaScript` polling

4. **QR code scanning**: Can't scan from WeChat on same device.
   - Solution: Display QR code in Neox UI → scan from another device

---

## Build Plan

### Phase 1: Site Auth (current state — code written, needs build + test)
- [x] WebViewManager cookie methods
- [x] WebAgentToolProvider auth dispatch
- [x] XHS adapters (explore/search/profile/post)
- [x] Skill prompt updated
- [ ] Build and verify compilation
- [ ] Test on real XHS site
- [ ] Commit

### Phase 2: WeChat Channel (port from bullx)
- [ ] `WeChatChannel.swift` — WKWebView + WechatyBro injection
- [ ] `wechat-bridge.js` — Port injection code from bullx
- [ ] QR code generation + display in Neox UI
- [ ] Message polling + event handling (scan, login, logout, message)
- [ ] `sendMessage` + `getContacts` APIs
- [ ] Integrate with CopilotSDK session system for message routing
- [ ] Handle iOS background/foreground lifecycle
- [ ] Test end-to-end: QR scan → login → receive message → AI reply

### Phase 3: Advanced
- [ ] Voice message support (iOS Speech framework)
- [ ] Contact avatar fetching + caching
- [ ] Group chat support
- [ ] Auto-reconnect after app suspension
- [ ] WeChat file/image message support

---

## File Map

```
WebKitAgent/
├── Sources/
│   ├── WebViewManager.swift          # Cookie/auth methods (modified)
│   ├── WebAgentToolProvider.swift     # Auth dispatch + known sites (modified)
│   ├── Adapters/
│   │   ├── SiteAdapter.swift         # Adapter types (unchanged)
│   │   ├── AdapterRegistry.swift     # XHS + WeChat adapters (modified)
│   │   └── PipelineEngine.swift      # Pipeline executor (unchanged)
│   ├── WeChat/                       # NEW — Phase 2
│   │   ├── WeChatChannel.swift       # Main channel manager
│   │   ├── WeChatTypes.swift         # WeChatUser, WeChatMessage, WeChatContact
│   │   ├── WeChatBridge.swift        # Bridge injection code (JS string)
│   │   └── WeChatRouter.swift        # Message → session routing
│   └── Resources/
│       └── wechat-bridge.js          # WechatyBro injection script (port from bullx)
```
