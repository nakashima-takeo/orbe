import WebKit

/// `BrowserTabRuntime` の遷移追跡モデルとナビゲーション状態同期。
extension BrowserTabRuntime {
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

  /// `WKNavigation` のオブジェクト同一性をキーに `NavigationMeta` を弱参照管理するストア。
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

  func allowsSameDocumentHistoryCompletion(to targetURL: URL?) -> Bool {
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

  func applyURLState(_ url: URL, isSecure: Bool) {
    rawURL = url.absoluteString
    displayURL = BrowserURLInput.display(url, isSecure: isSecure)
  }

  func syncWebViewStatus() {
    canGoBack = webView.canGoBack
    canGoForward = webView.canGoForward
    isLoading = webView.isLoading
    estimatedProgress = webView.estimatedProgress
  }

  func syncTitleFromWebView() {
    guard let committed = committedPage, !committed.isLocalHTML, !isProvisionalNavigation else {
      return
    }
    let liveTitle = (webView.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !liveTitle.isEmpty, liveTitle != title else { return }
    title = liveTitle
    onTitleChange?(liveTitle)
  }

  func notifyStateChange() {
    guard !isInvalidated else { return }
    onStateChange?()
  }

  func syncNavigationState() {
    guard !isInvalidated else { return }
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
          let urlChanged = liveURL != committed.url
          committedPage = CommittedPage(url: liveURL, isLocalHTML: committed.isLocalHTML)
          if !committed.isLocalHTML {
            lastRequestedURL = liveURL
            if urlChanged, BrowserURLInput.isValidHTTPNavigationURL(liveURL) {
              onCommittedNavigation?(liveURL, nil)
            }
          }
          applyURLState(liveURL, isSecure: Self.isSecure(liveURL, in: webView))
        } else {
          applyURLState(committed.url, isSecure: Self.isSecure(committed.url, in: webView))
        }
      } else if let requested = lastRequestedURL {
        applyURLState(requested, isSecure: false)
      }
    }
    syncWebViewStatus()
    syncTitleFromWebView()
    notifyStateChange()
  }
}
