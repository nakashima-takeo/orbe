import SwiftUI

/// メニューバーアイテム本体。①②③④を**1 つのピル**で描き、態は「位相 × 件数 × ドロップダウン
/// 開閉」の関数として現れる（境界で幅が飛ばない）。時間はビューの外（`MenuBarArrivalDriver`）が
/// 持ち、`phase` として注入される——任意の中間フレームが決定論的に描けるので、開閉の途中も
/// 静止画とテストで確かめられる。
///
/// ① 要対応 0・閉じ切り: 減光した ◐ だけ（地なし・数字なし・水平余白も持たない）。
/// ② `store.transient` が生きている間: 状態グリフ 11＋WS 名（上限で省略）＋文言（残り予算まで）を
///    **1 つの箱**として滲み出し、件数は仕舞われる。祝いは艶の走査 1 本が担う。
/// ③ 閉じ切りで要対応あり: ◐＋件数（waiting+done のみ）。地 surfaceInk 16%。
/// ④ ドロップダウン表示中はピル地を accent 35% に。
struct MenuBarStatusView: View {
  let store: AttentionStore
  let ui: MenuBarUIState
  /// 開閉と艶の位相。呼び出し側が必ず明示する（既定値は置かない）。
  let phase: MenuBarArrival.Phase
  /// 状態アイコン上書き（別 NSHostingView root のため chrome と同じ実ホルダーを注入する。
  /// 既定は素の割り当て＝gallery / preview は既定グリフ）。
  var iconResolver = AgentIconResolver()

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

  /// ピル高。メニューバー厚は 22/24 の 2 系があり、24 に固定すると 22 の bar で content が
  /// 縦に潰れる。22 以下の content は bar 高の中で SwiftUI が縦センターする。
  private static let pillHeight: CGFloat = 22

  /// ピルの形。地の 2 層・hairline・艶のクリップが同じ形を指すことを、この 1 つが保証する。
  private static let pillShape = RoundedRectangle(cornerRadius: 5)

  /// 件数スロットの直前の間隔（原典の数字スロット `padding-left: 5px`）。他のスロットは 6。
  private static let countGap: CGFloat = 5

  /// ◐ の辺長（原典 `width: 15`）。予算の割り付けもこの値を数える。
  private static let glyphSize: CGFloat = 15

  /// 水平 padding を除いた内側予算。
  private static let pillBudget = transientMaxWidth - pillPadding * 2

  /// ②の文言グループ（状態グリフ＋WS 名＋文言）の予算。外側 `PillRow` がこのグループへ配る
  /// 取り分——内側予算から ◐・グループ直前の間隔・件数スロットの取り分（上限固定）を引いた残り
  /// ——と同じ量である必要がある。グループが自分の取り分を超えて申告すると、外側は再提案しても
  /// 同じ幅を返され（`PillRow` は提案幅を見ない＝内容ハグ）、ピルが上限を超えて太る。
  private static let textBudget =
    pillBudget - glyphSize - Theme.Space.note - (countGap + countCap)

  /// 艶の帯幅（原典 `width: 80`）。
  private static let glossWidth: CGFloat = 80

  /// 艶の帯がピル上下へはみ出す量（原典 `top:-6 bottom:-6`）。
  private static let glossBleed: CGFloat = 6

  /// 艶の帯の高さ。ピル高の上下へ `glossBleed` ずつ。
  private static let glossHeight = Self.pillHeight + Self.glossBleed * 2

  /// 艶の斜め（原典 `skewX(-18deg)`）。
  private static let glossSkew = CGAffineTransform(
    a: 1, b: 0, c: CGFloat(tan(-18 * Double.pi / 180)), d: 1, tx: 0, ty: 0)

  /// skew が帯の下端を左へ張り出させる量。走り切りでピル右端に楔を残さないよう、
  /// 走行距離へこのぶんを足す（原典の入退場 opacity を持たない代わりの「通り抜け切る距離」）。
  private static let glossOverhang = Self.glossHeight * abs(Self.glossSkew.c)

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

  /// 件数スロットが描く値。開いていく間は**到来した瞬間の件数**、収縮中は実件数。
  /// 一覧は報告の coalesce で展開の途中に増えるので、開き側で実件数を見せると 0 件からの
  /// 到来で数字が展開中に閃く。原典は「開くとき仕舞い、閉じながら（＋1 された）件数が現れる」で、
  /// 数字が変わるのは必ず収縮と同時——境目は畳み具合ではなく**向き**にある。
  private var slotCount: Int {
    guard let transient = store.transient, !phase.closing else { return store.count }
    return transient.arrivedCount
  }

  var body: some View {
    PillRow(spacing: Theme.Space.note, budget: Self.pillBudget) {
      brandGlyph.pillSlot(gap: 0, fold: 1)
      if let row = store.transient?.row {
        transientGroup(row).pillSlot(gap: Theme.Space.note, fold: textFold)
      }
      if slotCount > 0 {
        Text("\(slotCount)")
          .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
          .foregroundStyle(.primary)  // ③④の数字はシステム外観に追従する（dark ピンを当てない）
          .pillSlot(gap: Self.countGap, fold: countFold, cap: Self.countCap)
      }
    }
    .padding(.horizontal, slotCount > 0 ? Self.pillPadding : Self.pillPadding * groundLift)
    .frame(height: Self.pillHeight)
    .background(pillGround)
    .overlay { if let gloss = phase.gloss { glossSweep(gloss) } }
    // 生の出入りだけを写す。`store.transient != nil` で絞ると、③に載せたまま②が到来した
    // ときに onHover が再発火せず false が焼き付き、延長が最も要る場面で効かなくなる。
    .onHover { ui.itemHovered = $0 }
    .padding(.horizontal, Theme.Space.hair)
  }

