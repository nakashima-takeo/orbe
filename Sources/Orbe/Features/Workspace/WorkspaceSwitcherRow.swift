import SwiftUI

/// WS切替オーバーレイ（⌘⇧S 一覧）専用の行コンテンツ（design 改善案）。
/// `[名前(統一色 textPrimary)] [インラインチップ群] [spacer] [パス(muted・右端 tail 省略)]`。
/// チップ = 状態アイコン（12pt・状態色）＋（件数≠1 のとき ×N）。0件・未知状態は出さない。
/// 選択の地色・dormant 減光は器（`SelectableRow`・`PaletteCard`）が担う。
struct WorkspaceSwitcherRow: View {
  let name: String
  /// 状態ロールアップ（`[(state, count)]`・正準順 working→waiting→done→idle で渡る）。
  /// 0件・未知状態は `statusSegments` が落とす。
  let rollup: [(state: String, count: Int)]
  let path: String

  /// 主名の絵文字 run 割り当て（現行 PaletteRow と同じ扱い）。
  @Environment(\.chromeFontResolver) private var fontResolver
  /// 状態アイコン上書き（`agentStateIcons` 設定）。他の chrome 面（タブ行・TopBar ロールアップ）と同じく、
  /// ユーザーが状態→SF Symbol を差し替えたらチップにも反映する。
  @Environment(\.agentIconResolver) private var iconResolver

  var body: some View {
    HStack(spacing: 0) {
      fontResolver.text(name, base: Theme.Typography.workspaceName)
        .font(Font.theme.workspaceName)
        .foregroundStyle(Color.theme.textPrimary)  // 名前は全行一律（状態・選択で変えない）
        .lineLimit(1)
        .layoutPriority(1)
      chips
        .padding(.leading, Theme.Space.span)  // 名前↔チップ群 = 20
      Spacer(minLength: 0)
      fontResolver.text(path, base: Theme.Typography.meta)
        .font(Font.theme.meta)
        .foregroundStyle(Color.theme.textMuted)
        .lineLimit(1)
        .truncationMode(.tail)
    }
  }

  /// インラインチップ群（gap 10）。各チップ = アイコン＋（×N・件数≠1 のみ）。縮まない。
  private var chips: some View {
    HStack(spacing: 10) {
      ForEach(statusSegments(rollup)) { seg in
        HStack(spacing: Theme.Space.hair) {  // アイコン↔×N = 2
          // color 省略＝状態色。symbol は agentStateIcons 上書き（未設定なら nil→既定 Glass）。
          StatusGlyphView(kind: seg.kind, size: 12, symbol: iconResolver.symbol(for: seg.kind))
          if seg.count != 1 {
            Text("×\(seg.count)")
              .font(.system(size: 12, weight: .regular, design: .monospaced))
              .tracking(2)  // design letterSpacing 2px
              .foregroundStyle(Color.theme.statusText)
          }
        }
      }
    }
    .fixedSize()  // flexShrink:0 相当（チップ群は縮まない）
  }
}
