import AppKit
import SwiftUI

/// サイドバー: ソース管理パネル（見本 ScmPanel）。上から、パネルヘッダー → 実行中の帯（0.3 秒を超えて走る操作があるときだけ）→
/// 区分見出し「ソース管理」（✓ コミット・再読込・…（プル / プッシュ / フェッチ））→ メッセージ欄・コミットボタン・失敗の文 →
/// 列（2 区分とグラフ。AppKit）。git 管理外の根では、ヘッダーの下に理由の一文だけ。部分ごとに別の view にして、読む値が
/// 変わった部分だけを組み直す（status が届くたびに欄まで組み直さない）。根が変わると面は panel と列を組で作り直すので、中身は
/// panel で同一視する（そうしないと載せた列・欄の AppKit と言語の追従が前の根のまま残る）。
struct ScmPanelView: View {
  let panel: ScmPanel
  let list: RowList<ScmListSource>
  @Environment(\.localization) private var l10n

  var body: some View {
    EditorSidebarPanel {
      EditorPanelHeader(title: l10n.string(.editorScmTitle)) { EmptyView() }
      if panel.isManaged == false {
        Text(l10n.string(.editorScmNotManaged))
          .font(Font.theme.editorScmNote)
          .foregroundStyle(Color.theme.editorTertiary)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 18)
          .padding(.vertical, Theme.Space.step)
      } else {
        ScmBand(control: panel.control)
        ScmControlsHead(panel: panel)
        if panel.isControlsOpen { ScmControls(panel: panel) }
        ScmList(panel: panel, list: list)
      }
    }
    .id(ObjectIdentifier(panel))
    .onDisappear(perform: panel.panelDidHide)
  }
}

/// 実行中の帯 28（見本に無い。決定の図）: 上端に流れる細い線、操作名・git の進捗の最新の行（末尾省略）・右端に「止める」。
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

/// 区分見出し「ソース管理」22（padding 0 8 0 4）: シェブロン（下の欄・ボタン・失敗の文を畳む）・題・右端に ✓（コミット。⌘↵ と
/// 同じ条件）・再読込（status を取り直し、グラフと HEAD の push 済みを読み直す）・…（プル / プッシュ / フェッチ。
/// ネット操作中は全部押せない）。
private struct ScmControlsHead: View {
  let panel: ScmPanel
  @State private var hovering = false
  @Environment(\.colorScheme) private var scheme
  @Environment(\.localization) private var l10n

  private static let hoverAlpha = 0.04

  var body: some View {
    let state = panel.commitState
    HStack(spacing: 0) {
      TreeChevron(open: panel.isControlsOpen)
      Text(l10n.string(.editorScmTitle))
        .font(Font.theme.editorScmSection)
        .foregroundStyle(Color.theme.editorText)
        .lineLimit(1)
      Spacer(minLength: 0)
      HStack(spacing: 1) {
        ScmToolButton(
          glyph: EditorGlyphs.check, help: l10n.string(.editorScmCommit), isEnabled: state.canCommit
        ) { panel.commit() }
        ScmToolButton(
          glyph: EditorGlyphs.refresh, help: l10n.string(.editorScmRefresh), isEnabled: true,
          action: panel.refresh)
        ScmToolButton(
          glyph: EditorGlyphs.more, help: l10n.string(.editorScmMoreActions), isEnabled: true,
          menu: {
            ScmMenu.make([
              ScmMenu.Item(l10n.string(.editorScmPull), state.canNetwork, panel.control.pull),
              ScmMenu.Item(l10n.string(.editorScmPush), state.canNetwork, panel.control.push),
              ScmMenu.Item(l10n.string(.editorScmFetch), state.canNetwork, panel.control.fetch),
            ])
          })
      }
    }
    .padding(.leading, Theme.Space.tick)
    .padding(.trailing, Theme.Space.step)
    .frame(height: Theme.Layout.editorScmRow)
    .background(hovering ? EditorInk(scheme).fill(Self.hoverAlpha) : .clear)
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .onTapGesture { panel.isControlsOpen.toggle() }
  }
}

/// メッセージ欄・コミットボタン・失敗の文（padding 2 12 8・gap 6）。
private struct ScmControls: View {
  let panel: ScmPanel
  @Environment(\.localization) private var l10n

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.note) {
      ScmMessageBox(panel: panel, placeholder: placeholder)
      ScmCommitButton(panel: panel)
      if let failure = panel.control.failure,
        let text = ScmFailureText.text(failure.cause, l10n.language)
      {
        Text(text)
          .font(Font.theme.editorScmNote)
          .lineSpacing(Self.failureLineSpacing)
          .foregroundStyle(Color.theme.danger)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, Theme.Space.hair)
          .textSelection(.enabled)
      }
    }
    .padding(.horizontal, 12)
    .padding(.top, Theme.Space.hair)
    .padding(.bottom, Theme.Space.step)
  }

  /// 失敗の文の行間（見本の行高 1.5 から、字の行の高さを引いた分）。
  private static let failureLineSpacing =
    Theme.Typography.editorScmNote.pointSize * 1.5
    - NSLayoutManager().defaultLineHeight(for: Theme.Typography.editorScmNote)

  /// プレースホルダ（ブランチに居ればその名前。detached・初回コミット前は名前なし）。
  private var placeholder: String {
    if let name = panel.branch?.name, panel.branch?.commit != nil {
      return l10n.format(.editorScmPlaceholderBranch, name)
    }
    return l10n.string(.editorScmPlaceholder)
  }
}