  /// ②の中身（状態グリフ・WS 名・文言）。**これで 1 つのスロット**——原典は 3 つを 1 枚の
  /// `max-width` の箱に入れて畳むので、滲み出しは左から途切れず一続きに現れ、収縮では右から
  /// 一続きに消える。3 つを個別に畳むと、同じ瞬間に WS 名も文言も字の途中で切れた断片が並ぶ。
  /// 内側の予算配分（WS 名は上限までハグ・文言が残りを吸う）はここが担う。
  private func transientGroup(_ row: AttentionRow) -> some View {
    PillRow(spacing: Theme.Space.note, budget: Self.textBudget) {
      if let kind = AgentStateIcon.kind(state: row.state) {
        StatusGlyphView(kind: kind, size: 11, symbol: iconResolver.symbol(for: kind))
          .environment(\.colorScheme, .dark)
      }
      textSlot(row.workspaceName, color: Color.theme.textPrimary)
        .pillSlotCap(Self.transientWorkspaceCap)
      // 上限を宣言せず残り予算を吸う。インクは WS 名より一段沈めて「名前 → 中身」の順を作る
      // （見本の副次インク #a49bb4 は②の地に対し 4.3:1 で、design-system §3 の本文 4.5:1 を
      // 満たさない。`textSecondary` は #b8afc4＝5.4:1 で、条件を満たすうちの最も近い階調）。
      textSlot(row.message ?? row.tabTitle, color: Color.theme.textSecondary)
    }
  }

  /// ◐。①③④は前景モノクロ（.primary＝メニューバー外観追従）で、他の常駐アイコンと同じ
  /// template 相当の見え——見本がバー全体へ与える `chromeText` は、バーを持たない実装では
  /// システムの前景にあたる（①はさらに減光する）。②の暗地が立つぶんだけ、見本どおりの
  /// `textPrimary` を dark で解決した単色へクロスフェードする（地が固定の暗色なので dark ピン）。
  private var brandGlyph: some View {
    let lift = eased(MenuBarArrival.Curve.glyph)
    return ZStack {
      OrbeMarkGlyph(size: Self.glyphSize, color: .primary)
        .opacity(slotCount > 0 ? 1 : 0.45 + 0.55 * lift)
      OrbeMarkGlyph(size: Self.glyphSize, color: Color.theme.textPrimary)
        .environment(\.colorScheme, .dark)
        .opacity(groundLift)
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
      Self.pillShape
        .fill(
          ui.dropdownOpen
            ? Color.theme.accentPrimary.opacity(0.35) : Color.theme.surfaceInk.opacity(0.16)
        )
        .opacity(slotCount > 0 ? 1 : 0)
      Self.pillShape
        .fill(Color.theme.bgBase)  // 不透明の暗地（メニューバー実背景に依存しない）
        .overlay(Self.pillShape.fill(Color.theme.accentPrimary.opacity(0.35)))
        .overlay(
          Self.pillShape
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
      .frame(width: Self.glossWidth, height: Self.glossHeight)
      .transformEffect(Self.glossSkew)
      .offset(
        x: -Self.glossWidth
          + (geo.size.width + Self.glossWidth + Self.glossOverhang)
            * MenuBarArrival.Curve.gloss.value(at: progress),
        y: -Self.glossBleed)
    }
    .clipShape(Self.pillShape)
    .environment(\.colorScheme, .dark)
    .allowsHitTesting(false)
  }
}

/// スロット幅の上限。宣言しないサブビューは残り予算のすべてを上限にできる。
private struct PillSlotCap: LayoutValueKey {
  static let defaultValue: CGFloat = .infinity
}

/// スロットの直前の間隔（nil＝`PillRow.spacing`）。
private struct PillSlotGap: LayoutValueKey {
  static let defaultValue: CGFloat? = nil
}

/// スロットの畳み具合。0＝畳み切り、1＝自然幅。
private struct PillSlotFold: LayoutValueKey {
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

  /// 幅の上限だけを宣言する（自分では畳まないスロット用）。
  func pillSlotCap(_ cap: CGFloat) -> some View {
    layoutValue(key: PillSlotCap.self, value: cap)
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
    // 上限を宣言したスロットが確保する取り分は**上限そのもの**（＋直前の間隔）。自然幅で
    // 予約すると、予約量が中身に依存する——件数スロットは②の最中に桁が変わる（0→1・2→3）ので、
    // その差だけ前の文言スロットの取り分が動いて切り詰め位置がずれ、文字が跳ねる。予算配分が
    // 畳み具合を見ないのと同じ理由で、予約も②の間ずっと不変な量から組む。
    let ideals = subviews.map { $0.sizeThatFits(.unspecified) }
    let claims = subviews.enumerated().map { index, subview -> CGFloat in
      let cap = subview[PillSlotCap.self]
      return cap.isFinite ? gaps[index] + cap : 0
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
