import AppKit
import WebKit

/// タブ 1 枚に対応する WebKit 実行単位。
/// `WKWebView` 1 枚と遷移状態機械・KVO 7 本を所有し、破棄やプロファイル切替時は `invalidate()` で確実に解放する。
@MainActor
final class BrowserTabRuntime: NSObject {
  let tabId: UUID
  let profileId: UUID
  let webView: WKWebView

  private(set) var isInvalidated = false
  var hasNavigated = false
  var committedPage: CommittedPage?
  var committedURL: URL? { committedPage?.url }
  var lastRequestedURL: URL?
  var pendingNavigation: PendingNavigation?
  var navigationMetadata = NavigationMetadataStore()
  var isProvisionalNavigation: Bool { pendingNavigation != nil }

  var rawURL: String = ""
  var displayURL: BrowserDisplayURL?
  var title: String = ""
  var canGoBack = false
  var canGoForward = false
  var isLoading = false
  var estimatedProgress: Double = 0

  var onStateChange: (() -> Void)?
  var onCommittedNavigation: ((URL, String?) -> Void)?
  var onTitleChange: ((String) -> Void)?
  var onNavigationFinish: (() -> Void)?

  private var kvoObservations: [NSKeyValueObservation] = []

  init(tabId: UUID, profileId: UUID, dataStore: WKWebsiteDataStore) {
    self.tabId = tabId
    self.profileId = profileId
    let config = WKWebViewConfiguration()
    config.websiteDataStore = dataStore
    config.preferences.javaScriptCanOpenWindowsAutomatically = false
    let view = WKWebView(frame: .zero, configuration: config)
    view.autoresizingMask = [.width, .height]
    self.webView = view
    super.init()
    view.navigationDelegate = self
    view.uiDelegate = self
    kvoObservations = [
      view.observe(\.url, options: [.new]) { [weak self] _, _ in
        DispatchQueue.main.async { self?.syncNavigationStateIfValid() }
      },
      view.observe(\.title, options: [.new]) { [weak self] _, _ in
        DispatchQueue.main.async { self?.syncNavigationStateIfValid() }
      },
      view.observe(\.hasOnlySecureContent, options: [.new]) { [weak self] _, _ in
        DispatchQueue.main.async { self?.syncNavigationStateIfValid() }
      },
      view.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
        DispatchQueue.main.async { self?.syncNavigationStateIfValid() }
      },
      view.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
        DispatchQueue.main.async { self?.syncNavigationStateIfValid() }
      },
      view.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
        DispatchQueue.main.async { self?.syncNavigationStateIfValid() }
      },
      view.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in
        DispatchQueue.main.async { self?.syncNavigationStateIfValid() }
      },
    ]
  }

  deinit {
    for obs in kvoObservations { obs.invalidate() }
  }

  func applyAppearance(_ appearance: NSAppearance) {
    appearance.performAsCurrentDrawingAppearance {
      webView.underPageBackgroundColor = Theme.Color.bgBase
    }
  }

  func invalidate() {
    guard !isInvalidated else { return }
    isInvalidated = true
    for obs in kvoObservations { obs.invalidate() }
    kvoObservations.removeAll()
    webView.stopLoading()
    webView.navigationDelegate = nil
    webView.uiDelegate = nil
    webView.removeFromSuperview()
    pendingNavigation = nil
    navigationMetadata.removeAll()
    onStateChange = nil
    onCommittedNavigation = nil
    onTitleChange = nil
    onNavigationFinish = nil
  }

  // MARK: - 遷移操作

  func load(_ url: URL, notify: Bool = true) {
    guard !isInvalidated else { return }
    hasNavigated = true
    lastRequestedURL = url
    if committedPage == nil {
      applyURLState(url, isSecure: false)
    }
    let initialItem = webView.backForwardList.currentItem
    let allowsSameDocument = allowsSameDocumentLoadCompletion(to: url, in: webView)
    let navigation = webView.load(URLRequest(url: url))
    beginPendingNavigation(
      PendingNavigation(
        navigation: navigation, requestedURL: url,
        allowsSameDocumentCompletion: allowsSameDocument,
        initialBackForwardItem: initialItem))
    if notify { notifyStateChange() }
  }

  /// ローカル HTML を外部通信なしで読み込む（`visual-check`・テスト用）。
  func loadHTMLString(_ html: String, baseURL: URL?, notify: Bool = true) {
    guard !isInvalidated else { return }
    hasNavigated = true
    lastRequestedURL = nil
    if committedPage == nil, let baseURL {
      applyURLState(baseURL, isSecure: false)
    }
    let initialItem = webView.backForwardList.currentItem
    let navigation = webView.loadHTMLString(html, baseURL: baseURL)
    beginPendingNavigation(
      PendingNavigation(
        navigation: navigation, requestedURL: baseURL ?? URL(string: "about:blank"),
        isLocalHTML: true, allowsInternalBlankLoad: baseURL == nil,
        initialBackForwardItem: initialItem))
    if notify { notifyStateChange() }
  }

  func goBack() {
    guard !isInvalidated else { return }
    let initialItem = webView.backForwardList.currentItem
    let targetURL = webView.backForwardList.backItem?.url
    let allowsSameDocument = allowsSameDocumentHistoryCompletion(to: targetURL)
    let navigation = webView.goBack()
    beginPendingNavigation(
      PendingNavigation(
        navigation: navigation, requestedURL: targetURL,
        allowsSameDocumentCompletion: allowsSameDocument,
        initialBackForwardItem: initialItem))
  }

  func goForward() {
    guard !isInvalidated else { return }
    let initialItem = webView.backForwardList.currentItem
    let targetURL = webView.backForwardList.forwardItem?.url
    let allowsSameDocument = allowsSameDocumentHistoryCompletion(to: targetURL)
    let navigation = webView.goForward()
    beginPendingNavigation(
      PendingNavigation(
        navigation: navigation, requestedURL: targetURL,
        allowsSameDocumentCompletion: allowsSameDocument,
        initialBackForwardItem: initialItem))
  }

  func reloadPage() {
    guard !isInvalidated, hasNavigated else { return }
    if committedPage == nil, let url = lastRequestedURL {
      load(url)
      return
    }
    if let committed = committedPage, !committed.isLocalHTML, webView.url != committed.url {
      load(committed.url)
      return
    }
    let initialItem = webView.backForwardList.currentItem
    if webView.url != nil, let navigation = webView.reload() {
      beginPendingNavigation(
        PendingNavigation(
          navigation: navigation, requestedURL: webView.url ?? committedPage?.url,
          isLocalHTML: committedPage?.isLocalHTML ?? false,
          initialBackForwardItem: initialItem))
    } else if let url = lastRequestedURL {
      load(url)
    }
  }

  func reloadOrStop() {
    guard !isInvalidated, hasNavigated else { return }
    if isLoading || webView.isLoading {
      webView.stopLoading()
    } else {
      reloadPage()
    }
  }

  private func syncNavigationStateIfValid() {
    guard !isInvalidated else { return }
    syncNavigationState()
  }
}
