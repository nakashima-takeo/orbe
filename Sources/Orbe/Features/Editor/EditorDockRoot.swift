import AppKit
import SwiftUI

/// 上のバーの右下の置き場の SwiftUI ルート。上から、ポップアップ（開いていれば、載せる側の中身。同一性は器の開いた回数）と、
/// 今の画面の札を右寄せで縦に並べる（→ `EditorDockStack`）。札は、本体の上端の帯（`EditorShellModel.bodyBandHeight`）の
/// 下から並べる。札は、画面ごとのファイル（`EditorDock+<画面>.swift`）が、ここの描画の中で持ち主の値から
/// 組む。器の中の別 root なので環境は明示注入する。影を描くために、置き場の枠の外側に `margin` の余白を取る。見えている物の
/// 枠（`editorDockItem` を付けた物）は `framesDidChange` で host へ知らせる（host が押下を受ける範囲）。
struct EditorDockRoot: View {
  let shell: EditorShellModel
  /// ポップアップの器（開閉と、載せる側の持ち主）。
  let popup: EditorPopup
  /// コミットのポップアップの持ち主（Changes の札が、ソース管理の状態と、ポップアップが開いているかを読む）。
  let commitPopup: ScmCommitPopup
  /// レビューのポップアップの持ち主（PR の画面の札が、worktree の今の PR とポップアップが開いているかを読む）。
  let reviewPopup: PrReviewPopup
  let localization: LocalizationStore
  let fontResolver: ChromeFontResolver
  let translucency: ChromeTranslucency
  let framesDidChange: ([CGRect]) -> Void

  /// 影を描く余白（一覧の器と同じ）。
  static let margin = EditorItemListRoot.margin
  /// 並んでいる物の枠を測る座標空間（置き場の host の座標）。
  static let space = "editorDock"

  var body: some View {
    EditorDockStack(cardsTop: shell.bodyBandHeight) {
      if popup.isOpen, let owner = popup.owner { owner.popupContent().id(popup.openCount) }
    } cards: {
      switch shell.panel.screen {
      case .changes: changesCards
      case .pullRequest: pullRequestCards
      case .files: EmptyView()
      }
    }
    .padding(Self.margin)
    .coordinateSpace(.named(Self.space))
    .onPreferenceChange(EditorDockFramesKey.self) { framesDidChange($0) }
    .environment(\.localization, localization)
    .environment(\.chromeFontResolver, fontResolver)
    .environment(\.chromeTranslucency, translucency)
  }
}

/// 置き場の並び。上から、ポップアップ（幅 520。並びが狭ければ並びの幅）と、札（自分の幅と高さ）を、右寄せで間 6 で縦に
/// 並べる。札は、並びの上端から `cardsTop` より上には置かない（本体の上端の帯を覆わない）。札は自分の高さを取り、
/// ポップアップは残りの高さを上限に縮む。押下を受ける範囲は、並んでいる物の外枠ではなく、その中の見えている物が自分で
/// 知らせる枠（→ `editorDockItem`）。
struct EditorDockStack<Popup: View, Cards: View>: View {
  var cardsTop: CGFloat = 0
  @ViewBuilder let popup: () -> Popup
  @ViewBuilder let cards: () -> Cards

  var body: some View {
    EditorDockLayout(cardsTop: cardsTop) {
      ForEach(subviews: popup()) { item in
        item.layoutValue(key: EditorDockPopupKey.self, value: true)
      }
      cards()
    }
  }
}

/// 子のうち、ポップアップ（`EditorDockPopupKey` が真）は幅 520 か並びの幅の小さいほうで、高さは札の残りを上限に置き、札は
/// 並びの幅を上限に自分の大きさで置く。どれも右寄せで、上から間 6 で並べる。札は、上端から `cardsTop` より上には置かない。
private struct EditorDockLayout: Layout {
  let cardsTop: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    proposal.replacingUnspecifiedDimensions()
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let gap = Theme.Layout.editorDockGap
    let cards = subviews.filter { !$0[EditorDockPopupKey.self] }
    let cardSizes = cards.map {
      $0.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
    }
    let cardsHeight = cardSizes.reduce(0) { $0 + $1.height + gap }
    var y = bounds.minY
    for popup in subviews where popup[EditorDockPopupKey.self] {
      let width = min(Theme.Layout.editorPopupWidth, bounds.width)
      let ceiling = max(0, bounds.maxY - y - cardsHeight)
      let height = min(
        popup.sizeThatFits(ProposedViewSize(width: width, height: ceiling)).height, ceiling)
      popup.place(
        at: CGPoint(x: bounds.maxX - width, y: y), anchor: .topLeading,
        proposal: ProposedViewSize(width: width, height: height))
      y += height + gap
    }
    y = max(y, bounds.minY + cardsTop)
    for (card, size) in zip(cards, cardSizes) {
      let width = min(size.width, bounds.width)
      card.place(
        at: CGPoint(x: bounds.maxX - width, y: y), anchor: .topLeading,
        proposal: ProposedViewSize(width: width, height: size.height))
      y += size.height + gap
    }
  }
}

private struct EditorDockPopupKey: LayoutValueKey {
  static let defaultValue = false
}

/// 置き場の見えている物の枠（`EditorDockRoot.space` の座標）。
struct EditorDockFramesKey: PreferenceKey {
  static let defaultValue: [CGRect] = []

  static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
    value.append(contentsOf: nextValue())
  }
}

