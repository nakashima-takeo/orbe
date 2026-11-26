import AppKit
import SwiftUI

/// 左の列: ソース管理パネル。上から、パネルヘッダー → 実行中の帯（0.3 秒を超えて走る操作があるときだけ）→
/// 親「ソース管理」（見出し・失敗の文〔コミットのポップアップの赤い行に出していないものだけ〕・変更の列〔2 つの子の区分。
/// AppKit〕）→ 境目 → グラフの枠（区切り線・見出し「グラフ」・グラフの列。AppKit）。git 管理外の根では、ヘッダーの下に
/// 「表示できません」の一言だけ（見出しと理由は本体が出す）。部分ごとに別の view にして、読む値が変わった部分だけを組み直す。
/// 根が変わると面は panel と列を組で作り直すので、中身は panel で同一視する（そうしないと載せた列の AppKit と言語の追従が
/// 前の根のまま残る）。
struct ScmPanelView: View {
  let panel: ScmPanel
  let commitPopup: ScmCommitPopup
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
        ScmBand(control: panel.control)
        ScmSplit(
          panel: panel, commitPopup: commitPopup, list: list, graphList: graphList,
          sidebar: sidebar)
      }
    }
    .id(ObjectIdentifier(panel))
    .onDisappear(perform: panel.panelDidHide)
  }
}

/// 実行中の帯 28: 上端に流れる細い線、操作名・git の進捗の最新の行（末尾省略）・右端に「止める」。
private struct ScmBand: View {
  let control: SourceControl
  @Environment(\.colorScheme) private var scheme
  @Environment(\.localization) private var l10n

  private static let groundAlpha = 0.035
  private static let hairlineAlpha = 0.07
  private static let stopAlpha = 0.08

  var body: some View {
    if let operation = control.bandOperation {
      let ink = EditorInk(scheme)
      HStack(spacing: Theme.Space.step) {
        Text(l10n.string(operation.kind.runningLabel))
          .font(Font.theme.editorScmBandName)
          .foregroundStyle(Color.theme.editorText)
          .lineLimit(1)
          .fixedSize()
        Text(operation.progress ?? "")
          .font(Font.theme.editorScmBandProgress)
          .foregroundStyle(Color.theme.textMuted)
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(maxWidth: .infinity, alignment: .leading)
        HStack(spacing: Theme.Space.tick) {
          EditorGlyphView(glyph: EditorGlyphs.stopSquare, size: 9, color: Color.theme.editorText)
          Text(l10n.string(.editorScmStop))
            .font(Font.theme.editorScmStop)
            .foregroundStyle(Color.theme.editorText)
        }
        .padding(.horizontal, Theme.Space.step)
        .frame(height: Theme.Layout.editorScmStop)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.xs).fill(ink.fill(Self.stopAlpha)))
        .contentShape(Rectangle())
        .onTapGesture(perform: operation.stop)
      }
      .padding(.leading, 18)
      .padding(.trailing, Theme.Space.step)
      .frame(height: Theme.Layout.editorScmBand)
      .background(ink.fill(Self.groundAlpha))
      .overlay(alignment: .top) {
        ZStack(alignment: .top) {
          Rectangle().fill(ink.hairline(Self.hairlineAlpha)).frame(height: Theme.Stroke.hairline)
          EditorProgressLine()
        }
      }
      .overlay(alignment: .bottom) {
        Rectangle().fill(ink.hairline(Self.hairlineAlpha)).frame(height: Theme.Stroke.hairline)
      }
    }
  }
}

/// 親「ソース管理」の見出し 22（padding 0 8 0 4）: シェブロン（失敗の文と 2 つの子の区分をまとめて畳む）・題・右端に
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

/// 失敗の文（padding 2 12 8）。コミットのポップアップの赤い行に出している失敗は、ここに重ねて出さない。
struct ScmFailureNote: View {
  let panel: ScmPanel
  let isCommitPopupOpen: Bool
  @Environment(\.localization) private var l10n

  var body: some View {
    if ScmFailurePlace(panel.control.failure, isCommitPopupOpen: isCommitPopupOpen) == .outside,
      let failure = panel.control.failure, let text = ScmFailureText.text(failure, l10n.language)
    {
      Text(text)
        .font(Font.theme.editorScmNote)
        .lineSpacing(Self.lineSpacing)
        .foregroundStyle(Color.theme.danger)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Space.hair)
        .textSelection(.enabled)
        .padding(.horizontal, 12)
        .padding(.top, Theme.Space.hair)
        .padding(.bottom, Theme.Space.step)
    }
  }

  /// 失敗の文の行間（design-system の行高 1.5）。
  private static let lineSpacing = Theme.Typography.editorScmNote.extraLeading(lineHeight: 1.5)
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

extension SourceControl.Kind {
  /// 実行中の帯の操作名。
  var runningLabel: L10nKey {
    switch self {
    case .stage: .editorScmRunningStage
    case .unstage: .editorScmRunningUnstage
    case .discard: .editorScmRunningDiscard
    case .commit: .editorScmRunningCommit
    case .amend: .editorScmRunningAmend
    case .undo: .editorScmRunningUndo
    case .pull: .editorScmRunningPull
    case .push: .editorScmRunningPush
    case .fetch: .editorScmRunningFetch
    case .sync: .editorScmRunningSync
    case .publish: .editorScmRunningPublish
    case .commitAndPush: .editorScmRunningCommitAndPush
    }
  }
}
