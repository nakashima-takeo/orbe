import SwiftUI

/// メニューバーアイテム本体（①②③④の描画・デザイン第11シーンの数値をトークン経由で移植）。
/// ① 要対応 0（working だけの間も含む）: ◐ 15pt・opacity 0.45・数字なし。
/// ② `store.transient` が生きている間: ピル（高さ 22・radius 5・地 accent 35%）に
///    ◐＋状態グリフ 11＋WS 名 11（上限で省略）＋文言先頭 11 muted（残り予算まで・省略）が
///    滲み出る。波紋 1 回。
/// ③ 収縮後: ◐＋件数（waiting+done のみ）。地 surfaceInk 16%。
/// ④ ドロップダウン表示中はピル地を accent 35% に。
/// Reduce Motion では波紋・滲み出しアニメを止める（②は静的表示で同じ時間出る）。
struct MenuBarStatusView: View {
  let store: AttentionStore
  let ui: MenuBarUIState

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Group {
      if let transient = store.transient {
        transientPill(transient.row)
          // 行が変われば波紋・滲み出しを新規再生する（同一 view の再利用で波紋が死なない）。
          .id(transient.row.paneId)
      } else if store.count > 0 {
        countPill
      } else {
        quietGlyph
      }
    }
    // 幅アニメはしない（状態切替は即時拡張/即時収縮）。NSStatusItem.length はアニメの中間値を
    // 受け取れず、implicit animation は intrinsic 幅の確定を遅らせて滲み出しが伸びない実害が出た。
    .padding(.horizontal, Theme.Space.hair)
    // 高さは固定しない。メニューバー厚は 22/24 の 2 系があり、固定 24 は 22 の bar で
    // content が縦に潰れる。ピル（22）以下の content を bar 高の中で SwiftUI が縦センターする。
  }

  // ① 静か（要対応 0）。前景モノクロ（.primary＝メニューバー外観追従: ダーク=白 / ライト=黒）を
  // 減光。他の常駐メニューバーアイコンと同じ template 相当の見え（ブランドグラデは地の付く
  // ②ピル内とアプリ内のみ——素のメニューバー上では視認性が悪い）。
  private var quietGlyph: some View {
    OrbeMarkGlyph(size: 15, color: .primary).opacity(0.45)
  }

  /// ②ピル全体の幅上限（メニューバーの他アイテムを圧迫しない）。ここから内側予算
  /// （`transientMaxWidth` − 水平 padding×2）が決まり、`PillRow` がそれを固定部（グリフ・
  /// 状態アイコン・spacing）と WS 名（`transientWorkspaceCap`）へ配って残りを文言に渡す。
  /// テストがサイズ契約として固定する。
  static let transientMaxWidth: CGFloat = 330

  /// ②ピルの WS 名スロット上限。超えた分は省略し、余った分は文言が吸う。
  private static let transientWorkspaceCap: CGFloat = 120

  // ②状態変化の瞬間。WS 名＋文言の先頭が滲み出る（文言なしはタブタイトル）。
  //
  // 地はデザイン見本（tint(accent, 0.35)）から**不透明の暗地＋accent 被せ**へ逸脱する——
  // メニューバーの実背景（壁紙由来・半透明）の上では 35% tint が薄すぎて読めない（実機 NG）。
  // 地が固定の暗色になるため、インクは `.environment(\.colorScheme, .dark)` で dark トークンに
  // 固定して解決する（ライトメニューバー上でも文字・状態グリフが地に対して読める）。
  private func transientPill(_ row: AttentionRow) -> some View {
    PillRow(spacing: Theme.Space.note, budget: Self.transientMaxWidth - Theme.Space.step * 2) {
      OrbeMarkGlyph(size: 15)  // 暗地の上ではブランドグラデを保つ
      if let kind = AgentStateIcon.kind(state: row.state) {
        StatusGlyphView(kind: kind, size: 11)
      }
      pillSlot(row.workspaceName, color: Color.theme.textPrimary)
        .pillSlotCap(Self.transientWorkspaceCap)
      // muted は暗地で沈む——読める階調へ上げる。上限を宣言せず残り予算を吸う。
      pillSlot(row.message ?? row.tabTitle, color: Color.theme.statusText)
    }
    .padding(.horizontal, Theme.Space.step)
    .frame(height: 22)
    .background(
      RoundedRectangle(cornerRadius: 5)
        .fill(Color.theme.bgBase)  // 不透明の暗地（メニューバー実背景に依存しない）
        .overlay(RoundedRectangle(cornerRadius: 5).fill(Color.theme.accentPrimary.opacity(0.35)))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 5)
        .strokeBorder(Color.theme.accentPrimary.opacity(0.6), lineWidth: Theme.Stroke.hairline)
    )
    .overlay { if !reduceMotion { PillRipple() } }
    .environment(\.colorScheme, .dark)  // 固定暗地に合わせてインクを dark トークンで解決
    .onHover { ui.transientHovered = $0 }
  }

  /// ②ピルの文字スロット。幅はレイアウト（`PillRow`）が決めるので、ここは体裁だけを持つ。
  private func pillSlot(_ text: String, color: Color) -> some View {
    Text(text)
      .font(.system(size: 11, design: .monospaced))
      .foregroundStyle(color)
      .lineLimit(1)
      .truncationMode(.tail)
  }

  // ③④ 収縮ピル（◐＋件数）。④（ドロップダウン表示中）は accent tint。
  // グリフ・数字とも前景モノクロ（①と同じ template 相当の見え）。
  private var countPill: some View {
    HStack(spacing: 5) {
      OrbeMarkGlyph(size: 15, color: .primary)
      Text("\(store.count)")
        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
        .foregroundStyle(.primary)
    }
    .padding(.horizontal, 7)
    .frame(height: 22)
    .background(
      RoundedRectangle(cornerRadius: 5)
        .fill(
          ui.dropdownOpen
            ? Color.theme.accentPrimary.opacity(0.35) : Color.theme.surfaceInk.opacity(0.16))
    )
  }
}

