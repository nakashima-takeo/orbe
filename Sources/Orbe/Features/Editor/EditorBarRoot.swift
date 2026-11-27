import AppKit
import SwiftUI

/// 上のバー（高さ 36。下端の hairline を含む）の SwiftUI ルート。左から、左の列の開閉・画面の切り替え（Changes の件数・PR の
/// 番号つき）・今の項目のボタン（今の項目があるとき。前に区切り線。仮の文書なら後ろに「プレビュー」の札と「開いたままに
/// する」）・画面ごとの中ほどの部品、右寄せで「⌥ 端末を表示」の案内と画面ごとの右端の部品。器の中の別 root なので環境は
/// 明示注入する。押してもフォーカスを取らない（host が first responder を受けない）。幅は `EditorBarLayout` が、部品の
/// 名乗る譲る順（`EditorBarYield`）で配る——案内はまるごと落ち、今の項目のボタンは親のパス、その次に名前の全体を譲る。
/// 開閉・切り替え・今の項目のボタン・「プレビュー」の札・「開いたままにする」は落とさない。画面ごとの部品は、
/// 画面ごとのファイル（`EditorBar+<画面>.swift`）に書く。ボタンの枠は、閉包で pane へ知らせる（一覧の器の位置の入力）。
struct EditorBarRoot: View {
  let shell: EditorShellModel
  /// 左の列の開閉の持ち主（pane と同じ 1 つ）。
  let sidebar: EditorSidebarState
  /// 一覧の器（開閉の持ち主。開いている間は今の項目のボタンを開いている姿にする）。
  let itemList: EditorItemList
  /// Changes の件数・ブランチ・同期の持ち主。
  let scm: ScmPanel
  /// コミットのポップアップの持ち主（Changes の右端の「コミット」が開閉に使う）。
  let commitPopup: ScmCommitPopup
  /// PR の番号の持ち主（worktree の今の PR）。
  let pullRequest: BranchPullRequest
  /// ファイル内検索の欄の持ち主（Files の中ほど）。
  let findField: EditorFindField
  let localization: LocalizationStore
  let fontResolver: ChromeFontResolver
  /// 部品の間隔。
  static let spacing: CGFloat = 6
  /// 部品の枠を測る座標空間（バーの座標＝面の座標）。
  static let space = "editorBar"

  var body: some View {
    EditorBarRow {
      EditorSidebarToggle(isOpen: sidebar.isOpen, action: shell.toggleSidebar)
      EditorScreenSwitch(
        selection: shell.panel.screen, changesCount: scm.count,
        pullRequestNumber: pullRequest.state?.key.id.number, select: shell.selectScreen
      )
      .fixedSize()
      if let item = shell.currentItem { currentItem(item) }
      middle
      EditorPeekHint(isPeeking: shell.isPeeking).editorBarPart(.trailing, drops: .hint)
      trailing
    }
    .environment(\.editorBarActionFrame, shell.actionButtonFrameDidChange)
    .environment(\.localization, localization)
    .environment(\.chromeFontResolver, fontResolver)
  }

  /// 今の画面の、今の項目の後ろに並ぶ部品。
  @ViewBuilder private var middle: some View {
    switch shell.panel.screen {
    case .changes: changesMiddle
    case .pullRequest: pullRequestMiddle
    case .files: filesMiddle
    }
  }

  /// 今の画面の、右端に並ぶ部品。
  @ViewBuilder private var trailing: some View {
    switch shell.panel.screen {
    case .changes: changesTrailing
    case .pullRequest: pullRequestTrailing
    case .files: filesTrailing
    }
  }

  @ViewBuilder
  private func currentItem(_ item: EditorShellModel.CurrentItem) -> some View {
    switch item {
    case .file(let file):
      itemButton(help: .editorBarOpenFiles) { EditorCurrentFileLabel(file: file) }
      if file.isPreview {
        EditorTag(text: localization.string(.editorOpenFilesPreview))
        EditorTextButton(
          title: localization.string(.editorOpenFilesKeepOpen),
          key: file.showsKeepOpenKey ? .glyph(EditorGlyphs.returnKey) : nil, style: .filled,
          action: shell.keepOpen)
      }
    case .diff(let subject):
      itemButton(help: .editorBarChangedFiles) {
        EditorCurrentDiffLabel(header: subject.header(scm: scm))
      }
    }
  }

  /// 区切り線と今の項目のボタン（広い姿を `itemWide` で受け取る）。ボタンの枠は閉包で pane へ知らせる（一覧の器の位置の
  /// 入力）。
  private func itemButton<Label: View>(
    help: L10nKey, @ViewBuilder label: @escaping () -> Label
  ) -> some View {
    HStack(spacing: Self.spacing) {
      EditorBarSeparator()
      EditorItemButton(
        isOpen: itemList.isOpen, help: localization.string(help),
        action: shell.toggleItemList, label: label
      )
      .onGeometryChange(for: CGRect.self) {
        $0.frame(in: .named(Self.space))
      } action: {
        shell.itemButtonFrameDidChange($0)
      }
    }
    .editorBarPart(grows: .itemWide)
  }
}

/// 上のバーの行の器——部品の行（`EditorBarLayout`。行の枠で切る）・左 8 右 12 の余白・高さ・下端の線。行の枠の座標空間
/// （`EditorBarLayout.space`）と、部品の枠を測る座標空間（`EditorBarRoot.space`）を張る。
struct EditorBarRow<Content: View>: View {
  @ViewBuilder let content: () -> Content
  @Environment(\.colorScheme) private var scheme

  private let hairlineAlpha = 0.07

