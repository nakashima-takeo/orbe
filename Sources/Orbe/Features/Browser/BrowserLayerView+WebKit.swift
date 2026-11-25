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
    toolbar.rawURL = url.absoluteString
    toolbar.displayURL = BrowserURLInput.display(url)
    view.load(URLRequest(url: url))
  }

  /// ローカル HTML を外部通信なしで読み込む（`visual-check`・テスト用）。
  func loadHTMLString(_ html: String, baseURL: URL?) {
    let view = ensureWebView()
    hasNavigated = true
    emptyOverlay.isHidden = true
    if let baseURL {
      toolbar.rawURL = baseURL.absoluteString
      toolbar.displayURL = BrowserURLInput.display(baseURL)
    }
    view.loadHTMLString(html, baseURL: baseURL)
  }

  func reloadPage() {
    guard hasNavigated else { return }
    webView?.reload()
  }

  func reloadOrStop() {
    guard hasNavigated else { return }
    if toolbar.isLoading {
      webView?.stopLoading()
    } else {
      webView?.reload()
    }
  }

  private func syncNavigationState() {
    guard let webView else { return }
    if hasNavigated, let url = webView.url, url.scheme?.lowercased() != "about" {
      toolbar.rawURL = url.absoluteString
      toolbar.displayURL = BrowserURLInput.display(url)
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

  func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    syncNavigationState()
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
    syncNavigationState()
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    toolbar.isLoading = false
    toolbar.estimatedProgress = 0
  }

  func webView(
    _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    if navigationAction.targetFrame == nil {
      webView.load(navigationAction.request)
    }
    return nil
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
