import AppKit
import WebKit

/// `BrowserLayerView` のアクティブ `BrowserTabRuntime` マウント・ツールバー投影・遷移委譲・URL インライン編集。
extension BrowserLayerView {
  /// アクティブタブの実行体を `belowBar` へ差し替え、空画面・ツールバー・焦点を同期する。
  func mountRuntime(_ next: BrowserTabRuntime?) {
    if mountedRuntime === next {
      emptyOverlay.isHidden = next?.hasNavigated ?? false
      syncToolbar(from: next)
      return
    }
    let wasFocused = focusIsInside
    if isEditingURL {
      endURLEditingExternally()
    }
    mountedRuntime?.webView.removeFromSuperview()
    mountedRuntime = next
    clearWebSnapshot()
    if let next {
      next.applyAppearance(effectiveAppearance)
      next.webView.frame = belowBar.bounds
      next.webView.autoresizingMask = [.width, .height]
      belowBar.addSubview(next.webView, positioned: .above, relativeTo: belowGround)
      emptyOverlay.isHidden = next.hasNavigated
    } else {
      emptyOverlay.isHidden = false
    }
    syncToolbar(from: next)
    if mode.isOpen && wasFocused {
      focusBrowser()
    }
  }

  func syncToolbar(from runtime: BrowserTabRuntime?) {
    if let runtime {
      toolbar.rawURL = runtime.rawURL
      toolbar.displayURL = runtime.displayURL
      toolbar.canGoBack = runtime.canGoBack
      toolbar.canGoForward = runtime.canGoForward
      toolbar.isLoading = runtime.isLoading
      toolbar.estimatedProgress = runtime.estimatedProgress
    } else if let url = session.store.activeTab?.url {
      toolbar.rawURL = url.absoluteString
      toolbar.displayURL = BrowserURLInput.display(url, isSecure: false)
      toolbar.canGoBack = false
      toolbar.canGoForward = false
      toolbar.isLoading = false
      toolbar.estimatedProgress = 0
    } else {
      toolbar.rawURL = ""
      toolbar.displayURL = nil
      toolbar.canGoBack = false
      toolbar.canGoForward = false
      toolbar.isLoading = false
      toolbar.estimatedProgress = 0
    }
  }

  // MARK: - 遷移操作（session へ委譲）

  func load(_ url: URL) {
    session.load(url)
  }

  func loadHTMLString(_ html: String, baseURL: URL?) {
    session.loadHTMLString(html, baseURL: baseURL)
  }

  func goBack() {
    session.goBack()
  }

  func goForward() {
    session.goForward()
  }

  func reloadPage() {
    session.reloadPage()
  }

  func reloadOrStop() {
    session.reloadOrStop()
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
