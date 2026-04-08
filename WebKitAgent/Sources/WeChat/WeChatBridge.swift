import Foundation

/// Contains the WechatyBro bridge JavaScript for injection into WeChat Web.
///
/// Uses the standalone wechat-bro.js library loaded from bundle resources.
/// Communication via `window.__wechatBridge` polling array (no WKScriptMessageHandler needed).
public enum WeChatBridge {

    /// Load wechat-bro.js from the app bundle.
    private static let wechatBroSource: String = {
        guard let url = Bundle.main.url(forResource: "wechat-bro", withExtension: "js"),
              let code = try? String(contentsOf: url, encoding: .utf8) else {
            print("[WeChatBridge] FATAL: wechat-bro.js not found in app bundle")
            return ""
        }
        return code
    }()

    /// The JavaScript code to inject into the WeChat Web WKWebView.
    /// Sets up the sendToPuppeteer → __wechatBridge polling bridge,
    /// injects wechat-bro.js, and calls WechatyBro.init().
    /// Must be called after angular is ready on the page.
    public static var injectionScript: String {
        """
        ;(function() {
          'use strict';

          // Set up polling bridge (Swift polls __wechatBridge array)
          window.sendToPuppeteer = function(type, data) {
            window.__wechatBridge = window.__wechatBridge || [];
            window.__wechatBridge.push({ type: type, data: data, ts: Date.now() });
          };
        })();

        \(wechatBroSource)

        ;(function() {
          if (window.WechatyBro && window.WechatyBro.init) {
            var result = window.WechatyBro.init();
            return JSON.stringify(result || {code: 200, message: 'ok'});
          }
          return JSON.stringify({code: 503, message: 'WechatyBro not found after injection'});
        })()
        """
    }
    /// JavaScript to poll accumulated bridge events.
    /// Returns JSON array of events and clears the buffer.
    public static let pollScript: String = """
    (function() {
      var bridge = window.__wechatBridge || [];
      window.__wechatBridge = [];
      return JSON.stringify(bridge);
    })()
    """

    /// JavaScript to check if angular is ready on the page.
    public static let angularCheckScript: String = """
    (function() {
      return !!(typeof angular !== 'undefined' && angular.element && angular.element(document).injector());
    })()
    """

    /// JavaScript to check login state.
    public static let loginCheckScript: String = """
    (function() {
      return !!(window.MMCgi && window.MMCgi.isLogin);
    })()
    """

    /// JavaScript to get the QR code URL from the login scope.
    public static let qrCodeScript: String = """
    (function() {
      try {
        if (typeof angular === 'undefined') return JSON.stringify({error: 'no angular'});
        var scope = angular.element('[ng-controller="loginController"]').scope();
        if (!scope) return JSON.stringify({error: 'no login scope'});
        return JSON.stringify({
          code: scope.code,
          url: scope.qrcodeUrl || null
        });
      } catch(e) {
        return JSON.stringify({error: e.message});
      }
    })()
    """

    /// JavaScript to extract QR code UUID directly from DOM/JS variables.
    /// Does NOT require the bridge or angular to be fully ready.
    /// Uses 3 fallback methods (same as bullx):
    /// 1. Find QR <img> element in DOM
    /// 2. window.QRLogin.uuid
    /// 3. Angular loginController scope
    public static let directQRExtractionScript: String = """
    (function() {
      try {
        // Method 1: Find QR code <img> element
        var imgs = document.querySelectorAll(
          'img[src*="login.weixin.qq.com/qrcode/"], img[src*="login.wx.qq.com/qrcode/"]'
        );
        for (var i = 0; i < imgs.length; i++) {
          var match = imgs[i].src.match(/qrcode\\/(.+)/);
          if (match) return JSON.stringify({uuid: match[1], method: 'img'});
        }

        // Method 2: Global JS variable
        if (window.QRLogin && window.QRLogin.uuid) {
          return JSON.stringify({uuid: window.QRLogin.uuid, method: 'global'});
        }

        // Method 3: Angular scope (if available)
        if (typeof angular !== 'undefined' && angular.element) {
          var scope = angular.element('[ng-controller="loginController"]').scope();
          if (scope && scope.qrcodeUrl) {
            var m = scope.qrcodeUrl.match(/\\/l\\/(.+)$/);
            if (m) return JSON.stringify({uuid: m[1], method: 'angular'});
          }
        }

        return JSON.stringify({uuid: null});
      } catch(e) {
        return JSON.stringify({error: e.message});
      }
    })()
    """

