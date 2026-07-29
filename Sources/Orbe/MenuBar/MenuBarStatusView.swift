import SwiftUI

/// メニューバーアイテム本体。①②③④を**1 つのピル**で描き、態は「位相 × 件数 × ドロップダウン
/// 開閉」の関数として現れる（境界で幅が飛ばない）。時間はビューの外（`MenuBarArrivalDriver`）が
/// 持ち、`phase` として注入される——任意の中間フレームが決定論的に描けるので、開閉の途中も
/// 静止画とテストで確かめられる。
///
/// ① 要対応 0・閉じ切り: 減光した ◐ だけ（地なし・数字なし・水平余白も持たない）。
/// ② `store.transient` が生きている間: 状態グリフ 11＋WS 名（上限で省略）＋文言（残り予算まで）が
///    滲み出て、件数は仕舞われる。祝いは艶の走査 1 本が担う。
/// ③ 閉じ切りで要対応あり: ◐＋件数（waiting+done のみ）。地 surfaceInk 16%。
/// ④ ドロップダウン表示中はピル地を accent 35% に。
struct MenuBarStatusView: View {
  let store: AttentionStore
  let ui: MenuBarUIState
  /// 開閉と艶の位相。呼び出し側が必ず明示する（既定値は置かない）。
  let phase: MenuBarArrival.Phase

  /// ②ピル全体の幅上限（メニューバーの他アイテムを圧迫しない）。ここから内側予算
  /// （`transientMaxWidth` − 水平 padding×2）が決まり、`PillRow` がそれを固定部（グリフ・
  /// 状態アイコン・spacing）と WS 名（`transientWorkspaceCap`）へ配って残りを文言に渡す。
  /// テストがサイズ契約として固定する。
  static let transientMaxWidth: CGFloat = 330

  /// ②ピルの WS 名スロット上限。超えた分は省略し、余った分は文言が吸う。
  private static let transientWorkspaceCap: CGFloat = 120

  /// 件数スロット上限（原典の数字スロット `max-width: 22px`）。上限を宣言することで、
  /// 前にある文言スロットに対して自分の取り分を予算の中に残す。
  private static let countCap: CGFloat = 22

  /// 地を持つときの水平余白。
  private static let pillPadding: CGFloat = 7

  /// 水平 padding を除いた内側予算。
  private static let pillBudget = transientMaxWidth - pillPadding * 2

  /// 艶の帯幅（原典 `width: 80`）。
  private static let glossWidth: CGFloat = 80

  /// 艶の斜め（原典 `skewX(-18deg)`）。
  private static let glossSkew = CGAffineTransform(
    a: 1, b: 0, c: CGFloat(tan(-18 * Double.pi / 180)), d: 1, tx: 0, ty: 0)

  /// 曲線を「いま起きている動きの進捗」に当てて 0（閉じ切り側）〜1（開き切り側）へ直す。
  /// 開くときは `openness` そのもの、閉じるときは収縮の進捗——原典の easing はどちらの動きも
  /// その動き自身の進捗に対して前のめりで、向きを落とすと収縮が後半に固まる。
  private func eased(_ curve: UnitCurve) -> Double {
    phase.closing
      ? 1 - curve.value(at: 1 - phase.openness)
      : curve.value(at: phase.openness)
  }

  /// 地・余白が従う進捗（②の地の立ち上がり）。
  private var groundLift: Double { eased(MenuBarArrival.Curve.background) }
  /// 文言側スロットの畳み具合。
  private var textFold: Double { eased(MenuBarArrival.Curve.text) }
  /// 件数スロットの畳み具合（開くほど畳まれる＝文言表示中は件数を出さない）。
  private var countFold: Double { 1 - eased(MenuBarArrival.Curve.count) }

  var body: some View {
    PillRow(spacing: Theme.Space.note, budget: Self.pillBudget) {
      brandGlyph.pillSlot(gap: 0, fold: 1)
      if let row = store.transient?.row {
        if let kind = AgentStateIcon.kind(state: row.state) {
          StatusGlyphView(kind: kind, size: 11)
            .environment(\.colorScheme, .dark)
            .pillSlot(gap: Theme.Space.note, fold: textFold)
        }
        textSlot(row.workspaceName, color: Color.theme.textPrimary)
          .pillSlot(gap: Theme.Space.note, fold: textFold, cap: Self.transientWorkspaceCap)
        // muted は暗地で沈む——読める階調へ上げる。上限を宣言せず残り予算を吸う。
        textSlot(row.message ?? row.tabTitle, color: Color.theme.statusText)
          .pillSlot(gap: Theme.Space.note, fold: textFold)
      }
      if store.count > 0 {
        Text("\(store.count)")
          .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
          .foregroundStyle(.primary)  // ③④の数字はシステム外観に追従する（dark ピンを当てない）
          .pillSlot(gap: 5, fold: countFold, cap: Self.countCap)
      }
    }
    .padding(.horizontal, store.count > 0 ? Self.pillPadding : Self.pillPadding * groundLift)
    // ピル高（22）に揃える。メニューバー厚は 22/24 の 2 系があり、24 に固定すると 22 の bar で
    // content が縦に潰れる。22 以下の content は bar 高の中で SwiftUI が縦センターする。
    .frame(height: 22)
    .background(pillGround)
    .overlay { if let gloss = phase.gloss { glossSweep(gloss) } }
    .onHover { ui.transientHovered = $0 && store.transient != nil }
    .padding(.horizontal, Theme.Space.hair)
  }

