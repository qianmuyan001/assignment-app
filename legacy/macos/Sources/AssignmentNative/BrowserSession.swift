import Combine
import Foundation
import SwiftUI
import WebKit


enum BrowserSessionError: LocalizedError {
    case invalidURL
    case insecureCredentialOrigin
    case hostMismatch
    case missingPasswordField
    case captureFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter a valid website URL."
        case .insecureCredentialOrigin:
            "Credentials can only be filled on an HTTPS page."
        case .hostMismatch:
            "The saved credential does not match the current page host."
        case .missingPasswordField:
            "No visible password field was found on this page."
        case .captureFailed:
            "The visible page content could not be captured."
        }
    }
}


@MainActor
final class BrowserSession: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView

    @Published private(set) var currentURL = ""
    @Published private(set) var pageTitle = ""
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.limitsNavigationsToAppBoundDomains = false

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsMagnification = true
        webView.allowsBackForwardNavigationGestures = true
        super.init()
        webView.navigationDelegate = self
    }

    var currentHost: String? {
        webView.url?.host?.lowercased()
    }

    var currentOrigin: String? {
        webView.url.flatMap { try? CredentialOrigin.value(for: $0) }
    }

    var isSecurePage: Bool {
        webView.url?.scheme?.lowercased() == "https"
    }

    func load(_ value: String) throws {
        let prepared = value.contains("://") ? value : "https://\(value)"
        guard let url = URL(string: prepared),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else {
            throw BrowserSessionError.invalidURL
        }
        errorMessage = nil
        webView.load(URLRequest(url: url))
    }

    func reload() {
        webView.reload()
    }

    func goBack() {
        if webView.canGoBack {
            webView.goBack()
        }
    }

    func goForward() {
        if webView.canGoForward {
            webView.goForward()
        }
    }

    func fill(_ credential: StoredCredential) async throws {
        guard isSecurePage else {
            throw BrowserSessionError.insecureCredentialOrigin
        }
        guard currentOrigin == credential.origin.lowercased() else {
            throw BrowserSessionError.hostMismatch
        }

        let username = try Self.javascriptLiteral(credential.username)
        let password = try Self.javascriptLiteral(credential.password)
        let script = """
        (() => {
          const username = \(username);
          const password = \(password);
          const visible = element => {
            const style = window.getComputedStyle(element);
            const box = element.getBoundingClientRect();
            return !element.disabled &&
              style.visibility !== 'hidden' &&
              style.display !== 'none' &&
              box.width > 0 && box.height > 0;
          };
          const passwordField = [...document.querySelectorAll('input[type="password"]')]
            .find(visible);
          if (!passwordField) {
            return JSON.stringify({ success: false, reason: 'missing_password' });
          }
          const candidates = [
            'input[autocomplete="username"]',
            'input[type="email"]',
            'input[name*="user" i]',
            'input[id*="user" i]',
            'input[name*="email" i]',
            'input[id*="email" i]',
            'input[type="text"]'
          ];
          let usernameField = null;
          for (const selector of candidates) {
            usernameField = [...document.querySelectorAll(selector)].find(visible);
            if (usernameField) break;
          }
          const setValue = (field, value) => {
            if (!field) return;
            const setter = Object.getOwnPropertyDescriptor(
              window.HTMLInputElement.prototype, 'value'
            ).set;
            setter.call(field, value);
            field.dispatchEvent(new Event('input', { bubbles: true }));
            field.dispatchEvent(new Event('change', { bubbles: true }));
          };
          setValue(usernameField, username);
          setValue(passwordField, password);
          passwordField.focus();
          return JSON.stringify({ success: true });
        })()
        """

        let result = try await evaluateString(script)
        guard let data = result.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["success"] as? Bool == true else {
            throw BrowserSessionError.missingPasswordField
        }
    }

    func capturePage() async throws -> CapturedPage {
        let script = """
        (() => {
          const isVisible = element => {
            const style = window.getComputedStyle(element);
            const rect = element.getBoundingClientRect();
            return style.display !== 'none' &&
              style.visibility !== 'hidden' &&
              Number(style.opacity || 1) > 0 &&
              rect.width > 0 && rect.height > 0;
          };
          const excluded = new Set([
            'SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'SVG', 'CANVAS',
            'INPUT', 'TEXTAREA', 'SELECT', 'OPTION'
          ]);
          const chunks = [];
          const walker = document.createTreeWalker(
            document.body,
            NodeFilter.SHOW_TEXT
          );
          while (walker.nextNode()) {
            const node = walker.currentNode;
            const parent = node.parentElement;
            if (!parent || excluded.has(parent.tagName) || !isVisible(parent)) continue;
            const value = (node.textContent || '').replace(/\\s+/g, ' ').trim();
            if (value) chunks.push(value);
            if (chunks.join('\\n').length > 60000) break;
          }

          const links = [...document.querySelectorAll('a[href]')]
            .filter(link => isVisible(link))
            .map(link => ({
              text: (link.innerText || '').replace(/\\s+/g, ' ').trim().slice(0, 240),
              url: link.href
            }))
            .filter(link => {
              try {
                return link.text && new URL(link.url).origin === location.origin;
              } catch (_) {
                return false;
              }
            })
            .slice(0, 250);

          return JSON.stringify({
            url: location.href,
            title: document.title || '',
            text: chunks.join('\\n').slice(0, 60000),
            links
          });
        })()
        """

        let result = try await evaluateString(script)
        guard let data = result.data(using: .utf8) else {
            throw BrowserSessionError.captureFailed
        }
        do {
            return try JSONDecoder().decode(CapturedPage.self, from: data)
        } catch {
            throw BrowserSessionError.captureFailed
        }
    }

    func webView(
        _ webView: WKWebView,
        didStartProvisionalNavigation navigation: WKNavigation!
    ) {
        isLoading = true
        errorMessage = nil
        updateLocation(from: webView)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url,
              let scheme = url.scheme?.lowercased() else {
            return .cancel
        }
        if ["http", "https", "about"].contains(scheme) {
            return .allow
        }
        errorMessage = "Blocked navigation to the \(scheme) scheme."
        return .cancel
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        navigationResponse.canShowMIMEType ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        updateLocation(from: webView)
        Task { @MainActor [weak self, weak webView] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, let webView else { return }
            self.updateLocation(from: webView)
            if let documentTitle = try? await self.evaluateString(
                "document.title || ''"
            ), !documentTitle.isEmpty {
                self.pageTitle = documentTitle
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        isLoading = false
        errorMessage = error.localizedDescription
        updateLocation(from: webView)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        isLoading = false
        errorMessage = error.localizedDescription
        updateLocation(from: webView)
    }

    private func updateLocation(from webView: WKWebView) {
        currentURL = webView.url?.absoluteString ?? ""
        pageTitle = webView.title ?? ""
    }

    private func evaluateString(_ script: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let value = value as? String {
                    continuation.resume(returning: value)
                } else {
                    continuation.resume(throwing: BrowserSessionError.captureFailed)
                }
            }
        }
    }

    private static func javascriptLiteral(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [value])
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }
}


struct BrowserWebView: NSViewRepresentable {
    @ObservedObject var session: BrowserSession

    func makeNSView(context: Context) -> WKWebView {
        session.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
