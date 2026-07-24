import SwiftUI

/// メニューバーアイテム本体（①②③④の描画・デザイン第11シーンの数値をトークン経由で移植）。
/// ① 要対応 0（working だけの間も含む）: ◐ 15pt・opacity 0.45・数字なし。
/// ② `store.transient` が生きている間: ピル（高さ 22・radius 5・地 accent 35%）に
///    ◐＋状態グリフ 11＋WS 名 11＋文言先頭 11 muted（max 150・省略）が滲み出る。波紋 1 回。
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

  // ②状態変化の瞬間。WS 名＋文言の先頭が滲み出る（文言なしはタブタイトル）。
  private func transientPill(_ row: AttentionRow) -> some View {
    HStack(spacing: Theme.Space.note) {
      OrbeMarkGlyph(size: 15)  // accent 地の上ではブランドグラデを保つ
      if let kind = AgentStateIcon.kind(state: row.state) {
        StatusGlyphView(kind: kind, size: 11)
      }
      Text(row.workspaceName)
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(Color.theme.textPrimary)
        .lineLimit(1)
      Text(row.message ?? row.tabTitle)
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(Color.theme.textMuted)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: 150, alignment: .leading)
        .fixedSize(horizontal: false, vertical: false)
    }
    .padding(.horizontal, Theme.Space.step)
    .frame(height: 22)
    .background(
      RoundedRectangle(cornerRadius: 5).fill(Color.theme.accentPrimary.opacity(0.35))
    )
    .overlay { if !reduceMotion { PillRipple() } }
    .onHover { ui.transientHovered = $0 }
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
