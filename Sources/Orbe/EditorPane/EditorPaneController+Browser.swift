import AppKit
import WebKit

/// EditorPaneController の埋め込みブラウザ担当。dev サーバー検出のポーリングと WKWebView 操作・
/// ライブ状態の反映を受け持つ（ブラウザ操作の唯一の入口）。状態は本体クラスに置く。
extension EditorPaneController {
  // MARK: - EditorPaneActions（埋め込みブラウザ）

  func browserGoBack() { model.webView.goBack() }
  func browserGoForward() { model.webView.goForward() }
  func browserReload() { model.webView.reload() }

  func openBrowserExternally() {
    guard let url = model.browserDisplayURL ?? model.devServerURL else { return }
    NSWorkspace.shared.open(url)
  }

  /// browser ツールへ切替えた瞬間に dev サーバーを即再検出する（ポーリングの 3 秒を待たせない）。
  func browserActivated() {
    probeDevServer(rootChanged: false)
  }

  // MARK: - dev サーバー検出

  func startDevServerPolling() {
    stopDevServerPolling()
    devServerTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
      self?.probeDevServer(rootChanged: false)
    }
  }

  func stopDevServerPolling() {
    devServerTimer?.invalidate()
    devServerTimer = nil
  }

  /// 現在の root で dev サーバーを検出し、model と WKWebView へ反映する。
  /// `rootChanged` はプロジェクト切替時で、同一 URL でも再 load して新しい root の内容を取り直す。
  func probeDevServer(rootChanged: Bool) {
    guard let root = currentRoot else { return }
    DevServerProbe.shared.detect(repoRoot: root) { [weak self] url in
      guard let self, self.currentRoot == root else { return }
      self.applyDevServer(url, rootChanged: rootChanged)
    }
  }

  /// 検出結果を model・WKWebView へ投影する（ブラウザ操作の唯一の書き込み点）。
  private func applyDevServer(_ url: URL?, rootChanged: Bool) {
    let changed = url != model.devServerURL
    if changed { model.devServerURL = url }
    guard let url else {
      if changed {
        model.browserDisplayURL = nil
        model.browserCanGoBack = false
        model.browserCanGoForward = false
        browserLoadedURL = nil
      }
      return
    }
    guard changed || rootChanged || browserLoadedURL != url else { return }
    // ページ load はブラウザツール表示中のみ。非表示中は検出（devServerURL）だけ継続し裏で load しない。
    // 非表示中は browserLoadedURL を url へ進めないので、開いた瞬間の probe が上の browserLoadedURL != url を通り再びここに到達して load される。
    guard model.ui.paneOpen, model.ui.tool == .browser else { return }
    ensureBrowserObservers()
    browserLoadedURL = url
    model.browserDisplayURL = url
    model.webView.load(URLRequest(url: url))
  }

  /// WKWebView の canGoBack/canGoForward/現在 URL を model へ写す KVO を一度だけ張る。
  private func ensureBrowserObservers() {
    guard browserObservers.isEmpty else { return }
    let webView = model.webView
    browserObservers = [
      webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] webView, _ in
        self?.model.browserCanGoBack = webView.canGoBack
      },
      webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] webView, _ in
        self?.model.browserCanGoForward = webView.canGoForward
      },
      webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
        guard let self else { return }
        self.model.browserDisplayURL = webView.url ?? self.model.devServerURL
      },
    ]
  }
}
