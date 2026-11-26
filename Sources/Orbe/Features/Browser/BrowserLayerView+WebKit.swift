import AppKit
import WebKit

/// `BrowserLayerView` の WebKit 遅延生成・遷移・URL インライン編集・`WKNavigationDelegate` / `WKUIDelegate`。
extension BrowserLayerView: WKNavigationDelegate, WKUIDelegate {
  /// 初回表示時に 1 回だけ `WKWebView` を生成する。`BrowserDataStore.make()` で隔離する。
  @discardableResult
  func ensureWebView() -> WKWebView {
    if let webView { return webView }
    let config = WKWebViewConfiguration()
    config.websiteDataStore = BrowserDataStore.make()
    config.preferences.javaScriptCanOpenWindowsAutomatically = false
    let view = WKWebView(frame: belowBar.bounds, configuration: config)
    view.autoresizingMask = [.width, .height]
    view.navigationDelegate = self
    view.uiDelegate = self
    effectiveAppearance.performAsCurrentDrawingAppearance {
      view.underPageBackgroundColor = Theme.Color.bgBase
    }
    belowBar.addSubview(view, positioned: .above, relativeTo: belowGround)
    kvoObservations = [
      view.observe(\.url, options: [.new]) { [weak self] _, _ in
        DispatchQueue.main.async { self?.syncNavigationState() }
      },
      view.observe(\.hasOnlySecureContent, options: [.new]) { [weak self] _, _ in
        DispatchQueue.main.async { self?.syncNavigationState() }
      },
      view.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
        DispatchQueue.main.async { self?.syncNavigationState() }
      },
      view.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
        DispatchQueue.main.async { self?.syncNavigationState() }
      },
      view.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
        DispatchQueue.main.async { self?.syncNavigationState() }
      },
      view.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in
        DispatchQueue.main.async { self?.syncNavigationState() }
      },
    ]
    webView = view
    return view
  }

  func load(_ url: URL) {
    let view = ensureWebView()
    hasNavigated = true
    emptyOverlay.isHidden = true
    lastRequestedURL = url
    isLocalHTMLNavigation = false
    allowingInternalBlankLoad = false
    if committedURL == nil {
      applyToolbarURL(url, isSecure: false)
    }
    view.load(URLRequest(url: url))
  }

  /// ローカル HTML を外部通信なしで読み込む（`visual-check`・テスト用）。
  func loadHTMLString(_ html: String, baseURL: URL?) {
    let view = ensureWebView()
    hasNavigated = true
    emptyOverlay.isHidden = true
    lastRequestedURL = nil
    isLocalHTMLNavigation = true
    allowingInternalBlankLoad = (baseURL == nil)
    if committedURL == nil, let baseURL {
      applyToolbarURL(baseURL, isSecure: false)
    }
    view.loadHTMLString(html, baseURL: baseURL)
  }

  func reloadPage() {
    guard hasNavigated, let webView else { return }
    if webView.url == nil || webView.reload() == nil {
      if let url = lastRequestedURL {
        load(url)
      }
    }
  }

  func reloadOrStop() {
    guard hasNavigated else { return }
    if toolbar.isLoading {
      webView?.stopLoading()
    } else {
      reloadPage()
    }
  }

  private func applyToolbarURL(_ url: URL, isSecure: Bool) {
    toolbar.rawURL = url.absoluteString
    toolbar.displayURL = BrowserURLInput.display(url, isSecure: isSecure)
  }

  private func syncNavigationState() {
    guard let webView else { return }
    if hasNavigated, !isProvisionalNavigation {
      if let committed = committedURL {
        if let liveURL = webView.url,
          liveURL.scheme?.lowercased() != "about",
          Self.isSameOrigin(liveURL, committed)
        {
          committedURL = liveURL
          if lastRequestedURL != nil {
            lastRequestedURL = liveURL
          }
          applyToolbarURL(liveURL, isSecure: Self.isSecure(liveURL, in: webView))
        } else {
          applyToolbarURL(committed, isSecure: Self.isSecure(committed, in: webView))
        }
      } else if let requested = lastRequestedURL {
        applyToolbarURL(requested, isSecure: false)
      }
    }
    toolbar.canGoBack = webView.canGoBack
    toolbar.canGoForward = webView.canGoForward
    toolbar.isLoading = webView.isLoading
    toolbar.estimatedProgress = webView.estimatedProgress
  }

  // MARK: - URL インライン編集

  func beginURLEditing() {
    toolbar.editingText = toolbar.rawURL
    toolbar.isEditingURL = true
    toolbar.editSessionToken &+= 1
  }

  /// 明示確定（Enter）。有効な URL なら遷移して編集を閉じ `focusTarget` へ戻す。無効なら編集欄に留まる。
  func commitURLEditing(_ text: String) -> Bool {
    guard let url = BrowserURLInput.resolve(text) else {
      NSSound.beep()
      return false
    }
    toolbar.isEditingURL = false
    load(url)
    focusBrowser()
    return true
  }

  /// 明示取消（Esc）。編集を閉じて `focusTarget` へ戻す。
  func cancelURLEditing() {
    toolbar.isEditingURL = false
    toolbar.editingText = toolbar.rawURL
    focusBrowser()
  }

  /// 外因終了（blur・`⌘B` 閉鎖・ボタン押下・モード変更）。焦点は動かさず編集状態のみ解除する。
  func endURLEditingExternally() {
    guard toolbar.isEditingURL else { return }
    toolbar.isEditingURL = false
    toolbar.editingText = toolbar.rawURL
  }

  // MARK: - WKNavigationDelegate / WKUIDelegate

  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    let isMainOrNew = navigationAction.targetFrame?.isMainFrame ?? true
    let url = navigationAction.request.url
    let scheme = url?.scheme?.lowercased()
    if isMainOrNew {
      if scheme == "http" || scheme == "https" {
        decisionHandler(.allow)
      } else if allowingInternalBlankLoad, url?.absoluteString == "about:blank" {
        allowingInternalBlankLoad = false
        decisionHandler(.allow)
      } else {
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
    isProvisionalNavigation = true
    syncNavigationState()
  }

  func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    isProvisionalNavigation = false
    allowingInternalBlankLoad = false
    let wasLocalHTML = isLocalHTMLNavigation
    isLocalHTMLNavigation = false
    if let url = webView.url, url.scheme?.lowercased() != "about" {
      committedURL = url
      if !wasLocalHTML {
        lastRequestedURL = url
      }
      applyToolbarURL(url, isSecure: Self.isSecure(url, in: webView))
    } else {
      committedURL = nil
      toolbar.rawURL = ""
      toolbar.displayURL = nil
    }
    syncNavigationState()
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    syncNavigationState()
    onNavigationFinish?()
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    isProvisionalNavigation = false
    syncNavigationState()
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    isProvisionalNavigation = false
    allowingInternalBlankLoad = false
    isLocalHTMLNavigation = false
    if let committed = committedURL {
      lastRequestedURL = committed
    }
    syncNavigationState()
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    isProvisionalNavigation = false
    allowingInternalBlankLoad = false
    isLocalHTMLNavigation = false
    toolbar.isLoading = false
    toolbar.estimatedProgress = 0
    if let committed = committedURL {
      applyToolbarURL(committed, isSecure: Self.isSecure(committed, in: webView))
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
    webView.load(navigationAction.request)
    return nil
  }

  private static let allowedSubframeSchemes: Set<String> = [
    "http", "https", "about", "data", "blob",
  ]

  private static func isSecure(_ url: URL, in webView: WKWebView) -> Bool {
    url.scheme?.lowercased() == "https" && webView.hasOnlySecureContent
  }

  private static func isValidHTTPNavigationURL(_ url: URL?) -> Bool {
    guard let url,
      let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      let host = url.host, !host.isEmpty
    else { return false }
    return true
  }

  private static func effectivePort(scheme: String, port: Int?) -> Int? {
    if let port, port > 0 { return port }
    switch scheme {
    case "http": return 80
    case "https": return 443
    default: return nil
    }
  }

  private static func normalizedOriginHost(_ host: String) -> String {
    let lower = host.lowercased()
    if lower.hasPrefix("["), lower.hasSuffix("]"), lower.count >= 2 {
      return String(lower.dropFirst().dropLast())
    }
    return lower
  }

  private static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
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
    initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void
  ) {
    completionHandler()
  }

  func webView(
    _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void
  ) {
    completionHandler(false)
  }

  func webView(
    _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
    defaultText: String?, initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping (String?) -> Void
  ) {
    completionHandler(nil)
  }
}
