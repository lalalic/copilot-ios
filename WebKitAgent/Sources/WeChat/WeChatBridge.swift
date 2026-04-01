import Foundation

/// Contains the WechatyBro bridge JavaScript for injection into WeChat Web.
///
/// This is a port of bullx's `wechat-inject.js` adapted for WKWebView:
/// - Uses `window.__wechatBridge` array instead of `window.sendToPuppeteer`
/// - All communication via polling from Swift side
/// - No CDP dependency
public enum WeChatBridge {

    /// The JavaScript code to inject into the WeChat Web WKWebView.
    /// Must be called after angular is ready on the page.
    public static let injectionScript: String = """
    ;(function() {
      'use strict';

      if (window.WechatyBro && window.WechatyBro.vars && window.WechatyBro.vars.initState) {
        return JSON.stringify({code: 304, message: 'already initialized'});
      }

      // Bridge: accumulate events for Swift to poll
      window.__wechatBridge = window.__wechatBridge || [];

      function emit(type, data) {
        window.__wechatBridge.push({ type: type, data: data, ts: Date.now() });
      }

      function log() {
        console.log.apply(console, ['[WechatyBro]'].concat(Array.from(arguments)));
      }

      function MMCgiLogined() {
        return !!(window.MMCgi && window.MMCgi.isLogin);
      }

      function angularIsReady() {
        return !!(
          typeof angular !== 'undefined' &&
          angular.element &&
          angular.element('body') &&
          angular.element(document).injector()
        );
      }

      if (!angularIsReady()) {
        return JSON.stringify({code: 503, message: 'angular not ready'});
      }

      // Core bridge object
      window.WechatyBro = {
        vars: {
          initState: false,
          heartBeatTimmer: null,
          scanCode: null,
          scanUrl: null,
          loginState: false
        },
        glue: {},

        emit: emit,
        angularIsReady: angularIsReady,

        getUserName: function() {
          try {
            var injector = angular.element(document).injector();
            var accountFactory = injector.get('accountFactory');
            return accountFactory.getUserName();
          } catch(e) { return null; }
        },

        getContact: function(id) {
          try {
            var injector = angular.element(document).injector();
            var contactFactory = injector.get('contactFactory');
            var contact = contactFactory.getContact(id);
            if (!contact) return {id: id, UserName: id};
            return {
              id: contact.PYQuanPin || contact.UserName,
              name: contact.RemarkName || contact.NickName,
              UserName: contact.UserName,
              NickName: contact.NickName,
              RemarkName: contact.RemarkName,
              HeadImgUrl: contact.HeadImgUrl,
              Sex: contact.Sex,
              isRoomContact: !!(contact.UserName && contact.UserName.startsWith('@@'))
            };
          } catch(e) { return {id: id, UserName: id}; }
        },

        contactList: function() {
          try {
            var injector = angular.element(document).injector();
            var contactFactory = injector.get('contactFactory');
            var accountFactory = injector.get('accountFactory');
            var selfUserName = accountFactory.getUserName() || '';
            var all = contactFactory.getAllContacts();
            return Object.values(all).map(function(c) {
              var isRoom = !!(c.UserName && c.UserName.startsWith('@@'));
              return {
                id: c.PYQuanPin || c.UserName,
                name: c.RemarkName || c.NickName,
                UserName: c.UserName,
                NickName: c.NickName,
                RemarkName: c.RemarkName,
                HeadImgUrl: c.HeadImgUrl,
                isRoomContact: isRoom,
                isRoomOwner: isRoom && c.ChatRoomOwner === selfUserName,
                VerifyFlag: c.VerifyFlag || 0,
                ContactFlag: c.ContactFlag || 0,
                StarFriend: c.StarFriend || 0
              };
            });
          } catch(e) {
            log('contactList error:', e.message);
            return [];
          }
        },

        send: function(to, content) {
          try {
            var injector = angular.element(document).injector();
            var chatFactory = injector.get('chatFactory');
            var confFactory = injector.get('confFactory');
            var userName = to;

            if (to === 'filehelper' || to === 'wenjianchuanshuzhushou') {
              userName = 'filehelper';
            } else if (to && !to.startsWith('@') && !to.startsWith('@@')) {
              var contactFactory = injector.get('contactFactory');
              var allContacts = contactFactory.getAllContacts && contactFactory.getAllContacts();
              if (allContacts) {
                var contacts = Object.values(allContacts);
                for (var i = 0; i < contacts.length; i++) {
                  var c = contacts[i];
                  if (c && (c.PYQuanPin === to || c.id === to)) {
                    userName = c.UserName;
                    break;
                  }
                }
              }
            }

            var m = chatFactory.createMessage({
              ToUserName: userName,
              Content: content,
              MsgType: confFactory.MSGTYPE_TEXT
            });
            chatFactory.appendMessage(m);
            chatFactory.sendMessage(m);
            return true;
          } catch(e) {
            log('send error:', e.message);
            return false;
          }
        }
      };

      // Internal: glue to AngularJS
      var injector = angular.element(document).injector();
      WechatyBro.glue = {
        injector: injector,
        rootScope: injector.get('$rootScope'),
        loginScope: angular.element('[ng-controller="loginController"]').scope(),
        accountFactory: injector.get('accountFactory'),
        chatFactory: injector.get('chatFactory'),
        contactFactory: injector.get('contactFactory'),
        confFactory: injector.get('confFactory')
      };

      // Hook message events
      WechatyBro.glue.rootScope.$on('message:add:success', function(event, data) {
        data.from = WechatyBro.getContact(data.FromUserName);
        data.to = WechatyBro.getContact(data.ToUserName);
        emit('message', data);
      });

      // Hook contact additions
      var origAdd = WechatyBro.glue.contactFactory.addContacts;
      if (origAdd) {
        WechatyBro.glue.contactFactory.addContacts = function(contacts) {
          origAdd.apply(this, arguments);
          emit('contacts', contacts.length);
          var user = WechatyBro.getContact(WechatyBro.getUserName());
          if (user.id && !WechatyBro.vars.loginState) {
            doLogin();
          }
        };
      }

      function doLogin(attempt) {
        if (WechatyBro.vars.loginState && attempt === undefined) return;
        if (!attempt) attempt = 0;
        var userName = WechatyBro.getUserName();
        var user = userName ? WechatyBro.getContact(userName) : {id: null};
        if ((!user.name && !user.NickName) && attempt < 10) {
          setTimeout(function() { doLogin(attempt + 1); }, 500);
          return;
        }
        WechatyBro.vars.loginState = true;
        emit('login', user);
      }

      function checkScan() {
        if (WechatyBro.vars.loginState) return;
        var loginScope = WechatyBro.glue.loginScope;
        if (!loginScope) return setTimeout(checkScan, 1000);
        var code = +loginScope.code;
        var url = loginScope.qrcodeUrl;
        if (url && (code !== WechatyBro.vars.scanCode || url !== WechatyBro.vars.scanUrl)) {
          emit('scan', {code: code, url: url});
          WechatyBro.vars.scanCode = code;
          WechatyBro.vars.scanUrl = url;
        }
        if (code !== 200) return setTimeout(checkScan, 1000);
        WechatyBro.vars.scanCode = null;
        WechatyBro.vars.scanUrl = null;
      }

      function heartBeat() {
        emit('heartbeat', 'heartbeat@browser');
        WechatyBro.vars.heartBeatTimmer = setTimeout(heartBeat, 15000);
      }

      // Check if already logged in
      if (MMCgiLogined()) {
        setTimeout(doLogin, 1000);
      }

      // Start scan checking
      setTimeout(checkScan, 1000);

      // Start heartbeat
      heartBeat();

      WechatyBro.vars.initState = true;
      return JSON.stringify({code: 200, message: 'WechatyBro Init Succ'});
    })()
    """

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

    /// JavaScript to send a message.
    public static func sendScript(to: String, content: String) -> String {
        let escapedTo = to.replacingOccurrences(of: "'", with: "\\'")
        let escapedContent = content.replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
        return """
        (function() {
          try {
            var result = WechatyBro.send('\(escapedTo)', '\(escapedContent)');
            return JSON.stringify({ok: result});
          } catch(e) {
            return JSON.stringify({error: e.message});
          }
        })()
        """
    }
}