  /// ◐。閉じ切りの①では減光した前景モノクロ（.primary＝メニューバー外観追従）で、他の常駐
  /// アイコンと同じ template 相当の見え。②の暗地が立つぶんだけブランドグラデへクロスフェードする。
  private var brandGlyph: some View {
    let lift = eased(MenuBarArrival.Curve.glyph)
    return ZStack {
      OrbeMarkGlyph(size: 15, color: .primary)
        .opacity(store.count > 0 ? 1 : 0.45 + 0.55 * lift)
      OrbeMarkGlyph(size: 15).opacity(groundLift)
    }
  }

  /// ②ピルの文字スロット。幅はレイアウト（`PillRow`）が決めるので、ここは体裁だけを持つ。
  /// インクは②の固定暗地に合わせて dark トークンで解決する（ライトメニューバーでも読める）。
  private func textSlot(_ text: String, color: Color) -> some View {
    Text(text)
      .font(.system(size: 11, design: .monospaced))
      .foregroundStyle(color)
      .lineLimit(1)
      .truncationMode(.tail)
      .environment(\.colorScheme, .dark)
  }

  /// 地の 2 層。下が③④（surfaceInk 16%／ドロップダウン中は accent 35%）、上が②。
  ///
  /// ②の地はデザイン見本（tint(accent, 0.35)）から**不透明の暗地＋accent 被せ**へ逸脱する——
  /// メニューバーの実背景（壁紙由来・半透明）の上では 35% tint が薄すぎて読めない（実機 NG）。
  /// 地が固定の暗色になるため、インクは `.environment(\.colorScheme, .dark)` で dark トークンに
  /// 固定して解決する（ライトメニューバー上でも文字・状態グリフが地に対して読める）。
  private var pillGround: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 5)
        .fill(
          ui.dropdownOpen
            ? Color.theme.accentPrimary.opacity(0.35) : Color.theme.surfaceInk.opacity(0.16)
        )
        .opacity(store.count > 0 ? 1 : 0)
      RoundedRectangle(cornerRadius: 5)
        .fill(Color.theme.bgBase)  // 不透明の暗地（メニューバー実背景に依存しない）
        .overlay(RoundedRectangle(cornerRadius: 5).fill(Color.theme.accentPrimary.opacity(0.35)))
        .overlay(
          RoundedRectangle(cornerRadius: 5)
            .strokeBorder(Color.theme.accentPrimary.opacity(0.6), lineWidth: Theme.Stroke.hairline)
        )
        .environment(\.colorScheme, .dark)
        .opacity(groundLift)
    }
  }

  /// 艶の走査。左端の外から右端の外へ 1 度だけ通り抜ける（`surfaceInk` は dark ピンで純白）。
  /// 入退場の opacity 切り替えは持たない——通り抜ける距離を取れば、グラデーション自身の
  /// α 傾斜が同じ役目を果たす。
  private func glossSweep(_ progress: Double) -> some View {
    GeometryReader { geo in
      LinearGradient(
        colors: [
          Color.theme.surfaceInk.opacity(0), Color.theme.surfaceInk.opacity(0.5),
          Color.theme.surfaceInk.opacity(0),
        ],
        startPoint: .leading, endPoint: .trailing
      )
      .frame(width: Self.glossWidth, height: 34)  // ピル 22 の上下へ 6 ずつはみ出す
      .transformEffect(Self.glossSkew)
      .offset(
        x: -Self.glossWidth
          + (geo.size.width + Self.glossWidth) * MenuBarArrival.Curve.gloss.value(at: progress),
        y: -6)
    }
    .clipShape(RoundedRectangle(cornerRadius: 5))
    .environment(\.colorScheme, .dark)
    .allowsHitTesting(false)
  }
}

/// スロット幅の上限。宣言しないサブビューは残り予算のすべてを上限にできる。
struct PillSlotCap: LayoutValueKey {
  static let defaultValue: CGFloat = .infinity
}

/// スロットの直前の間隔（nil＝`PillRow.spacing`）。
struct PillSlotGap: LayoutValueKey {
  static let defaultValue: CGFloat? = nil
}

