import AppKit
import WebKit

/// `visual-check` 撮影用フック。
/// 非表示 borderless `NSWindow` 上では `cacheDisplay(in:to:)` が `WKWebView` を白紙で描くため、
/// `WKWebView.takeSnapshot(with:)` で取得した画像を `belowBar` 内へ一時配置して合成する。
/// `belowBar` 配下に置くことで、全面 Peek（`belowBar.alphaValue = 0`）や右シート Peek でも同期して消える。
extension BrowserLayerView {
  /// 現在の `WKWebView` 表示内容を撮影し、`belowBar` の最前面へ一時合成する。
  func captureWebSnapshot(completion: @escaping (Bool) -> Void) {
    guard let webView else {
      completion(false)
      return
    }
    webView.takeSnapshot(with: nil) { [weak self] image, error in
      DispatchQueue.main.async {
        guard let self, error == nil, let image else {
          completion(false)
          return
        }
        let overlay = self.snapshotOverlay ?? NSImageView()
        overlay.imageScaling = .scaleAxesIndependently
        overlay.image = image
        overlay.frame = self.belowBar.bounds
        overlay.autoresizingMask = [.width, .height]
        if overlay.superview !== self.belowBar {
          self.belowBar.addSubview(overlay)
        }
        self.snapshotOverlay = overlay
        completion(true)
      }
    }
  }

  /// 一時合成したスナップショット面を除去する。
  func clearWebSnapshot() {
    snapshotOverlay?.removeFromSuperview()
    snapshotOverlay = nil
  }
}
