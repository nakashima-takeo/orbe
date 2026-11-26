import AppKit
import SwiftUI

/// 左端ドラッグ中にシート左内側へ浮かべるスナップ表示ピル（比率% / 全面に吸着 / 離すと閉じる）。
/// host をシート全面に張り SwiftUI 側で左寄せ中央配置することで、文言変化時の `fittingSize` ずれや
/// 影クリップを構造的に防ぐ。
struct BrowserSnapBadge: View {
  let model: BrowserSnapBadgeModel
  let localization: LocalizationStore

  var body: some View {
    ZStack(alignment: .leading) {
      if let kind = model.kind {
        Text(label(for: kind))
          .font(Font.theme.browserSnapBadge)
          .foregroundStyle(Color.theme.textPrimary)
          .lineLimit(1)
          .fixedSize()
          .padding(.horizontal, Theme.Layout.browserSnapBadgePadX)
          .padding(.vertical, Theme.Layout.browserSnapBadgePadY)
          .background(
            RoundedRectangle(cornerRadius: Theme.Layout.browserSnapBadgeRadius)
              .fill(Color(nsColor: Theme.Glass.surface(.help)))
          )
          .overlay(
            RoundedRectangle(cornerRadius: Theme.Layout.browserSnapBadgeRadius)
              .strokeBorder(
                Color.theme.accentPrimary.opacity(Theme.Opacity.browserSnapBadgeBorder),
                lineWidth: Theme.Stroke.hairline)
          )
          .elevation(.popup)
          .padding(.leading, Theme.Layout.browserSnapBadgeLeading)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
  }

  private func label(for kind: BrowserResizeSession.SnapBadgeKind) -> String {
    switch kind {
    case .percent(let value): "\(value)%"
    case .snapFull: localization.string(.browserSnapFull)
    case .snapClose: localization.string(.browserSnapClose)
    }
  }
}

/// スナップバッジの host。非対話のため hitTest は常に nil。
final class BrowserSnapBadgeHost: NSHostingView<BrowserSnapBadge> {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
