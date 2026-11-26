import AppKit
import SwiftUI

/// 左の列: ソース管理パネル。上から、パネルヘッダー → 親「ソース管理」（見出し・変更の列〔2 つの子の区分。AppKit。
/// 変更が無ければ「変更なし」の一言〕）→ 境目 → グラフの枠（区切り線・見出し「グラフ」・グラフの列。AppKit）。git 管理外の
/// 根では、ヘッダーの下に「表示できません」の一言だけ（見出しと理由は本体が出す）。部分ごとに別の view にして、読む値が
/// 変わった部分だけを組み直す。
/// 根が変わると面は panel と列を組で作り直すので、中身は panel で同一視する（そうしないと載せた列の AppKit と言語の追従が
/// 前の根のまま残る）。
struct ScmPanelView: View {
  let panel: ScmPanel
  let list: RowList<ScmListSource>
  let graphList: RowList<ScmGraphSource>
  /// グラフの枠の高さの持ち主（アプリ全体で 1 つ）。
  let sidebar: EditorSidebarState
  @Environment(\.localization) private var l10n

  var body: some View {
    EditorSidebarPanel {
      EditorPanelHeader(title: l10n.string(.editorScmTitle)) { EmptyView() }
      if panel.isManaged == false {
        EditorSidebarNote(text: l10n.string(.editorUnavailable))
      } else {
        ScmSplit(panel: panel, list: list, graphList: graphList, sidebar: sidebar)
      }
    }
    .id(ObjectIdentifier(panel))
    .onDisappear(perform: panel.panelDidHide)
  }
}

/// 親「ソース管理」の見出し 22（padding 0 8 0 4）: シェブロン（2 つの子の区分をまとめて畳む）・題・右端に
/// 再読込（status を取り直し、グラフと HEAD の push 済みを読み直す）・…（プル / プッシュ / フェッチ）。
struct ScmRepositoryHead: View {
  let panel: ScmPanel
  @State private var hovering = false
  @Environment(\.colorScheme) private var scheme
  @Environment(\.localization) private var l10n

  private static let hoverAlpha = 0.04

  var body: some View {
    HStack(spacing: 0) {
      TreeChevron(open: panel.isRepositoryOpen)
      Text(l10n.string(.editorScmTitle))
        .font(Font.theme.editorScmSection)
        .foregroundStyle(Color.theme.editorText)
        .lineLimit(1)
      Spacer(minLength: 0)
      HStack(spacing: Theme.Layout.editorScmToolGap) {
        ScmToolButton(
          glyph: EditorGlyphs.refresh, help: l10n.string(.editorScmRefresh), isEnabled: true,
          action: panel.refresh)
        ScmToolButton(
          glyph: EditorGlyphs.more, help: l10n.string(.editorScmMoreActions), isEnabled: true,
          menu: moreMenu)
      }
    }
    .padding(.leading, Theme.Space.tick)
    .padding(.trailing, Theme.Space.step)
    .frame(height: Theme.Layout.editorScmRow)
    .background(hovering ? EditorInk(scheme).fill(Self.hoverAlpha) : .clear)
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .onTapGesture { panel.setRepositoryOpen(!panel.isRepositoryOpen) }
  }

  /// …（項目は開いた時点の姿で照らす）。
  private func moreMenu() -> NSMenu {
    let canNetwork = panel.commitState.canNetwork
    return ScmMenu.make([
      ScmMenu.Item(l10n.string(.editorScmPull), canNetwork, panel.pull),
      ScmMenu.Item(l10n.string(.editorScmPush), canNetwork, panel.control.push),
      ScmMenu.Item(l10n.string(.editorScmFetch), canNetwork, panel.control.fetch),
    ])
  }
}

/// 見出しのツール 20（radius 4・hover 地 fill .08 で字が上がる。既定の字 muted）。押せない姿は字を薄くし、押しても何もしない。
/// `menu` を渡すと押下で OS のメニューを出す。
struct ScmToolButton: View {
  let glyph: EditorGlyphs.Glyph
  let help: String
  let isEnabled: Bool
  var action: () -> Void = {}
  var menu: (() -> NSMenu)?
  @State private var hovering = false
  @Environment(\.colorScheme) private var scheme

  private static let hoverAlpha = 0.08
  private static let disabledOpacity = 0.35

  var body: some View {
    let lit = hovering && isEnabled
    EditorGlyphView(
      glyph: glyph, size: Theme.Layout.editorScmGlyph,
      color: lit ? Color.theme.editorText : Color.theme.textMuted
    )
    .opacity(isEnabled ? 1 : Self.disabledOpacity)
    .frame(width: Theme.Layout.editorScmTool, height: Theme.Layout.editorScmTool)
    .background(
      RoundedRectangle(cornerRadius: Theme.Radius.sm)
        .fill(lit ? EditorInk(scheme).fill(Self.hoverAlpha) : .clear)
    )
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .overlay {
      if let menu { ScmMenuAnchor(help: help, isEnabled: isEnabled, menu: menu) }
    }
    .onTapGesture { if isEnabled, menu == nil { action() } }
    .help(help)
  }
}