    /// JavaScript to click the expired QR overlay to refresh it.
    public static let qrRefreshScript: String = """
    (function() {
      try {
        var overlay = document.querySelector(
          '.qrcode .expired, .qrcode_expired_mask, [ng-click*="getQRCode"], .QRCode .mask'
        );
        if (overlay) { overlay.click(); return JSON.stringify({refreshed: true, method: 'overlay'}); }
        var mask = document.querySelector('.qrcode .mask, .login_box .mask');
        if (mask) { mask.click(); return JSON.stringify({refreshed: true, method: 'mask'}); }
        return JSON.stringify({refreshed: false});
      } catch(e) {
        return JSON.stringify({error: e.message});
      }
    })()
    """

    /// JavaScript to get contacts list.
    public static let contactsScript: String = """
    (function() {
      try {
        return JSON.stringify(WechatyBro.contactList());
      } catch(e) {
        return JSON.stringify({error: e.message});
      }
    })()
    """

    /// JavaScript to send a message (with optional AI watermark and markdown styling).
    public static func sendScript(to: String, content: String, watermark: Bool = false) -> String {
        let escapedTo = to.replacingOccurrences(of: "'", with: "\\'")
        let escapedContent = content.replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
        return """
        (function() {
          try {
            var result = WechatyBro.send('\(escapedTo)', '\(escapedContent)', \(watermark));
            return JSON.stringify({ok: result});
          } catch(e) {
            return JSON.stringify({error: e.message});
          }
        })()
        """
    }

    /// JavaScript to build @mention string for a user in a room.
    public static func atScript(userId: String, roomId: String? = nil) -> String {
        let escapedUser = userId.replacingOccurrences(of: "'", with: "\\'")
        let roomArg = roomId.map { "'\($0.replacingOccurrences(of: "'", with: "\\'"))'" } ?? "undefined"
        return """
        (function() {
          try {
            return WechatyBro.at('\(escapedUser)', \(roomArg));
          } catch(e) {
            return '@\(escapedUser)\\u2005';
          }
        })()
        """
    }

    /// JavaScript to check if content was sent by AI (has hidden watermark).
    public static let isFromAIScript: String = """
    (function() {
      return !!(window.WechatyBro && window.WechatyBro.isFromAI);
    })()
    """

    /// JavaScript to get upload parameters for media upload.
    public static func uploadParamsScript(to: String) -> String {
        let escapedTo = to.replacingOccurrences(of: "'", with: "\\'")
        return """
        (function() {
          try {
            var params = WechatyBro.getUploadParams('\(escapedTo)');
            return JSON.stringify(params);
          } catch(e) {
            return JSON.stringify({error: e.message});
          }
        })()
        """
    }

    /// JavaScript to get room members.
    public static func roomMembersScript(roomId: String) -> String {
        let escapedRoom = roomId.replacingOccurrences(of: "'", with: "\\'")
        return """
        (function() {
          try {
            return JSON.stringify(WechatyBro.getRoomMembers('\(escapedRoom)'));
          } catch(e) {
            return JSON.stringify([]);
          }
        })()
        """
    }

    /// JavaScript to send image with pre-uploaded MediaId.
    public static func sendImageScript(to: String, mediaId: String) -> String {
        let escapedTo = to.replacingOccurrences(of: "'", with: "\\'")
        let escapedId = mediaId.replacingOccurrences(of: "'", with: "\\'")
        return """
        (function() {
          try {
            var result = WechatyBro.sendImageWithMediaId('\(escapedTo)', '\(escapedId)');
            return JSON.stringify({ok: result});
          } catch(e) {
            return JSON.stringify({error: e.message});
          }
        })()
        """
    }
}