/// スロットの畳み具合。0＝畳み切り、1＝自然幅。
struct PillSlotFold: LayoutValueKey {
  static let defaultValue: Double = 1
}

extension View {
  /// スロットを「直前の間隔」「畳み具合」「幅の上限」で宣言する。**畳まれるスロットは自分の
  /// 直前の間隔ごと畳む**（閉じ切りで隙間だけが残らない）。見える幅は分数マスクで切り、content は
  /// 変形も再レイアウトもしない——提案幅が変わらないので、文字の切り詰め位置が毎フレーム
  /// 動いて文言が跳ねることがない。畳み具合はそのまま不透明度でもある（原典の `max-width` は
  /// 常に `opacity` と対で動く）——切り口に半端な字形が立たず、畳む動きが一続きに読める。
  func pillSlot(gap: CGFloat, fold: Double, cap: CGFloat = .infinity) -> some View {
    mask { GeometryReader { geo in Color.black.frame(width: geo.size.width * fold) } }
      .opacity(fold)
      .layoutValue(key: PillSlotGap.self, value: gap)
      .layoutValue(key: PillSlotFold.self, value: fold)
      .layoutValue(key: PillSlotCap.self, value: cap)
  }
}

/// ピルの行レイアウト。`budget` の中で、サブビューを左から順に「自分の上限（`pillSlotCap`）と
/// 残り予算のうち小さい方」までの内容幅で取らせる。上限を宣言しない本文が残り予算を吸うため、
/// WS 名が短いほど文言が長く出る。**上限を宣言したスロットは後ろにあっても自分の取り分を
/// 残す**（末尾の件数スロットが、前にある文言に予算を食われて消えない）。
///
/// HStack ではこれが作れない——`.frame(maxWidth:)` は静的な上限しか持てず隣の兄弟の実幅を
/// 参照できないうえ、柔軟な子へ幅を均等に配ろうとして内容と無関係なスロット幅を作る。
///
/// 予算配分は**畳み具合を見ない**（各スロットへの提案幅は自然幅のまま）。最終的な幅だけが
/// 畳み具合を掛けた値になる。提案幅は見ない（`sizeThatFits` は予算と理想幅だけで決める）＝
/// 内容ハグ。メニューバーアイテムの幅は `MenuBarController` が intrinsic から
/// `statusItem.length` へ明示反映する。
struct PillRow: Layout {
  let spacing: CGFloat
  /// 水平 padding を除いた内側予算。
  let budget: CGFloat

  struct Cache {
    var widths: [CGFloat]
    var gaps: [CGFloat]
    var height: CGFloat
  }

  func makeCache(subviews: Subviews) -> Cache { measure(subviews) }
  func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = measure(subviews) }

  /// 左から順に予算を配る。理想幅が収まればそのまま、収まらなければ予算を提案し直して
  /// **切り詰め後の実幅**を採る（上限ちょうどで提案すると最大 1 文字ぶんの端数がスロット内に
  /// 空白として残るため、その端数を次のスロットへ回す）。
  private func measure(_ subviews: Subviews) -> Cache {
    let gaps = subviews.enumerated().map { index, subview in
      index == 0 ? 0 : (subview[PillSlotGap.self] ?? spacing)
    }
    // 上限を宣言したスロットが後続に確保する取り分（自然幅と上限の小さい方＋直前の間隔）。
    let ideals = subviews.map { $0.sizeThatFits(.unspecified) }
    let claims = subviews.enumerated().map { index, subview -> CGFloat in
      let cap = subview[PillSlotCap.self]
      return cap.isFinite ? gaps[index] + min(ideals[index].width, cap) : 0
    }
    var reserved = claims.reduce(0, +)

    var remaining = budget
    var widths: [CGFloat] = []
    var height: CGFloat = 0
    for (index, subview) in subviews.enumerated() {
      reserved -= claims[index]
      remaining -= gaps[index]
      let ideal = ideals[index]
      let allowance = min(subview[PillSlotCap.self], max(0, remaining - reserved))
      let width =
        ideal.width <= allowance
        ? ideal.width
        : subview.sizeThatFits(ProposedViewSize(width: allowance, height: nil)).width
      widths.append(width)
      remaining -= width
      height = max(height, ideal.height)
    }
    return Cache(widths: widths, gaps: gaps, height: height)
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
    var width: CGFloat = 0
    for (index, subview) in subviews.enumerated() {
      width += (cache.gaps[index] + cache.widths[index]) * CGFloat(subview[PillSlotFold.self])
    }
    return CGSize(width: width, height: cache.height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache
  ) {
    var x = bounds.minX
    for (index, subview) in subviews.enumerated() {
      let fold = CGFloat(subview[PillSlotFold.self])
      let width = cache.widths[index]
      x += cache.gaps[index] * fold
      subview.place(
        at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
        proposal: ProposedViewSize(width: width, height: bounds.height))
      x += width * fold
    }
  }
}
