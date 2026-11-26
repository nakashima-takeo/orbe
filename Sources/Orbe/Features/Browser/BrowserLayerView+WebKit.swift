import AppKit
import WebKit

/// `BrowserLayerView` の WebKit 遅延生成・遷移操作・ナビゲーション状態同期・URL インライン編集。
extension BrowserLayerView {
  struct CommittedPage {
    let url: URL
    let isLocalHTML: Bool
  }

  /// API 発行・暫定開始した `WKNavigation` の最小メタデータ。
  /// 後続遷移へ差し替わった先行遷移が後から `didCommit` してもローカル HTML 判定や最新到達 URL を復元する。
  struct NavigationMeta {
    let requestedURL: URL?
    let isLocalHTML: Bool
    var isSuperseded = false
    var latestURL: URL?
    weak var initialBackForwardItem: WKBackForwardListItem?
    var initialBackForwardURL: URL?
  }

  private struct NavigationMetadataEntry {
    weak var navigation: WKNavigation?
    var meta: NavigationMeta
  }

  /// `WKNavigation` のオブジェクト同一性をキーに `NavigationMeta` を弱参照管理する薄いストア。
  struct NavigationMetadataStore {
    private var entries: [ObjectIdentifier: NavigationMetadataEntry] = [:]

    subscript(_ navigation: WKNavigation) -> NavigationMeta? {
      get {
        guard let entry = entries[ObjectIdentifier(navigation)],
          entry.navigation === navigation
        else { return nil }
        return entry.meta
      }
      set {
        purgeReleased()
        let key = ObjectIdentifier(navigation)
        if let newValue {
          entries[key] = NavigationMetadataEntry(navigation: navigation, meta: newValue)
        } else if entries[key]?.navigation === navigation {
          entries.removeValue(forKey: key)
        }
      }
    }

    mutating func update(for navigation: WKNavigation, _ body: (inout NavigationMeta) -> Void) {
      purgeReleased()
      let key = ObjectIdentifier(navigation)
      guard var entry = entries[key], entry.navigation === navigation else { return }
      body(&entry.meta)
      entries[key] = entry
    }

    @discardableResult
    mutating func removeValue(for navigation: WKNavigation) -> NavigationMeta? {
      purgeReleased()
      let key = ObjectIdentifier(navigation)
      guard entries[key]?.navigation === navigation else { return nil }
      return entries.removeValue(forKey: key)?.meta
    }

    mutating func removeAll() {
      entries.removeAll()
    }

    private mutating func purgeReleased() {
      guard entries.values.contains(where: { $0.navigation == nil }) else { return }
      entries = entries.filter { $0.value.navigation != nil }
    }
  }

  /// 進行中ナビゲーションを `WKNavigation` 単位で追跡し、重複遷移の旧キャンセル通知や
  /// `didStartProvisionalNavigation` 前の KVO 窓から状態と URL 欄を保護する。
  struct PendingNavigation {
    weak var navigation: WKNavigation?
    let requestedURL: URL?
    let isLocalHTML: Bool
    var allowsInternalBlankLoad: Bool
    let allowsSameDocumentCompletion: Bool
    var didStartProvisional: Bool
    weak var initialBackForwardItem: WKBackForwardListItem?

    init(
      navigation: WKNavigation?,
      requestedURL: URL?,
      isLocalHTML: Bool = false,
      allowsInternalBlankLoad: Bool = false,
      allowsSameDocumentCompletion: Bool = false,
      didStartProvisional: Bool = false,
      initialBackForwardItem: WKBackForwardListItem?
    ) {
      self.navigation = navigation
      self.requestedURL = requestedURL
      self.isLocalHTML = isLocalHTML
      self.allowsInternalBlankLoad = allowsInternalBlankLoad
      self.allowsSameDocumentCompletion = allowsSameDocumentCompletion
      self.didStartProvisional = didStartProvisional
      self.initialBackForwardItem = initialBackForwardItem
    }

