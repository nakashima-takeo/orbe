import AppKit
import SwiftUI

/// 一覧の器の SwiftUI の root——地・枠・影（popup の段のガラス）と下の案内。行は、pane が root の上へ重ねて置く行の列が
/// 描く。器の中の別 root なので環境は明示注入する。影を描くために、一覧の矩形の外側に `margin` の余白を取る。
struct EditorItemListRoot: View {
  let itemList: EditorItemList
  let localization: LocalizationStore
  let fontResolver: ChromeFontResolver
  let translucency: ChromeTranslucency

  /// 影を描く余白（popup の段の影の広がり）。
  static let margin: CGFloat = 48
  private static let hintKeyGap: CGFloat = 5
  private static let footerTop: CGFloat = 5
  private static let footerPadTop: CGFloat = 7
  private static let footerPadBottom: CGFloat = 3
  private static let lineAlpha = 0.07
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    GlassPanel(level: .popup) {
      VStack(spacing: 0) {
        Spacer(minLength: 0)
        footer
      }
      .padding(Theme.Layout.editorItemListPad)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .padding(Self.margin)
    .environment(\.localization, localization)
    .environment(\.chromeFontResolver, fontResolver)
    .environment(\.chromeTranslucency, translucency)
  }

  /// 下の案内: 上に 1px の線、キーの札と文言の組を間 14 で並べる（sans 11・muted）。
  private var footer: some View {
    VStack(spacing: 0) {
      Rectangle().fill(EditorInk(scheme).hairline(Self.lineAlpha))
        .frame(height: Theme.Stroke.hairline)
        .padding(.top, Self.footerTop)
      HStack(spacing: Theme.Layout.editorItemListHintGap) {
        ForEach(Array(itemList.hints.enumerated()), id: \.offset) { _, hint in
          HStack(spacing: Self.hintKeyGap) {
            EditorKeyCap(content: hint.key)
            Text(hint.label)
              .font(Font.theme.editorItemListHint)
              .foregroundStyle(Color.theme.textMuted)
          }
        }
        Spacer(minLength: 0)
      }
      .lineLimit(1)
      .padding(.horizontal, Theme.Layout.editorItemListRowPadX)
      .padding(.top, Self.footerPadTop)
      .padding(.bottom, Self.footerPadBottom)
    }
    .frame(height: Theme.Layout.editorItemListFooter, alignment: .top)
  }
}

/// 一覧の器の行の列を SwiftUI に載せる。行の版・選択・字体は器が自分で行の列へ写すので、ここは載せて大きさを渡すだけ
/// （`RowListHost` は持ち主から読んだ値で列を更新するので使わない）。行の列は 1 つの器に 1 本で、載せる場所も 1 つ。
struct EditorItemListRowListHost: NSViewRepresentable {
  let itemList: EditorItemList

  func makeNSView(context: Context) -> RowList<EditorItemListSource> { itemList.list }

  /// 与えられた大きさを埋める（AppKit の自動レイアウトで測らせない）。
  func sizeThatFits(
    _ proposal: ProposedViewSize, nsView: RowList<EditorItemListSource>, context: Context
  ) -> CGSize? {
    proposal.replacingUnspecifiedDimensions()
  }

  func updateNSView(_ list: RowList<EditorItemListSource>, context: Context) {}
}

/// 一覧の器の host。押してもフォーカスを取らない。影の余白の上の押下は受けず、下の view へ通す（一覧の矩形の中の押下は
/// 受けて、何もしない）。
final class EditorItemListHost: NSHostingView<EditorItemListRoot> {
  override var acceptsFirstResponder: Bool { false }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let panel = frame.insetBy(dx: EditorItemListRoot.margin, dy: EditorItemListRoot.margin)
    return !isHidden && panel.contains(point) ? self : nil
  }
}