/// ②ピルのスロット上限。宣言しないサブビューは残り予算のすべてを上限にできる。
private struct PillSlotCap: LayoutValueKey {
  static let defaultValue: CGFloat = .infinity
}

extension View {
  fileprivate func pillSlotCap(_ width: CGFloat) -> some View {
    layoutValue(key: PillSlotCap.self, value: width)
  }
}

/// ②ピルの行レイアウト。`budget` の中で、サブビューを左から順に
/// 「自分の上限（`pillSlotCap`）と残り予算のうち小さい方」までの内容幅で取らせる。
/// 上限を宣言しない本文が残り予算を吸うため、WS 名が短いほど文言が長く出る。
///
/// HStack ではこれが作れない——`.frame(maxWidth:)` は静的な上限しか持てず隣の兄弟の実幅を
/// 参照できないうえ、柔軟な子へ幅を均等に配ろうとして内容と無関係なスロット幅を作る。
///
/// 提案幅は見ない（`sizeThatFits` は予算と理想幅だけで決める）＝内容ハグ。メニューバー
/// アイテムの幅は `MenuBarController` が intrinsic から `statusItem.length` へ明示反映する。
struct PillRow: Layout {
  let spacing: CGFloat
  /// 水平 padding を除いた内側予算。
  let budget: CGFloat

  struct Cache {
    var widths: [CGFloat]
    var height: CGFloat
  }

  func makeCache(subviews: Subviews) -> Cache { measure(subviews) }
  func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = measure(subviews) }

  /// 左から順に予算を配る。理想幅が収まればそのまま、収まらなければ予算を提案し直して
  /// **切り詰め後の実幅**を採る（上限ちょうどで提案すると最大 1 文字ぶんの端数がスロット内に
  /// 空白として残るため、その端数を次のスロットへ回す）。
  private func measure(_ subviews: Subviews) -> Cache {
    var remaining = budget
    var widths: [CGFloat] = []
    var height: CGFloat = 0
    for (index, subview) in subviews.enumerated() {
      if index > 0 { remaining -= spacing }
      let ideal = subview.sizeThatFits(.unspecified)
      let allowance = min(subview[PillSlotCap.self], remaining)
      let width =
        ideal.width <= allowance
        ? ideal.width
        : subview.sizeThatFits(ProposedViewSize(width: allowance, height: nil)).width
      widths.append(width)
      remaining -= width
      height = max(height, ideal.height)
    }
    return Cache(widths: widths, height: height)
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
    let gaps = spacing * CGFloat(max(0, subviews.count - 1))
    return CGSize(width: cache.widths.reduce(0, +) + gaps, height: cache.height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache
  ) {
    var x = bounds.minX
    for (index, subview) in subviews.enumerated() {
      let width = cache.widths[index]
      subview.place(
        at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
        proposal: ProposedViewSize(width: width, height: bounds.height))
      x += width + spacing
    }
  }
}

/// 波紋 1 回（デザイン mpulse＝box-shadow 0→7px リング・2.4s ease-out の**ピル内翻案**）。
/// メニューバー高では外向きリングが物理的に収まらないため、ピル内側から縁へ広がって
/// 消えるリング（scale＋opacity）で「1 回の脈動」の意図を保つ。
private struct PillRipple: View {
  @State private var expanded = false

  var body: some View {
    RoundedRectangle(cornerRadius: 5)
      .strokeBorder(Color.theme.accentPrimary.opacity(0.45), lineWidth: 1.5)
      .scaleEffect(expanded ? 1 : 0.7)
      .opacity(expanded ? 0 : 0.9)
      .onAppear {
        withAnimation(.easeOut(duration: 2.4)) { expanded = true }
      }
      .allowsHitTesting(false)
  }
}
