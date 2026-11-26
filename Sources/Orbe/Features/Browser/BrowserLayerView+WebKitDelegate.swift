import AppKit
import WebKit

/// `BrowserLayerView` の `WKNavigationDelegate` / `WKUIDelegate` と遷移・オリジン検証。
extension BrowserLayerView: WKNavigationDelegate, WKUIDelegate {
  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
  ) {
    let isMainOrNew = navigationAction.targetFrame?.isMainFrame ?? true
    let url = navigationAction.request.url
    let scheme = url?.scheme?.lowercased()
    if isMainOrNew {
      if scheme == "http" || scheme == "https" {
        decisionHandler(.allow)
      } else if pendingNavigation?.allowsInternalBlankLoad == true,
        url?.absoluteString == "about:blank"
      {
        pendingNavigation?.allowsInternalBlankLoad = false
        decisionHandler(.allow)
      } else {
        clearUnstartedPendingNavigationIfMatching(url)
        decisionHandler(.cancel)
      }
    } else if let scheme, Self.allowedSubframeSchemes.contains(scheme) {
      decisionHandler(.allow)
    } else {
      decisionHandler(.cancel)
    }
  }

  func webView(
    _ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!
  ) {
    if let navigation, supersededNavigations.contains(navigation) {
      return
    }
    if var pending = pendingNavigation, pending.matches(navigation) {
      pending.didStartProvisional = true
      pendingNavigation = pending
    } else if let navigation {
      pendingNavigation = PendingNavigation(
        navigation: navigation, requestedURL: webView.url,
        isLocalHTML: false, allowsInternalBlankLoad: false, didStartProvisional: true)
    }
    syncNavigationState()
  }

  func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    if let navigation, supersededNavigations.contains(navigation) {
      return
    }
    if let pending = pendingNavigation, !pending.matches(navigation) {
      return
    }
    let wasLocalHTML = pendingNavigation?.isLocalHTML ?? false
    pendingNavigation = nil
    if let url = webView.url, url.scheme?.lowercased() != "about" {
      committedPage = CommittedPage(url: url, isLocalHTML: wasLocalHTML)
      if !wasLocalHTML {
        lastRequestedURL = url
      }
      applyToolbarURL(url, isSecure: Self.isSecure(url, in: webView))
    } else {
      committedPage = nil
      lastRequestedURL = nil
      toolbar.rawURL = ""
      toolbar.displayURL = nil
    }
    syncToolbarStatus(from: webView)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    syncNavigationState()
    onNavigationFinish?()
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    syncNavigationState()
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    if let navigation {
      supersededNavigations.remove(navigation)
    }
    guard let pending = pendingNavigation, pending.matches(navigation) else {
      syncToolbarStatus(from: webView)
      return
    }
    pendingNavigation = nil
    restoreLastRequestedURLToCommitted()
    syncNavigationState()
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    pendingNavigation = nil
    supersededNavigations.removeAllObjects()
    restoreLastRequestedURLToCommitted()
    toolbar.isLoading = false
    toolbar.estimatedProgress = 0
    if let committed = committedPage {
      applyToolbarURL(committed.url, isSecure: Self.isSecure(committed.url, in: webView))
    } else if let requested = lastRequestedURL {
      applyToolbarURL(requested, isSecure: false)
    }
  }

  func webView(
    _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    guard navigationAction.targetFrame == nil,
      Self.isValidHTTPNavigationURL(navigationAction.request.url),
      navigationAction.sourceFrame.isMainFrame
        || isSameOriginAsMainFrame(navigationAction.sourceFrame.securityOrigin)
    else { return nil }
    let url = navigationAction.request.url
    if let url {
      lastRequestedURL = url
    }
    let navigation = webView.load(navigationAction.request)
    beginPendingNavigation(navigation, requestedURL: url, isLocalHTML: false, allowsBlank: false)
    return nil
  }

  static let allowedSubframeSchemes: Set<String> = [
    "http", "https", "about", "data", "blob",
  ]

  static func isSecure(_ url: URL, in webView: WKWebView) -> Bool {
    url.scheme?.lowercased() == "https" && webView.hasOnlySecureContent
  }

  static func isValidHTTPNavigationURL(_ url: URL?) -> Bool {
    guard let url,
      let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      let host = url.host, !host.isEmpty
    else { return false }
    return true
  }

  static func effectivePort(scheme: String, port: Int?) -> Int? {
    if let port, port > 0 { return port }
    switch scheme {
    case "http": return 80
    case "https": return 443
    default: return nil
    }
  }

  static func normalizedOriginHost(_ host: String) -> String {
    let lower = host.lowercased()
    if lower.hasPrefix("["), lower.hasSuffix("]"), lower.count >= 2 {
      return String(lower.dropFirst().dropLast())
    }
    return lower
  }

  static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
    guard let lhsScheme = lhs.scheme?.lowercased(),
      let rhsScheme = rhs.scheme?.lowercased(),
      lhsScheme == rhsScheme,
      let lhsHost = lhs.host, !lhsHost.isEmpty,
      let rhsHost = rhs.host, !rhsHost.isEmpty,
      normalizedOriginHost(lhsHost) == normalizedOriginHost(rhsHost)
    else { return false }
    return effectivePort(scheme: lhsScheme, port: lhs.port)
      == effectivePort(scheme: rhsScheme, port: rhs.port)
  }

  private func isSameOriginAsMainFrame(_ sourceOrigin: WKSecurityOrigin) -> Bool {
    guard let mainURL = committedURL ?? webView?.url,
      let mainScheme = mainURL.scheme?.lowercased(),
      mainScheme == "http" || mainScheme == "https",
      let mainHost = mainURL.host, !mainHost.isEmpty
    else { return false }
    let sourceScheme = sourceOrigin.protocol.lowercased()
    let sourceHost = sourceOrigin.host
    guard !sourceScheme.isEmpty, !sourceHost.isEmpty,
      sourceScheme == mainScheme,
      Self.normalizedOriginHost(sourceHost) == Self.normalizedOriginHost(mainHost)
    else { return false }
    return Self.effectivePort(scheme: sourceScheme, port: sourceOrigin.port)
      == Self.effectivePort(scheme: mainScheme, port: mainURL.port)
  }

  func webView(
    _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void
  ) {
    completionHandler()
  }

  func webView(
    _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void
  ) {
    completionHandler(false)
  }

  func webView(
    _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
    defaultText: String?, initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping @MainActor (String?) -> Void
  ) {
    completionHandler(nil)
  }
}
