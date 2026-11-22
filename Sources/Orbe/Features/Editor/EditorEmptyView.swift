import SwiftUI

/// 本体が空のときの、画面ごとの表示。出すものが無い・表示できないときは、中央に見出しと案内の一文と（あれば）ボタンか
/// ショートカットの行を出し、出すものがまだ決まらない間（判定の前・読み込み中・diff が自動で開く前）は何も出さない。
/// Files は文書を開いていないとき、Changes は git 管理外と変更なし、PR は worktree の今の PR の答えで決まる。
struct EditorEmptyView: View {
  let screen: EditorScreen
  let scm: ScmPanel
  let pullRequest: PrPanel
  @Environment(\.localization) private var l10n

  var body: some View {
    switch screen {
    case .files: files
    case .changes: changes
    case .pullRequest: pullRequestMessage
    }
  }

  private var files: some View {
    EditorMessage(title: l10n.string(.editorEmptyLead)) {
      VStack(spacing: 6) {
        EditorShortcutRow(label: l10n.string(.editorEmptySearchProject), key: "⌘⇧F")
        EditorShortcutRow(label: l10n.string(.editorEmptyBackToTerminal), key: "⌘E")
      }
      .padding(.top, 8)
    }
  }

  @ViewBuilder private var changes: some View {
    if scm.isManaged == false {
      EditorMessage(
        title: l10n.string(.editorScmUnavailableTitle), lead: l10n.string(.editorScmNotManaged))
    } else if scm.isManaged == true, scm.rowsVersion > 0, scm.count == 0 {
      EditorMessage(
        title: l10n.string(.editorScmNoChanges), lead: l10n.string(.editorScmNoChangesLead))
    }
  }

  @ViewBuilder private var pullRequestMessage: some View {
    switch pullRequest.pullRequest.answer {
    case .reading: EmptyView()
    case .noPullRequest(let creation):
      let published = creation.published != .no
      EditorMessage(
        title: l10n.string(.editorPrNone),
        lead: l10n.string(published ? .editorPrNoneLead : .editorPrPublishFirst)
      ) {
        EditorMessageButton(
          title: l10n.string(.editorPrCreate), isPrimary: true, isEnabled: published,
          action: pullRequest.createPullRequest)
      }
    case .unavailable(.failed(let failure)):
      failed(PrPanelText.unavailable(.failed(failure), l10n))
    case .unavailable(let reason):
      EditorMessage(
        title: l10n.string(.editorPrUnavailableTitle),
        lead: PrPanelText.unavailable(reason, l10n))
    case .pullRequest(let state):
      if state.content == nil, let failure = PrPanelText.failure(of: pullRequest, state, l10n) {
        failed(failure)
      }
    }
  }

  /// 読み込みの失敗——見出しと失敗の文に「再読込」を添える。
  private func failed(_ text: String) -> some View {
    EditorMessage(title: l10n.string(.editorPrUnavailableTitle), lead: text) {
      EditorMessageButton(
        title: l10n.string(.editorPrRefresh), isPrimary: false, isEnabled: true,
        action: pullRequest.refresh)
    }
  }
}

/// 本体の中央の見出し（sans 14 medium・textSecondary）と案内の一文（sans 12.5・textMuted）、その下の部品（ボタンなら 12 下）。
/// 置き場は本体の下 60 を除いた範囲の中央（デザインの見本の `.emp`）。
private struct EditorMessage<Extra: View>: View {
  let title: String
  var lead: String?
  @ViewBuilder var extra: Extra

  var body: some View {
    VStack(spacing: 6) {
      Text(title)
        .font(Font.theme.editorEmptyTitle)
        .foregroundStyle(Color.theme.textSecondary)
      if let lead {
        Text(lead)
          .font(Font.theme.editorEmptyText)
          .foregroundStyle(Color.theme.textMuted)
      }
      extra
    }
    .multilineTextAlignment(.center)
    .fixedSize(horizontal: false, vertical: true)
    .padding(.horizontal, Theme.Space.bar)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(.bottom, 60)
  }
}

extension EditorMessage where Extra == EmptyView {
  init(title: String, lead: String? = nil) {
    self.init(title: title, lead: lead) { EmptyView() }
  }
}

/// 案内のボタン（高さ 30・padding 0 14・radius 8・sans 12.5）。主のボタンは地 accent・字 onAccent の semibold、ほかは地 ink .08・
/// 字 textPrimary。押せない間は design-system の disabled に薄める。押してもフォーカスを取らない。
private struct EditorMessageButton: View {
  let title: String
  let isPrimary: Bool
  let isEnabled: Bool
  let action: () -> Void

  private static let groundAlpha = 0.08

  var body: some View {
    Text(title)
      .font(isPrimary ? Font.theme.editorEmptyButton : Font.theme.editorEmptyText)
      .foregroundStyle(isPrimary ? Color.theme.onAccent : Color.theme.textPrimary)
      .lineLimit(1)
      .padding(.horizontal, 14)
      .frame(height: 30)
      .background(
        RoundedRectangle(cornerRadius: 8)
          .fill(
            isPrimary
              ? Color.theme.accentPrimary : Color.theme.surfaceInk.opacity(Self.groundAlpha))
      )
      .opacity(isEnabled ? 1 : Theme.Opacity.disabled)
      .contentShape(Rectangle())
      .onTapGesture { if isEnabled { action() } }
      .padding(.top, 12)
  }
}

/// ショートカットの行: 案内（sans 12.5・textMuted）と、8 右にキーの札（高さ 18・最小幅 18・padding 0 4・radius 5・地 ink .07・
/// sans 10.5 semibold・textSecondary）。
private struct EditorShortcutRow: View {
  let label: String
  let key: String

  private static let keyAlpha = 0.07

  var body: some View {
    HStack(spacing: 8) {
      Text(label)
        .font(Font.theme.editorEmptyText)
        .foregroundStyle(Color.theme.textMuted)
      Text(key)
        .font(Font.theme.editorEmptyKey)
        .foregroundStyle(Color.theme.textSecondary)
        .padding(.horizontal, 4)
        .frame(minWidth: 18, minHeight: 18)
        .background(
          RoundedRectangle(cornerRadius: 5).fill(Color.theme.surfaceInk.opacity(Self.keyAlpha)))
    }
  }
}

/// 左の列の一言（デザインの見本の `.te`。sans 12・textMuted・中央・padding 22 14）。出すものが無い・表示できないとき、
/// パネルの題の行の下に出す。
struct EditorSidebarNote: View {
  let text: String

  var body: some View {
    Text(text)
      .font(Font.theme.editorSidebarNote)
      .foregroundStyle(Color.theme.textMuted)
      .multilineTextAlignment(.center)
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 14)
      .padding(.vertical, 22)
  }
}

#if DEBUG
  enum EditorEmptyFixtures {
    /// 文書を開いていない Files の本体を面の地（bgBase）の上で描く。gallery が dark / light を撮る。
    @MainActor static func gallery() -> some View {
      let root = FileManager.default.temporaryDirectory.path
      return EditorEmptyView(
        screen: .files, scm: ScmPanel(root: root), pullRequest: PrPanel(root: root, source: .gh())
      )
      .background(Color.theme.bgBase)
      .environment(\.localization, LocalizationStore(language: .ja))
    }
  }

  #Preview("EditorEmptyView") {
    EditorEmptyFixtures.gallery().frame(width: 640, height: 480)
  }
#endif
