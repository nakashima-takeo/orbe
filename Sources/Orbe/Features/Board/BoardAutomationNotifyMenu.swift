import SwiftUI

extension AutomationNotify {
  /// 通知先の名前。サブメニューの行と見出しの「通知」の行が引く。
  var labelKey: L10nKey {
    switch self {
    case .menuBar: .boardNotifyMenuBar
    case .notificationCenter: .boardNotifyNotificationCenter
    }
  }
}

/// サブメニュー「通知」を重ねる位置: 詳細の見える範囲と、見出しの「通知」の行。詳細は ScrollView なので、行の中に重ねると
/// 詳細の幅で切られる。部品の高さへ運んで重ねる。
struct BoardAutomationNotifyAnchor: PreferenceKey {
  var viewport: Anchor<CGRect>?
  var row: Anchor<CGRect>?

  static let defaultValue = BoardAutomationNotifyAnchor()

  static func reduce(
    value: inout BoardAutomationNotifyAnchor, nextValue: () -> BoardAutomationNotifyAnchor
  ) {
    let next = nextValue()
    value.viewport = next.viewport ?? value.viewport
    value.row = next.row ?? value.row
  }
}

/// 開いているサブメニュー「通知」を部品に重ねる層。「通知」の行の右に、行の上端に揃えて置く。部品の端を越えるなら内側へずらす。
/// 置くのは行が詳細の見える範囲に収まっている間だけで、開いている間に外れたら閉じる。メニューの外のクリックは閉じるだけで、
/// 下へは届かない。
struct BoardAutomationNotifyLayer: View {
  let model: BoardAutomationModel
  let anchors: BoardAutomationNotifyAnchor

  var body: some View {
    if model.notifyCursor != nil, let viewport = anchors.viewport, let row = anchors.row {
      GeometryReader { proxy in
        let visible = Self.contains(proxy[viewport], proxy[row])
        ZStack(alignment: .topLeading) {
          Color.clear
            .contentShape(Rectangle())
            .onTapGesture { model.closeNotify() }
          if visible {
            BoardAutomationNotifyPlacement(
              origin: CGPoint(x: proxy[row].maxX + Theme.Space.step, y: proxy[row].minY)
            ) {
              BoardAutomationNotifyMenu(model: model)
            }
          }
        }
        .onChange(of: visible) { was, now in
          if was, !now { model.closeNotify() }
        }
      }
    }
  }

  /// 行の上下が見える範囲に収まっているか。
  private static func contains(_ viewport: CGRect, _ row: CGRect) -> Bool {
    row.minY >= viewport.minY && row.maxY <= viewport.maxY
  }
}

/// 子を本来の大きさで `origin` に置き、収まらなければ収まるまで内側へずらす。
private struct BoardAutomationNotifyPlacement: Layout {
  let origin: CGPoint

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    proposal.replacingUnspecifiedDimensions()
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let margin = Theme.Space.step
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      let x = max(
        bounds.minX + margin, min(bounds.minX + origin.x, bounds.maxX - margin - size.width))
      let y = max(
        bounds.minY + margin, min(bounds.minY + origin.y, bounds.maxY - margin - size.height))
      subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
    }
  }
}

/// サブメニュー「通知」: 見出しと、通知しない・メニューバー・通知センターの 3 行。今の設定に印を付け、↑↓ で選んでいる行に
/// 選択の地を敷く。印は今の定義から毎回読む（開いている間に AI が書き換えても今の値を指す）。行のクリックで決める。ポインタが
/// 乗っても選びは動かさない（ボードの一覧と同じ）。
struct BoardAutomationNotifyMenu: View {
  let model: BoardAutomationModel
  @Environment(\.localization) private var l10n

  var body: some View {
    let current = model.selectedAutomation?.notify
    VStack(alignment: .leading, spacing: 0) {
      Text(l10n.string(.boardNotifyTitle))
        .font(Font(Theme.Typography.caption.monospacedWeight(.semibold)))
        .foregroundStyle(Color.theme.textSecondary)
        .padding(.horizontal, Theme.Space.step + Theme.Space.hair)
        .padding(.vertical, Theme.Space.tick)
      ForEach(Array(BoardAutomationModel.notifyChoices.enumerated()), id: \.offset) {
        row($0, $1, current)
      }
    }
    .padding(Theme.Space.tick)
    .frame(minWidth: 160, alignment: .leading)
    .floatingMenuCard()
  }

  private func row(_ index: Int, _ choice: AutomationNotify?, _ current: AutomationNotify?)
    -> some View
  {
    let on = choice == current
    let choose = { model.chooseNotify(choice) }
    return SelectableRow(selected: model.notifyCursor == index, action: choose) {
      HStack(spacing: Theme.Space.step) {
        MarkGlyph(kind: .success, width: 9, color: Color.theme.accentBright)
          .opacity(on ? 1 : 0)
        Text(l10n.string(choice?.labelKey ?? .boardNotifyOff))
          .font(Font.theme.chrome)
          .foregroundStyle(on ? Color.theme.textPrimary : Color.theme.textSecondary)
          .lineLimit(1)
      }
    }
  }
}
