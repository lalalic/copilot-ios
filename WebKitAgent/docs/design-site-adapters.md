# WebKitAgent Site Adapters — Design Document

## Inspiration: opencli

[opencli](https://github.com/jackwener/opencli) (8.6k stars) converts browser sites into CLI commands. Key patterns:

### Architecture
- **Dual-engine**: YAML declarative pipelines (public APIs) + TypeScript browser adapters (DOM scraping)
- **66+ adapters**: twitter, reddit, hackernews, bilibili, zhihu, xiaohongshu, youtube, spotify, etc.
- **Auth strategies**: `public` (no auth), `cookie` (reuse browser login), `header` (API key)
- **Chrome Bridge**: Extension + daemon connects to user's logged-in Chrome session via CDP
- **Anti-detection**: Patches `navigator.webdriver`, stubs `window.chrome`, cleans CDP stack traces

### Adapter Pattern

**YAML adapter** (public API, no browser):
```yaml
site: hackernews
name: top
description: Hacker News top stories
strategy: public
browser: false
args:
  limit: { type: int, default: 20 }
pipeline:
  - fetch: { url: https://hacker-news.firebaseio.com/v0/topstories.json }
  - limit: "${{ Math.min(args.limit + 10, 50) }}"
  - map: { id: "${{ item }}" }
  - fetch: { url: "https://hacker-news.firebaseio.com/v0/item/${{ item.id }}.json" }
  - filter: "item.title && !item.deleted"
  - map: { rank: "${{ index + 1 }}", title: "${{ item.title }}", score: "${{ item.score }}" }
  - limit: "${{ args.limit }}"
columns: [rank, title, score, author, comments]
```

**TypeScript adapter** (browser + DOM scraping):
```typescript
cli({
  site: 'twitter', name: 'trending',
  domain: 'x.com', strategy: Strategy.COOKIE, browser: true,
  args: [{ name: 'limit', type: 'int', default: 20 }],
  columns: ['rank', 'topic', 'tweets', 'category'],
  func: async (page, kwargs) => {
    await page.goto('https://x.com/explore/tabs/trending');
    await page.wait(3);
    const trends = await page.evaluate(`(() => { /* DOM scrape */ })()`);
    return trends.slice(0, kwargs.limit);
  },
});
```

### IPage Interface (opencli's browser abstraction)
```typescript
interface IPage {
  goto(url), evaluate(js), getCookies(opts),
  snapshot(opts), click(ref), typeText(ref, text),
  pressKey(key), scrollTo(ref), wait(opts),
  tabs(), closeTab(), newTab(), selectTab(),
  networkRequests(), consoleMessages(), scroll(),
  autoScroll(opts), screenshot(opts),
  setFileInput(files, selector)
}
```

---

## Design: WebKitAgent Site Adapters

### Goal
Add site-specific subcommands to `web_agent` tool so the AI agent can perform deterministic operations on popular sites without LLM-driven exploration. Zero LLM cost for known operations.

### Architecture

```
web_agent tool
├── Generic commands (existing)
│   ├── navigate, snapshot, click, type, download, upload
│
├── Site commands (new)
│   ├── hackernews/top, hackernews/search
│   ├── github/trending, github/issues
│   ├── reddit/hot, reddit/search
│   ├── twitter/trending, twitter/search, twitter/post
│   └── ... (extensible)
```

### Adapter Definition Format

YAML adapters stored in `WebKitAgent/Adapters/` (or bundled in the app):

```yaml
# WebKitAgent/Adapters/hackernews/top.yaml
site: hackernews
name: top
description: Get top Hacker News stories
auth: none               # none | cookie | header
requiresBrowser: false    # false = public API, true = needs WKWebView
args:
  limit:
    type: int
    default: 20
    description: Number of stories to return
pipeline:
  - fetch: https://hacker-news.firebaseio.com/v0/topstories.json
  - slice: { to: "${{ args.limit + 10 }}" }
  - fetchEach: "https://hacker-news.firebaseio.com/v0/item/${{ item }}.json"
  - filter: "${{ item.title != nil && !item.deleted }}"
  - map:
      rank: "${{ index + 1 }}"
      title: "${{ item.title }}"
      score: "${{ item.score }}"
      author: "${{ item.by }}"
      url: "${{ item.url }}"
  - slice: { to: "${{ args.limit }}" }
```

### Swift Adapter (browser-required)

```swift
// WebKitAgent/Adapters/twitter/trending.swift
struct TwitterTrendingAdapter: SiteAdapter {
    let site = "twitter"
    let name = "trending"
    let description = "Get Twitter/X trending topics"
    let auth: AuthStrategy = .cookie(domain: "x.com")
    let requiresBrowser = true
    let args: [AdapterArg] = [
        .init(name: "limit", type: .int, default: "20")
    ]
    
    func execute(manager: WebViewManager, args: [String: String]) async throws -> [[String: Any]] {
        try await manager.navigate(to: "https://x.com/explore/tabs/trending")
        // Wait for content
        try await Task.sleep(for: .seconds(3))
        // Evaluate JS to scrape trends
        let js = """
        (() => {
            const items = [];
            document.querySelectorAll('[data-testid="trend"]').forEach(cell => {
                const text = cell.textContent || '';
                if (text.includes('Promoted')) return;
                // ... extract rank, topic, tweets, category
                items.push({ rank: items.length + 1, topic, tweets, category });
            });
            return JSON.stringify(items);
        })()
        """
        let result = try await manager.evaluateJS(js)
        return parseJSON(result)
    }
}
```

### Tool Integration

New `web_agent` subcommand: `site`

```
web_agent command=site site=hackernews action=top limit=5
web_agent command=site site=twitter action=trending limit=10
web_agent command=site site=github action=trending language=swift
```

### Implementation Plan

#### Phase 1: Core Infrastructure
1. **SiteAdapter protocol** — defines site/name/args/auth/execute
2. **AdapterRegistry** — discovers and loads adapters
3. **YAML adapter parser** — parse YAML definitions, execute pipeline steps
4. **Pipeline engine** — fetch, slice, filter, map, fetchEach steps
5. Add `site` subcommand to WebAgentToolProvider

#### Phase 2: Public API Adapters (no browser needed)
- hackernews: top, new, best, search, user
- github: trending (scrape github.com/trending)
- wikipedia: search, random, article
- arxiv: search, recent

#### Phase 3: Browser-Based Adapters  
- twitter: trending, search, timeline, post
- reddit: hot, search, frontpage
- bilibili: hot, search, ranking
- youtube: trending, search
- xiaohongshu: search, feed

#### Phase 4: Auth & Session Management
- Cookie-based auth (reuse WKWebView session)
- Login flow prompts (open site in browser, user logs in, cookies persist)
- Session health checks (verify login state before running)

### Key Differences from opencli

| Aspect | opencli | WebKitAgent Adapters |
|--------|---------|---------------------|
| Runtime | Node.js + Chrome CDP | Swift + WKWebView |
| Auth | Chrome extension + daemon | WKWebView cookie jar (shared) |
| Platform | Desktop CLI | iOS app (in-process) |
| Browser | Playwright/CDP to Chrome | Native WKWebView |
| Format | YAML + TypeScript | YAML + Swift |
| Output | Table/JSON/CSV/YAML | Structured text for LLM |
| Anti-detect | Extensive | Not needed (real Safari UA) |

### Advantages of WKWebView Approach
- **Real Safari user agent** — Sites see a real iPhone Safari, not headless Chrome
- **Shared cookie jar** — If user logs into a site in the browser tab, adapters auto-inherit cookies
- **No extension needed** — Everything runs in-app
- **Mobile-native** — Access mobile APIs and layouts (often simpler than desktop)
- **Privacy** — Credentials never leave the device

### File Structure
```
WebKitAgent/
├── Sources/
│   ├── WebAgentToolProvider.swift   (existing — add `site` subcommand)
│   ├── WebViewManager.swift         (existing — add evaluateJS if needed)
│   ├── Adapters/
│   │   ├── SiteAdapter.swift        (protocol)
│   │   ├── AdapterRegistry.swift    (discovery + registration)
│   │   ├── PipelineEngine.swift     (YAML pipeline executor)
│   │   ├── hackernews/
│   │   │   └── top.yaml
│   │   ├── github/
│   │   │   └── trending.yaml
│   │   └── twitter/
│   │       └── trending.swift
```

---

## Dynamic Adapter Loading (No Rebuild Required)

### Problem
iOS apps are sandboxed and compiled. Adding a new adapter would normally require rebuilding and resubmitting to the App Store.

### Solution: YAML + JavaScript Adapters Loaded at Runtime

**Three adapter sources, in priority order:**

1. **Bundled adapters** — Ship with the app binary (fallback, always available)
2. **Remote adapters** — Downloaded from a GitHub repo or API at launch
3. **Local adapters** — User can add `.yaml` files to a shared App Group directory (via Files app, AirDrop, or MCP bridge)

### How It Works

#### YAML Adapters (Public API — no browser)
YAML adapters only use `fetch` + `map` + `filter` pipelines against public REST APIs. The `PipelineEngine` is a Swift interpreter that parses YAML at runtime and executes steps. No compilation needed.

```yaml
# Fetched from: https://raw.githubusercontent.com/user/neox-adapters/main/hackernews/top.yaml
site: hackernews
name: top
description: Get top HN stories
auth: none
requiresBrowser: false
pipeline:
  - fetch: https://hacker-news.firebaseio.com/v0/topstories.json
  - slice: { to: "${{ args.limit }}" }
  - fetchEach: "https://hacker-news.firebaseio.com/v0/item/${{ item }}.json"
  - map: { title: "${{ item.title }}", score: "${{ item.score }}", url: "${{ item.url }}" }
```

#### JavaScript Adapters (Browser — DOM scraping)
For browser-based adapters, the logic is JavaScript that runs in the WKWebView. This is already what `web_agent` does with `evaluate`. The adapter just packages the JS.

```yaml
# Browser-based adapter
site: twitter
name: trending
description: Twitter/X trending topics
auth: cookie
domain: x.com
requiresBrowser: true
preNavigate: https://x.com/explore/tabs/trending
waitSeconds: 3
script: |
  (() => {
    const items = [];
    document.querySelectorAll('[data-testid="trend"]').forEach(cell => {
      const text = cell.textContent || '';
      if (text.includes('Promoted')) return;
      const container = cell.querySelector(':scope > div');
      if (!container) return;
      const divs = container.children;
      if (divs.length < 2) return;
      const topic = divs[1].textContent.trim();
      items.push({ rank: items.length + 1, topic });
    });
    return JSON.stringify(items);
  })()
```

### Adapter Discovery & Update Flow

```
App Launch → Check local cache age → If stale:
  → Fetch adapter index from GitHub/CDN
  → Download new/updated YAML files
  → Store in App Group container (~/Documents/Adapters/)
  → Register in AdapterRegistry

Agent asks: "web_agent command=site site=hackernews action=top"
  → AdapterRegistry.find("hackernews", "top")
  → PipelineEngine.execute(adapter.pipeline, args)
  → Return structured result
```

### Security Considerations

1. **YAML adapters only fetch from HTTPS** — no arbitrary code execution
2. **JS adapters run in WKWebView sandbox** — same-origin, no file system access
3. **Adapter index is signed** — SHA256 hash of each adapter verified against manifest
4. **No Swift code injection** — adapters cannot call arbitrary Swift APIs
5. **Rate limit enforcement** — PipelineEngine enforces per-site rate limits

### Adapter Distribution

**Option A: GitHub Repository** (simplest)
```
github.com/user/neox-adapters/
├── index.json          # manifest with versions + hashes
├── hackernews/
│   ├── top.yaml
│   └── search.yaml
├── twitter/
│   └── trending.yaml
└── reddit/
    └── hot.yaml
```

The app fetches `index.json`, diffs against local cache, downloads changed YAML files.

**Option B: MCP Bridge** (developer workflow)
```bash
# Push adapter to device via bridge
curl http://localhost:9224/mcp -d '{
  "method": "tools/call",
  "params": {"name": "install_adapter", "arguments": {
    "yaml": "site: test\nname: demo\n..."
  }}
}'
```

**Option C: Files App**
User copies `.yaml` files to the Neox app folder via Files app or AirDrop.

### What This Means

- **Ship once, extend forever** — New site adapters added without App Store update
- **Community contributions** — Users can submit YAML adapters via PR to the adapter repo
- **Agent discovers adapters** — `web_agent command=site action=list` returns all available adapters
- **Hot reload** — Update adapters by editing YAML, no restart needed
- **Same approach as opencli** — Their `clis/` folder pattern, just mobile-native

### Limitations

- **Swift adapters still require rebuild** — Complex adapters with native API calls (camera, files) need compilation
- **YAML pipeline is limited** — fetch, map, filter, sort. No loops, conditionals, or complex state
- **JS adapters must trust the DOM structure** — If a site changes its HTML, the adapter breaks (same as opencli)
- **App Store review** — Downloaded code must not violate Apple's guidelines (YAML data pipelines are fine; arbitrary JS in WKWebView is standard practice)

---

## Login & Authentication Strategy

### The Problem

Many site adapters need the user to be logged in:
- Twitter trending requires a valid session cookie (`ct0`)
- Reddit saved posts require authentication
- Bilibili history requires login
- Any "personal feed" or "post" action needs auth

On desktop (opencli), this is solved by reusing Chrome's logged-in session via the Browser Bridge extension. On iOS, we don't have Chrome but we do have **WKWebView with persistent cookies**.

### Solution: WKWebView Shared Cookie Jar

WKWebView uses `WKWebsiteDataStore.default()` by default, which:
- **Persists cookies across app launches** (stored in iOS keychain/data container)
- **Shares cookies between all WKWebViews in the same process** (our browser tab + adapter execution use the same store)
- **Handles all standard cookie flows** (Set-Cookie, secure, httpOnly, SameSite)

This means: **if the user logs into Twitter in the browser tab, the adapter automatically has the session cookies.**

### Auth Flow

```
User → Opens browser tab → Types twitter.com → Logs in
  → WKWebView stores session cookies (ct0, auth_token, etc.)
  → Cookies persist in WKWebsiteDataStore.default()

Later → Agent runs: web_agent command=site site=twitter action=trending
  → Adapter checks auth: reads cookies for "x.com" domain
  → Finds ct0 cookie → Authenticated ✓
  → Navigates to trending page → Content loads with user's session
  → Scrapes and returns data
```

### Auth Strategies (per adapter)

```yaml
# In adapter YAML:
auth: none       # No authentication needed (public API)
auth: cookie     # Requires cookies for the domain
auth: header     # Requires API key in header (stored in Keychain)
```

#### Strategy 1: `none` (Public API)
- No auth needed. Just fetch from public REST APIs.
- Example: HackerNews top stories, GitHub trending (scrape), Wikipedia search

#### Strategy 2: `cookie` (Browser Session Reuse)
- Check if valid session cookies exist for the domain
- If yes: proceed with the request (cookies automatically attached by WKWebView)
- If no: return an error asking the user to log in first

```yaml
site: twitter
auth: cookie
domain: x.com
authCheck:
  # JS that verifies login state. Returns "true" if logged in.
  script: |
    (() => {
      const ct0 = document.cookie.split(';').find(c => c.trim().startsWith('ct0='));
      return ct0 ? 'true' : 'false';
    })()
```

**When not logged in, the adapter returns:**
```
Error: Not logged in to x.com.
To use this adapter:
1. Open the browser tab
2. Navigate to x.com
3. Log in with your account
4. Try this command again
```

The agent can then tell the user to log in, or even navigate to the login page itself.

#### Strategy 3: `header` (API Key)
- For sites that require an API key (e.g., OpenAI, external APIs)
- Keys stored in iOS Keychain, referenced by adapter name
- User provides key once via settings or MCP tool

### Login Helper Commands

The agent can help the user log in:

```
Agent: "I need to access your Twitter trending topics. You're not logged in to x.com.
        Would you like me to open x.com so you can log in?"

User: "Yes"

Agent → web_agent command=navigate url=https://x.com/login
        [Browser tab opens showing Twitter login page]
        
User → Types username/password in the browser tab

Agent → web_agent command=site site=twitter action=auth_check
        → Returns: "Logged in as @username"
        
Agent → web_agent command=site site=twitter action=trending limit=5
        → Returns trending topics
```

### Cookie Management

**Check login status:**
```yaml
# Built-in for every adapter with auth: cookie
authCheck:
  navigateTo: https://x.com
  script: |
    (() => {
      // Check for auth indicators in cookies or DOM
      const loggedIn = document.querySelector('[data-testid="SideNav_AccountSwitcher_Button"]');
      return loggedIn ? JSON.stringify({ loggedIn: true, user: loggedIn.textContent }) : JSON.stringify({ loggedIn: false });
    })()
```

**List all sessions:**
```
web_agent command=site action=sessions
→ twitter: logged in (@username)
→ reddit: not logged in
→ github: logged in (user@example.com)
→ bilibili: not logged in
```

**Clear session:**
```
web_agent command=site site=twitter action=logout
→ Clears all cookies for x.com domain
```

### Multi-Account Support

WKWebView cookie jar is single-account per domain. For multi-account:
- Use separate `WKWebsiteDataStore` instances per profile
- Or simply: user logs out and logs into a different account when needed

### Session Persistence

```
App launched → WKWebsiteDataStore.default() loads persisted cookies
               User's Twitter/Reddit/etc sessions still active
               All adapters immediately functional

App killed → Cookies persist in iOS data container
App reopened → Sessions still valid (if not expired server-side)

User deletes app → All cookies deleted (Apple sandbox)
```

### Privacy & Security

1. **Credentials never leave the device** — Login happens in WKWebView on-device
2. **No credential storage** — We don't store usernames/passwords, only standard HTTP cookies
3. **Per-domain isolation** — Each site's cookies are domain-scoped (standard Same-Origin)
4. **User-initiated only** — Agent can't log in without user typing credentials
5. **Transparent** — `sessions` command shows exactly what's logged in
6. **Easy revoke** — `logout` clears cookies instantly
7. **App deletion = full cleanup** — iOS sandbox ensures all data removed

### Comparison with opencli

| Aspect | opencli | WebKitAgent |
|--------|---------|-------------|
| Session storage | Chrome profile cookies | WKWebView cookie jar |
| Login flow | User logs into Chrome manually | User logs in via browser tab |
| Session sharing | Chrome Extension reads cookies via CDP | Same WKWebView store (automatic) |
| Multi-account | Chrome profiles | Not supported (single store) |
| Cookie access | `page.getCookies()` | `WKWebsiteDataStore.httpCookieStore` |
| Persistence | Chrome profile folder | iOS app data container |
| Anti-detection | Extensive (patches webdriver) | Not needed (real Safari) |

---

## QR Code / Barcode Login

### The Problem

Some sites (especially Chinese platforms) require scanning a QR code with a mobile app to log in:
- **WeChat (微信)** — scan with WeChat app to authorize web login
- **Bilibili** — QR code login option
- **Zhihu** — QR code login
- **Douyin/TikTok** — QR code login
- **Taobao/Alipay** — QR code login

These sites show a QR code on the web page. The user must scan it with the corresponding native app already installed on their iPhone.

### Why This Is Unique on iOS

On desktop (opencli), the user scans the QR code on their phone's camera pointing at the computer screen. On iOS, **the QR code is on the same device as the scanning app**. The user can't easily point their phone's camera at their own phone screen.

### Solution: Multi-Step Flow

#### Approach 1: System Share Sheet (Recommended)

```
1. Agent navigates to weixin.qq.com login page
2. WKWebView renders the QR code
3. Agent detects QR code image element in DOM
4. Extract QR code image URL or capture screenshot
5. Use iOS system to decode QR code → get the URL/payload
6. Open the URL in the native app (WeChat) via Universal Link / URL Scheme
7. Native app shows "Authorize login?" confirmation
8. User taps "Confirm" in native app
9. Web page auto-detects authorization → session established
10. Cookies persist → adapter is now authenticated
```

**Implementation:**

```swift
// Step 1-2: Navigate to login page
try await manager.navigate(to: "https://open.weixin.qq.com/connect/qrconnect?...")

// Step 3-4: Extract QR code from DOM
let qrImageDataURL = try await manager.evaluateJS("""
    (() => {
        const img = document.querySelector('.qrcode img, #qrcode img, canvas');
        if (img.tagName === 'CANVAS') {
            return img.toDataURL('image/png');
        }
        return img.src;
    })()
""")

// Step 5: Decode QR code
let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil)
let features = detector?.features(in: ciImage) as? [CIQRCodeFeature]
let qrPayload = features?.first?.messageString  // e.g., "https://login.weixin.qq.com/l/..."

// Step 6: Open in native WeChat app
if let url = URL(string: qrPayload) {
    await UIApplication.shared.open(url)
    // WeChat opens → shows "Authorize login?" dialog
}

// Step 7-8: User taps confirm in WeChat

// Step 9: Poll the web page for login success
for _ in 0..<30 {
    try await Task.sleep(for: .seconds(2))
    let loggedIn = try await manager.evaluateJS("""
        document.cookie.includes('session_id') ? 'true' : 'false'
    """)
    if loggedIn == "true" { break }
}
```

#### Approach 2: Screenshot + Camera Roll (Fallback)

For apps that don't support URL scheme QR scanning:

```
1. Agent captures a screenshot of the QR code
2. Save screenshot to camera roll OR show in a popup
3. User manually opens the native app (WeChat)
4. User long-presses the QR code image from camera roll → "Scan QR from Album"
5. Native app authenticates
6. Agent polls for session establishment
```

#### Approach 3: Clipboard QR (Simplest)

Some apps detect QR URLs in clipboard:

```
1. Extract QR code URL from the image
2. Copy the URL to clipboard: UIPasteboard.general.string = qrURL
3. User opens WeChat → it auto-detects clipboard link → offers to open
4. Or: tell user to paste the link in WeChat
```

### Platform-Specific Solutions

| Platform | Best Approach | URL Scheme | Notes |
|----------|--------------|------------|-------|
| WeChat | URL scheme | `weixin://dl/scan?qr=<url>` | Opens scan directly |
| Bilibili | URL scheme | `bilibili://qr_login?url=<url>` | May vary by version |
| Zhihu | Cookie fallback | N/A | Often allows password login too |
| Douyin | URL scheme | `snssdk1128://` | Complex deep link |
| Alipay | URL scheme | `alipay://platformapi/...` | Well-documented |

### Adapter YAML for QR Login

```yaml
site: wechat
auth: qr_code
domain: weixin.qq.com

loginFlow:
  navigateTo: https://open.weixin.qq.com/connect/qrconnect?...
  qrSelector: ".qrcode img"           # CSS selector for QR image
  qrType: image                       # image | canvas
  nativeAppScheme: "weixin://dl/scan"  # URL scheme to open native app
  pollInterval: 2                      # seconds between login checks
  pollTimeout: 60                      # max seconds to wait
  successCheck: |
    document.cookie.includes('wx_session') ? 'true' : 'false'
```

### Agent-Guided Login Flow

```
User: "Get my WeChat articles"

Agent: "You're not logged into WeChat web. I'll help you log in.
        I'll extract the QR code and open WeChat for you to confirm."

Agent → web_agent command=site site=wechat action=login
  → Navigates to login page
  → Extracts QR code
  → Opens WeChat via URL scheme
  → "I've opened WeChat. Please tap 'Confirm' to authorize login."

User → [Taps confirm in WeChat app]

Agent → [Polls... detects login success]
  → "You're now logged into WeChat web! Getting your articles..."
  → web_agent command=site site=wechat action=articles
```

### Key Consideration: Same-Device QR

The biggest UX challenge is scanning a QR code from the same device it's displayed on. Solutions ranked by quality:

1. **URL scheme opening** (best) — Decode QR → open native app directly via deep link. No scanning needed.
2. **Long-press from camera roll** — Screenshot QR → save to photos → user opens from album in native app
3. **AirDrop to another device** — Send QR screenshot to laptop/another phone to scan
4. **Display QR in notification/widget** — Use PiP or notification to show QR while switching to native app (complex)

**Recommendation:** Focus on URL scheme for major platforms. It completely bypasses the "scan from same device" problem. Most Chinese apps support deep links.