  var body: some View {
    VStack(spacing: 0) {
      EditorBarLayout(spacing: EditorBarRoot.spacing) { content() }
        .coordinateSpace(.named(EditorBarLayout.space))
        .clipped()
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Theme.Layout.editorBar - Theme.Stroke.hairline)
      Rectangle().fill(EditorInk(scheme).hairline(hairlineAlpha))
        .frame(height: Theme.Stroke.hairline)
    }
    .coordinateSpace(.named(EditorBarRoot.space))
  }
}

/// 左の列の開閉（26 角のアイコンのボタン）。開いている間は押された姿。
struct EditorSidebarToggle: View {
  let isOpen: Bool
  let action: () -> Void
  @Environment(\.localization) private var l10n

  var body: some View {
    EditorBarIconButton(
      glyph: EditorGlyphs.sidebarToggle, isPressed: isOpen,
      help: l10n.string(isOpen ? .editorBarHideSidebar : .editorBarShowSidebar), action: action)
  }
}

/// 画面の切り替え: 溝（padding 2・gap 2・radius 9・地 sunk・内側の影）に `Changes <件数>`・`PR <#番号>`・`Files` の 3 項目
/// （高さ 24・padding 0 11・radius 7）。選んでいる項目は地 ink .11 と上縁の明かり・下の影で浮かせ、件数・番号の字を accent にする。
/// 件数は 0 なら出さない（1000 以上は「999+」）。番号は今のブランチに open の PR があるときだけ。
struct EditorScreenSwitch: View {
  let selection: EditorScreen
  let changesCount: Int
  let pullRequestNumber: Int?
  let select: (EditorScreen) -> Void
  @Environment(\.localization) private var l10n

  private static let countLimit = 999
  private static let edgeAlpha = 0.05

  var body: some View {
    HStack(spacing: 2) {
      item(.changes, .editorScreenChanges, count: countText)
      item(.pullRequest, .editorScreenPullRequest, count: pullRequestNumber.map { "#\($0)" })
      item(.files, .editorScreenFiles, count: nil)
    }
    .padding(2)
    .background(
      RoundedRectangle(cornerRadius: 9)
        .fill(
          Color.theme.editorBarGroove.shadow(
            .inner(color: Color.theme.editorBarInset, radius: 1, y: 1)))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 9)
        .strokeBorder(
          Color.theme.surfaceInk.opacity(Self.edgeAlpha), lineWidth: Theme.Stroke.hairline)
    )
  }

  private var countText: String? {
    guard changesCount > 0 else { return nil }
    return changesCount > Self.countLimit ? "\(Self.countLimit)+" : "\(changesCount)"
  }

  private func item(_ screen: EditorScreen, _ label: L10nKey, count: String?) -> some View {
    EditorScreenItem(
      label: l10n.string(label), count: count, isSelected: selection == screen
    ) { select(screen) }
  }
}

private struct EditorScreenItem: View {
  let label: String
  let count: String?
  let isSelected: Bool
  let action: () -> Void

  private static let selectedAlpha = 0.11
  private static let highlightAlpha = 0.1

  var body: some View {
    HStack(spacing: 6) {
      Text(label)
        .font(Font.theme.editorBarSwitch)
        .foregroundStyle(isSelected ? Color.theme.textPrimary : Color.theme.textSecondary)
      if let count {
        Text(count)
          .font(Font.theme.editorBarCount)
          .foregroundStyle(isSelected ? Color.theme.accentBright : Color.theme.textMuted)
      }
    }
    .lineLimit(1)
    .fixedSize()
    .padding(.horizontal, 11)
    .frame(height: 24)
    .background {
      if isSelected {
        RoundedRectangle(cornerRadius: 7)
          .fill(
            Color.theme.surfaceInk.opacity(Self.selectedAlpha)
              .shadow(
                .inner(color: Color.theme.surfaceInk.opacity(Self.highlightAlpha), radius: 0, y: 1)
              )
              .shadow(.drop(color: Color.theme.editorBarInset, radius: 1, y: 1))
          )
      }
    }
    .contentShape(Rectangle())
    .onTapGesture(perform: action)
  }
}

/// 右寄せの案内「⌥ 端末を表示」（gap 7・mono 11・textMuted）。⌥ はキーの札。押せない。⌥ で透かしている間は押している間の姿
/// （字を textPrimary、札を地 accent・印 onAccent）。
struct EditorPeekHint: View {
  let isPeeking: Bool
  @Environment(\.localization) private var l10n

  var body: some View {
    HStack(spacing: 7) {
      if isPeeking {
        EditorKeyCap(
          content: .glyph(EditorGlyphs.optionKey), foreground: Color.theme.onAccent,
          ground: Color.theme.accentPrimary)
      } else {
        EditorKeyCap(content: .glyph(EditorGlyphs.optionKey))
      }
      Text(l10n.string(.editorBarShowTerminal))
        .font(Font.theme.editorBarHint)
        .foregroundStyle(isPeeking ? Color.theme.textPrimary : Color.theme.textMuted)
        .lineLimit(1)
    }
    .fixedSize()
  }
}

/// 上のバーの host。押してもフォーカスを取らない——フォーカスはバーの操作が決める（画面の切り替え・左の列の開閉）。
final class EditorBarHost: NSHostingView<EditorBarRoot> {
  override var acceptsFirstResponder: Bool { false }
}

/// 上のバーより下の中身をまとめる view。中身の枠は pane と同じ座標で置く（面いっぱいの枠で、上下を反転した座標）。
final class EditorBelowBar: NSView {
  override var isFlipped: Bool { true }
}