    func matches(_ other: WKNavigation?) -> Bool {
      guard let navigation, let other else { return false }
      return navigation === other
    }
  }

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
    if committedPage == nil {
      applyToolbarURL(url, isSecure: false)
    }
    let initialItem = view.backForwardList.currentItem
    let allowsSameDocument = allowsSameDocumentLoadCompletion(to: url, in: view)
    let navigation = view.load(URLRequest(url: url))
    beginPendingNavigation(
      PendingNavigation(
        navigation: navigation, requestedURL: url,
        allowsSameDocumentCompletion: allowsSameDocument,
        initialBackForwardItem: initialItem))
  }

  /// ローカル HTML を外部通信なしで読み込む（`visual-check`・テスト用）。
  func loadHTMLString(_ html: String, baseURL: URL?) {
    let view = ensureWebView()
    hasNavigated = true
    emptyOverlay.isHidden = true
    lastRequestedURL = nil
    if committedPage == nil, let baseURL {
      applyToolbarURL(baseURL, isSecure: false)
    }
    let initialItem = view.backForwardList.currentItem
    let navigation = view.loadHTMLString(html, baseURL: baseURL)
    beginPendingNavigation(
      PendingNavigation(
        navigation: navigation, requestedURL: baseURL ?? URL(string: "about:blank"),
        isLocalHTML: true, allowsInternalBlankLoad: baseURL == nil,
        initialBackForwardItem: initialItem))
  }

  func goBack() {
    guard let webView else { return }
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
    guard let webView else { return }
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
    guard hasNavigated, let webView else { return }
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
    guard hasNavigated else { return }
    if toolbar.isLoading {
      webView?.stopLoading()
    } else {
      reloadPage()
    }
  }

  func beginPendingNavigation(_ pending: PendingNavigation) {
    guard let navigation = pending.navigation else { return }
    if let previous = pendingNavigation, !previous.matches(navigation) {
      markSuperseded(previous)
    }
    navigationMetadata[navigation] = NavigationMeta(
      requestedURL: pending.requestedURL, isLocalHTML: pending.isLocalHTML,
      initialBackForwardItem: pending.initialBackForwardItem,
      initialBackForwardURL: pending.initialBackForwardItem?.url)
    pendingNavigation = pending
  }

  func allowsSameDocumentLoadCompletion(to url: URL?, in webView: WKWebView) -> Bool {
    guard let committed = committedPage, !committed.isLocalHTML,
      let url, url.fragment != nil,
      let currentURL = webView.url ?? committedPage?.url,
      let normalizedTarget = Self.normalizedURLWithoutFragment(url),
      let normalizedCurrent = Self.normalizedURLWithoutFragment(currentURL)
    else { return false }
    return normalizedTarget == normalizedCurrent
  }

  private func allowsSameDocumentHistoryCompletion(to targetURL: URL?) -> Bool {
    guard let targetURL, let committedURL = committedPage?.url else { return false }
    return Self.isSameOrigin(targetURL, committedURL)
  }

  func markSuperseded(_ pending: PendingNavigation) {
    guard let navigation = pending.navigation else { return }
    if navigationMetadata[navigation] != nil {
      navigationMetadata.update(for: navigation) { $0.isSuperseded = true }
    } else {
      navigationMetadata[navigation] = NavigationMeta(
        requestedURL: pending.requestedURL, isLocalHTML: pending.isLocalHTML,
        isSuperseded: true,
        initialBackForwardItem: pending.initialBackForwardItem,
        initialBackForwardURL: pending.initialBackForwardItem?.url)
    }
  }

  func restoreLastRequestedURLToCommitted() {
    guard let committed = committedPage else { return }
    lastRequestedURL = committed.isLocalHTML ? nil : committed.url
  }

  func clearUnstartedPendingNavigationIfMatching(_ url: URL?) {
    guard let pending = pendingNavigation, !pending.didStartProvisional else { return }
    guard pending.requestedURL == nil || pending.requestedURL == url else { return }
    if let navigation = pending.navigation {
      navigationMetadata.removeValue(for: navigation)
    }
    pendingNavigation = nil
    restoreLastRequestedURLToCommitted()
    syncNavigationState()
  }

  func applyToolbarURL(_ url: URL, isSecure: Bool) {
    toolbar.rawURL = url.absoluteString
    toolbar.displayURL = BrowserURLInput.display(url, isSecure: isSecure)
  }

  func syncToolbarStatus(from webView: WKWebView) {
    toolbar.canGoBack = webView.canGoBack
    toolbar.canGoForward = webView.canGoForward
    toolbar.isLoading = webView.isLoading
    toolbar.estimatedProgress = webView.estimatedProgress
  }

  func syncNavigationState() {
    guard let webView else { return }
    // 同一文書遷移（pushState の goBack / goForward や #hash 移動）は非 nil の WKNavigation を返しつつ
    // didStartProvisionalNavigation・didCommit・didFinish を発火せず isLoading = false のみで完了する。
    // 完了済みの同一文書遷移だけをここで回収し、連続 API 遷移キャンセル時の過渡的な isLoading == false 窓では消さない。
    if let pending = pendingNavigation,
      !pending.didStartProvisional,
      !pending.isLocalHTML,
      pending.allowsSameDocumentCompletion,
      !webView.isLoading,
      let committed = committedPage,
      let currentItem = webView.backForwardList.currentItem,
      currentItem !== pending.initialBackForwardItem,
      let liveURL = webView.url,
      currentItem.url == liveURL,
      Self.isSameOrigin(liveURL, committed.url)
    {
      if let navigation = pending.navigation {
        navigationMetadata.removeValue(for: navigation)
      }
      pendingNavigation = nil
      restoreLastRequestedURLToCommitted()
    }
    if hasNavigated, !isProvisionalNavigation {
      if let committed = committedPage {
        if let liveURL = webView.url,
          liveURL.scheme?.lowercased() != "about",
          webView.backForwardList.currentItem?.url == liveURL,
          Self.isSameOrigin(liveURL, committed.url)
        {
          committedPage = CommittedPage(url: liveURL, isLocalHTML: committed.isLocalHTML)
          if !committed.isLocalHTML {
            lastRequestedURL = liveURL
          }
          applyToolbarURL(liveURL, isSecure: Self.isSecure(liveURL, in: webView))
        } else {
          applyToolbarURL(committed.url, isSecure: Self.isSecure(committed.url, in: webView))
        }
      } else if let requested = lastRequestedURL {
        applyToolbarURL(requested, isSecure: false)
      }
    }
    syncToolbarStatus(from: webView)
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
}
