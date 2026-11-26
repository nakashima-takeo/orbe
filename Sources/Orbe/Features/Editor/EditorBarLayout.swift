import SwiftUI

/// 上のバーの部品が譲る順（先に譲るものから）。幅が足りなければ、後ろの段（大事な側）から幅を配り、前の段ほど先に譲る。
/// どの画面の部品も、この 1 つの順から選ぶ。
enum EditorBarYield: Int, CaseIterable, Comparable {
  /// 「⌥ 端末を表示」。
  case hint
  /// ファイル内検索の欄の幅。
  case findField
  /// 右端のボタンの添え書き。
  case actionDetail
  /// 中ほどの札の広い姿。
  case chipWide
  /// 今の項目のボタンの広い姿。
  case itemWide
  /// 中ほどの札まるごと。
  case chip

  static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// 上のバーの部品の宣言。名乗らない部品は、左寄せで、最小の幅のまま落とさない。
struct EditorBarPart: Equatable {
  enum Side {
    case leading
    case trailing
  }

  var side = Side.leading
  /// 幅が足りないとき、まるごと落としてよい段。
  var drops: EditorBarYield?
  /// 最小の幅より広い姿を受け取る段。
  var grows: EditorBarYield?
}

/// 部品に配った幅。`offered` は部品へ渡した幅、`width` は部品が使った幅。
struct EditorBarSlot: Equatable {
  var offered: CGFloat
  var width: CGFloat
}

/// 上のバーの行。部品は固定の子として並び、配った結果で子の同一性は変わらない。左寄せの部品と右寄せの部品の間には、
/// 幅 0 の伸びる隙間を 1 つ置く（隣とは部品と同じ間隔で離れる）。落とした部品は行の枠の外に置き、行が枠で切る（押下も受けない。
/// → `editorBarPart`）。
struct EditorBarLayout: Layout {
  let spacing: CGFloat

  /// 行の枠の座標空間（行を置く側が、このレイアウトに張る）。落としてよい部品は、この枠の中に居るかで押下を受けるかを決める。
  static let space = "editorBarRow"

  struct Cache {
    var parts: [EditorBarPart]
    var minimums: [CGFloat]
    /// 最後に配った幅（使える幅と、部品ごとの幅）。
    var last: (available: CGFloat, slots: [EditorBarSlot?])?
  }

  func makeCache(subviews: Subviews) -> Cache {
    Cache(
      parts: subviews.map { $0[EditorBarPartKey.self] },
      minimums: subviews.map { $0.sizeThatFits(ProposedViewSize(width: 0, height: nil)).width },
      last: nil)
  }

  func updateCache(_ cache: inout Cache, subviews: Subviews) {
    cache = makeCache(subviews: subviews)
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
    let slots = self.slots(
      available: proposal.width ?? .infinity, subviews: subviews, cache: &cache)
    let height =
      proposal.height ?? subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
    return CGSize(width: proposal.width ?? total(slots), height: height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache
  ) {
    let slots = self.slots(available: bounds.width, subviews: subviews, cache: &cache)
    func place(_ index: Int, at x: CGFloat, _ slot: EditorBarSlot) {
      subviews[index].place(
        at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
        proposal: ProposedViewSize(width: slot.offered, height: bounds.height))
    }
    let kept = slots.indices.filter { slots[$0] != nil }
    let leading = kept.filter { cache.parts[$0].side == .leading }
    let trailing = kept.filter { cache.parts[$0].side == .trailing }
    var x = bounds.minX
    for index in leading {
      place(index, at: x, slots[index]!)
      x += slots[index]!.width + spacing
    }
    if total(slots) > bounds.width {
      for index in trailing {
        x += spacing
        place(index, at: x, slots[index]!)
        x += slots[index]!.width
      }
    } else {
      x = bounds.maxX
      for index in trailing.reversed() {
        x -= slots[index]!.width
        place(index, at: x, slots[index]!)
        x -= spacing
      }
    }
    for index in slots.indices where slots[index] == nil {
      subviews[index].place(
        at: CGPoint(x: bounds.maxX + spacing, y: bounds.midY), anchor: .leading,
        proposal: ProposedViewSize(width: cache.minimums[index], height: bounds.height))
    }
  }

  /// 残した部品の幅と、間隔（伸びる隙間の分を含む）の和。
  private func total(_ slots: [EditorBarSlot?]) -> CGFloat {
    let kept = slots.compactMap { $0 }
    return kept.reduce(0) { $0 + $1.width } + spacing * CGFloat(kept.count)
  }

  private func slots(available: CGFloat, subviews: Subviews, cache: inout Cache)
    -> [EditorBarSlot?]
  {
    if let last = cache.last, last.available == available { return last.slots }
    let slots = Self.slots(
      parts: cache.parts, minimums: cache.minimums, available: available, spacing: spacing
    ) { index, width in
      subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil)).width
    }
    cache.last = (available, slots)
    return slots
  }