/// メッセージ欄の箱（見本 inputBox: radius 3・枠 hairline .10・地 sunk .35。焦点で radius 5・枠 accent .55）。
private struct ScmMessageBox: View {
  let panel: ScmPanel
  let placeholder: String
  @State private var focused = false
  @Environment(\.colorScheme) private var scheme

  private static let sunkAlpha = 0.35
  private static let borderAlpha = 0.10
  private static let focusBorderAlpha = 0.55

  var body: some View {
    let ink = EditorInk(scheme)
    let shape = RoundedRectangle(cornerRadius: focused ? 5 : Theme.Radius.xs)
    ScmMessageField(panel: panel, placeholder: placeholder, focused: $focused)
      .background(shape.fill(ink.sunk(Self.sunkAlpha)))
      .overlay(
        shape.strokeBorder(
          focused
            ? Color.theme.accentPrimary.opacity(Self.focusBorderAlpha)
            : ink.hairline(Self.borderAlpha),
          lineWidth: Theme.Stroke.hairline))
  }
}

/// コミットボタン（見本 primaryButton 26・radius 3・地 accent・字 tabActiveText 12 semibold）: 主の働き（コミット / 同期 ↑N ↓M /
/// ブランチを公開）＋縦線 ＋ ▾（コミット (amend) / コミットしてプッシュ / ─ / 最後のコミットを取り消す）。地は側ごとに持ち、
/// 押せない側は地ごと design-system の disabled にする（字だけ薄くすると、紫の地が押せる姿のまま残る）。▾ は中の項目が
/// 1 つも押せないときだけ押せない姿で、開かない。
private struct ScmCommitButton: View {
  let panel: ScmPanel
  @Environment(\.localization) private var l10n

  private static let dividerAlpha = 0.25

  var body: some View {
    let state = panel.commitState
    HStack(spacing: 0) {
      HStack(spacing: Theme.Space.note) {
        EditorGlyphView(glyph: glyph(state.primary), size: 13, color: Color.theme.tabActiveText)
        Text(label(state.primary))
          .font(Font.theme.editorScmButton)
          .foregroundStyle(Color.theme.tabActiveText)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.theme.accentPrimary)
      .contentShape(Rectangle())
      .onTapGesture { if state.isPrimaryEnabled { primary(state.primary) } }
      .opacity(state.isPrimaryEnabled ? 1 : Theme.Opacity.disabled)
      HStack(spacing: 0) {
        Rectangle()
          .fill(Color.theme.bgBase.opacity(Self.dividerAlpha))
          .frame(width: Theme.Stroke.hairline)
        EditorGlyphView(glyph: EditorGlyphs.chevronDown, size: 12, color: Color.theme.tabActiveText)
          .frame(width: Theme.Layout.editorScmCommitCaret)
          .frame(maxHeight: .infinity)
      }
      .background(Color.theme.accentPrimary)
      .opacity(state.isMenuEnabled ? 1 : Theme.Opacity.disabled)
      .overlay {
        ScmMenuAnchor(
          help: l10n.string(.editorScmCommitActions), isEnabled: state.isMenuEnabled
        ) { menu(panel.commitState) }
      }
    }
    .frame(height: Theme.Layout.editorScmCommitButton)
    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xs))
  }

  private func glyph(_ primary: ScmCommitState.Primary) -> EditorGlyphs.Glyph {
    switch primary {
    case .commit: EditorGlyphs.commitCheck
    case .sync: EditorGlyphs.sync
    case .publish: EditorGlyphs.publish
    }
  }

  private func label(_ primary: ScmCommitState.Primary) -> String {
    switch primary {
    case .commit: return l10n.string(.editorScmCommit)
    case .sync(let divergence): return l10n.string(.editorScmSync) + " " + divergence.arrows
    case .publish: return l10n.string(.editorScmPublish)
    }
  }

  private func primary(_ primary: ScmCommitState.Primary) {
    switch primary {
    case .commit: panel.commit()
    case .sync: panel.control.sync()
    case .publish: panel.control.publish()
    }
  }

  private func menu(_ state: ScmCommitState) -> NSMenu {
    ScmMenu.make([
      ScmMenu.Item(l10n.string(.editorScmAmend), state.canAmend, panel.amend),
      ScmMenu.Item(
        l10n.string(.editorScmCommitAndPush), state.canCommitAndPush, panel.commitAndPush),
      nil,
      ScmMenu.Item(l10n.string(.editorScmUndo), state.canUndo, panel.control.undoLastCommit),
    ])
  }
}

/// 列（pane が持つ `RowList`）を載せる。読む値（行の版・選択・焦点の要求・絵文字の字体）をここで読んで列へ渡し、言語が
/// 変われば行の文言を読み直させる。
private struct ScmList: View {
  let panel: ScmPanel
  let list: RowList<ScmListSource>
  @Environment(\.chromeFontResolver) private var fontResolver
  @Environment(\.localization) private var l10n

  var body: some View {
    RowListHost(
      list: list, rowsVersion: panel.rowsVersion, selection: panel.selection,
      emoji: fontResolver.emojiFont, wantsFocus: panel.focusRequest == .list
    )
    .onChange(of: l10n.language, initial: true) { _, language in
      guard list.list.source.language != language else { return }
      list.list.source.language = language
      list.list.reloadRows()
    }
  }
}

/// 見出しのツール 20（radius 4・hover 地 fill .08 で字が上がる。既定の字 muted）。押せない姿は字を薄くし、押しても何もしない。
/// `menu` を渡すと押下で OS のメニューを出す。
private struct ScmToolButton: View {
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
      if let menu { ScmMenuAnchor(help: help, menu: menu) }
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