extension View {
  /// 置き場の見えている物として、自分の枠を置き場の host へ知らせる（host は、この枠の中の押下だけを受ける）。地の部品
  /// （`EditorPopupGround`・`EditorCardGround`）は自分で付ける。地の部品を使わずに置き場へ並べる物（中身が地の外に
  /// 並べるメニューなど）は、その物に付ける。
  func editorDockItem() -> some View {
    modifier(EditorDockFrame())
  }
}

/// 置き場の見えている物の枠を知らせる。
private struct EditorDockFrame: ViewModifier {
  func body(content: Content) -> some View {
    content.background(
      GeometryReader { geometry in
        Color.clear.preference(
          key: EditorDockFramesKey.self,
          value: [geometry.frame(in: .named(EditorDockRoot.space))])
      })
  }
}

/// 置き場の host。押してもフォーカスを取らない。並んでいる物の枠の中の押下だけを受け、ほかは下の view へ通す。
final class EditorDockHost: NSHostingView<EditorDockRoot> {
  /// 並んでいる物の枠（host の座標）。
  var itemFrames: [CGRect] = []

  override var acceptsFirstResponder: Bool { false }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    guard itemFrames.contains(where: { $0.contains(local) }) else { return nil }
    return super.hitTest(point)
  }
}

/// ポップアップの地——popup の段のガラス・角丸 14・影。色 `tint` を渡すと、縁の線（色 .5）・上端から 132 までの縦の
/// グラデーション（色 .17 → 0）・外の光（色 .13・広がり 44）が付く。中身は渡された幅いっぱいに置く。自分の枠を、置き場の
/// 見えている物として知らせる。
struct EditorPopupGround<Content: View>: View {
  var tint: Color?
  @ViewBuilder let content: () -> Content

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Theme.Layout.editorPopupRadius)
    GlassPanel(level: .popup, cornerRadius: Theme.Layout.editorPopupRadius) {
      content()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .top) {
          if let tint {
            LinearGradient(
              colors: [tint.opacity(Theme.Opacity.editorPopupTintTop), tint.opacity(0)],
              startPoint: .top, endPoint: .bottom
            )
            .frame(height: Theme.Layout.editorPopupTintHeight)
          }
        }
    }
    .overlay {
      if let tint {
        shape.strokeBorder(
          tint.opacity(Theme.Opacity.editorPopupTintBorder), lineWidth: Theme.Stroke.hairline)
      }
    }
    .shadow(
      color: tint?.opacity(Theme.Opacity.editorPopupTintGlow) ?? .clear,
      radius: tint == nil ? 0 : Theme.Layout.editorPopupGlow
    )
    .editorDockItem()
  }
}

/// 札の地——popup の段のガラス・角丸 10・最小の高さ 34。`border` を渡すと縁の線が付く。自分の枠を、置き場の見えている物と
/// して知らせる。
struct EditorCardGround<Content: View>: View {
  var border: Color?
  @ViewBuilder let content: () -> Content

  var body: some View {
    GlassPanel(level: .popup, cornerRadius: Theme.Layout.editorCardRadius) {
      content().frame(minHeight: Theme.Layout.editorCardMinHeight)
    }
    .overlay {
      if let border {
        RoundedRectangle(cornerRadius: Theme.Layout.editorCardRadius)
          .strokeBorder(border, lineWidth: Theme.Stroke.hairline)
      }
    }
    .editorDockItem()
  }
}

/// 失敗の札（失敗 1 つに 1 枚）。札の地に縁の線 danger .5。文は sans 12・行の高さ 1.55・danger で、選べる。札の幅は文に
/// 合わせ（下の物の押下を要る幅だけ受け止める）、渡された幅（置き場の幅。上限 620）で折り返す。文の右上の × は `dismiss` を呼ぶだけで、失敗を消すか
/// 「知らせを閉じた」印を付けるかは、載せる側が決める。
struct EditorFailureCard: View {
  let text: String
  let dismiss: () -> Void
  @Environment(\.localization) private var l10n
  @State private var hovering = false

  var body: some View {
    EditorCardGround(border: Color.theme.danger.opacity(Theme.Opacity.editorFailureBorder)) {
      HStack(alignment: .top, spacing: 0) {
        Text(text)
          .font(Font.theme.editorDockCard)
          .lineSpacing(
            Theme.Typography.editorDockCard.extraLeading(
              lineHeight: Theme.Typography.editorDockCardLineHeight)
          )
          .foregroundStyle(Color.theme.danger)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.leading, Theme.Layout.editorCardPadX)
          .padding(.vertical, Theme.Layout.editorCardPadY)
        close
      }
    }
  }

  private var close: some View {
    let label = l10n.string(.editorDockCardClose)
    return EditorGlyphView(
      glyph: EditorGlyphs.close, size: Theme.Layout.editorCardCloseGlyph,
      color: hovering ? Color.theme.editorText : Color.theme.textMuted
    )
    .frame(width: Theme.Layout.editorCardClose, height: Theme.Layout.editorCardClose)
    .background(
      RoundedRectangle(cornerRadius: Theme.Layout.editorCardCloseRadius)
        .fill(
          hovering ? Color.theme.surfaceInk.opacity(Theme.Opacity.editorCardCloseHover) : .clear)
    )
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .onTapGesture(perform: dismiss)
    .help(label)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(label)
    .accessibilityAddTraits(.isButton)
    .padding(Theme.Layout.editorCardClosePad)
  }
}