  /// 部品ごとの幅（落とした部品は nil）。まず、落とせない部品を最小の幅で残す。次に、譲る順を大事な側から 1 段ずつ見る。
  /// その段で落ちる部品は、最小の幅と間隔が残りに入れば残す。その段で広がる部品には「最小の幅 ＋ 残り」を渡し、使った幅を
  /// 採る（使わなかった分は次の段へ回る）。間隔は、部品ごとに 1 つと、左寄せと右寄せの間の隙間の分。`measure(i, w)` は、
  /// 部品 i に幅 w を渡したときに使う幅。
  static func slots(
    parts: [EditorBarPart], minimums: [CGFloat], available: CGFloat, spacing: CGFloat,
    measure: (Int, CGFloat) -> CGFloat
  ) -> [EditorBarSlot?] {
    var slots: [EditorBarSlot?] = parts.indices.map { index in
      parts[index].drops == nil
        ? EditorBarSlot(offered: minimums[index], width: minimums[index]) : nil
    }
    var rest = slots.compactMap { $0 }.reduce(available) { $0 - $1.width - spacing }
    for yield in EditorBarYield.allCases.reversed() {
      for index in parts.indices where parts[index].drops == yield {
        guard minimums[index] + spacing <= rest else { continue }
        slots[index] = EditorBarSlot(offered: minimums[index], width: minimums[index])
        rest -= minimums[index] + spacing
      }
      for index in parts.indices where parts[index].grows == yield {
        guard let slot = slots[index], rest > 0 else { continue }
        let offered = slot.width + rest
        let width = min(max(measure(index, offered), slot.width), offered)
        slots[index] = EditorBarSlot(offered: offered, width: width)
        rest -= width - slot.width
      }
    }
    return slots
  }
}

private struct EditorBarPartKey: LayoutValueKey {
  static let defaultValue = EditorBarPart()
}

extension View {
  /// 上のバーの部品の宣言（寄せる側・まるごと落としてよい段・最小より広い姿を受け取る段）。落としてよい部品は、行の枠の
  /// 外に置かれている間、押下を受けない（行が枠で切るのは描画だけなので、枠の外でも host の中に残る部分が押下を受ける）。
  func editorBarPart(
    _ side: EditorBarPart.Side = .leading, drops: EditorBarYield? = nil,
    grows: EditorBarYield? = nil
  ) -> some View {
    modifier(EditorBarDroppable(isDroppable: drops != nil))
      .layoutValue(
        key: EditorBarPartKey.self, value: EditorBarPart(side: side, drops: drops, grows: grows))
  }
}

/// 落としてよい部品の押下を、行の枠（`EditorBarLayout.space`）の中に置かれている間だけ受ける。
private struct EditorBarDroppable: ViewModifier {
  let isDroppable: Bool
  @State private var isPlaced = true

  func body(content: Content) -> some View {
    if isDroppable {
      content
        .allowsHitTesting(isPlaced)
        .onGeometryChange(for: Bool.self) { proxy in
          guard let row = proxy.bounds(of: .named(EditorBarLayout.space)) else { return true }
          return row.intersects(proxy.frame(in: .named(EditorBarLayout.space)))
        } action: {
          isPlaced = $0
        }
    } else {
      content
    }
  }
}
