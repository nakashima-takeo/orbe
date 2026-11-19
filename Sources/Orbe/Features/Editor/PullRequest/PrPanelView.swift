import AppKit
import SwiftUI

/// サイドバー: PR のパネル（見本 PrReviewPanel）。上から、パネルヘッダー（再読込・GitHub で開く）→ 答えに応じた中身。PR が
/// あれば頭（PR の印・題・番号・作者 · `head → base`・手元とのずれの帯）と失敗の文と列（説明・コミット・変更ファイル。
/// AppKit）と下端のレビューの送信の区画。PR が無ければ作成の入口（見本 PrListPanel の作成ボタンと下の 1 行）、出せなければ理由の一文だけ。根が変わると
/// 面はパネルと列を組で作り直すので、中身はパネルで同一視する。
struct PrPanelView: View {
  let panel: PrPanel
  let list: RowList<PrListSource>
  let header: PrDescriptionHeader
  @Environment(\.chromeFontResolver) private var fontResolver
  @Environment(\.localization) private var l10n

  var body: some View {
    EditorSidebarPanel {
      EditorPanelHeader(title: l10n.string(.editorPrTitle)) {
        EditorIconButton(
          glyph: EditorGlyphs.refresh, help: l10n.string(.editorPrRefresh), action: panel.refresh)
        if panel.state?.content != nil {
          EditorIconButton(
            glyph: EditorGlyphs.openFile, help: l10n.string(.editorPrOpenOnGitHub),
            action: panel.openOnGitHub)
        }
      }
      content
    }
    .id(ObjectIdentifier(panel))
    .onDisappear(perform: panel.panelDidHide)
  }

  @ViewBuilder private var content: some View {
    switch panel.pullRequest.answer {
    case .reading: EmptyView()
    case .unavailable(let reason): PrNote(text: PrPanelText.unavailable(reason, l10n))
    case .noPullRequest(let creation): PrCreation(panel: panel, creation: creation)
    case .pullRequest(let state):
      if let content = state.content {
        PrHead(content: content, drift: panel.pullRequest.drift)
        if let failure = failureText(state) {
          PrNote(text: failure, color: Color.theme.danger)
        }
        PrListHost(
          list: list, header: header, panel: panel, description: content.body,
          descriptionTitle: l10n.string(.editorPrDescription), rowsVersion: panel.rowsVersion,
          selection: panel.selection, emoji: fontResolver.emojiFont,
          wantsFocus: panel.focusRequest
        )
        .onChange(of: l10n.language, initial: true) { _, language in
          guard list.list.source.language != language else { return }
          list.list.source.language = language
          list.list.reloadRows()
        }
        if let review = state.review {
          PrReviewSection(panel: panel, state: state, review: review)
            .id(ObjectIdentifier(state))
        } else if let failure = state.reviewFailure {
          PrReviewReadFailure(failure: failure)
        }
      } else if let failure = failureText(state) {
        PrNote(text: failure, color: Color.theme.danger)
      }
    }
  }

  /// 失敗の文——PR の中身の読み直し・確認済みの書き込みの失敗か、PR を保ったまま今のブランチの PR を引き直せなかった理由。
  private func failureText(_ state: PullRequestState) -> String? {
    if let failure = state.failure { return PrPanelText.failure(failure, l10n) }
    return panel.pullRequest.lookupFailure.map { PrPanelText.unavailable($0, l10n) }
  }
}

/// 理由・失敗の一文（ソース管理パネルの git 管理外の一文と同じ字と並び）。
private struct PrNote: View {
  let text: String
  var color = Color.theme.editorTertiary

  var body: some View {
    Text(text)
      .font(Font.theme.editorScmNote)
      .foregroundStyle(color)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 18)
      .padding(.vertical, Theme.Space.step)
  }
}

/// 頭（padding 2 14 10・下に hairline）: PR の印（success。ドラフトは弱い色）・題 13 と番号（muted）、2 段目に 作者 ·
/// `head → base`（mono 10.5）、その下に手元とのずれの帯（数え終わっていなければ出さない）。
private struct PrHead: View {
  let content: GitHubPullRequestContent
  let drift: BranchPullRequest.Drift?
  @Environment(\.colorScheme) private var scheme
  @Environment(\.localization) private var l10n

  private static let hairlineAlpha = 0.07

  var body: some View {
    let ink = EditorInk(scheme)
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: Theme.Space.step) {
        EditorGlyphView(
          glyph: EditorGlyphs.pullRequest, size: 15,
          color: content.isDraft ? Color.theme.textMuted : Color.theme.success
        )
        .padding(.top, 2)
        VStack(alignment: .leading, spacing: 5) {
          (Text(content.title).foregroundStyle(Color.theme.textPrimary)
            + Text(" #\(content.number)").foregroundStyle(Color.theme.textMuted))
            .font(Font.theme.editorPrTitle)
            .lineSpacing(
              Theme.Typography.editorPrTitle.extraLeading(
                lineHeight: Theme.Typography.editorPrTitleLineHeight)
            )
            .fixedSize(horizontal: false, vertical: true)
          HStack(spacing: Theme.Space.note) {
            if let author = content.author {
              Text(author).foregroundStyle(Color.theme.textMuted).fixedSize()
              Text("·").fixedSize()
            }
            Text("\(content.headRefName) → \(content.baseRefName)")
              .lineLimit(1)
              .truncationMode(.tail)
          }
          .font(Font.theme.editorPrMeta)
          .foregroundStyle(Color.theme.editorTertiary)
        }
        Spacer(minLength: 0)
      }
      if let drift { PrBand(drift: drift).padding(.top, 10) }
    }
    .padding(.top, 2)
    .padding(.horizontal, 14)
    .padding(.bottom, 10)
    .overlay(alignment: .bottom) {
      Rectangle().fill(ink.hairline(Self.hairlineAlpha)).frame(height: Theme.Stroke.hairline)
    }
  }
}

/// 手元とのずれの帯（1 行なら 24・padding 0 8・radius 3・地は色の .10）: 一致は success とレ点、未 push・未取得・数えない
/// 違いは注意の色。先行と遅れの両方があれば、2 つの文を「・」でつなぐ。文は省かず、幅に収まらなければ折り返して全文を
/// 出し、帯は行数に従って伸びる（レ点は 1 行目に揃える）。
private struct PrBand: View {
  let drift: BranchPullRequest.Drift
  @Environment(\.localization) private var l10n

  private static let groundAlpha = 0.10
  /// 帯の字の 1 行の高さと、1 行のとき帯が 24 になる上下の余白。
  private static let lineHeight = NSLayoutManager().defaultLineHeight(
    for: Theme.Typography.editorPrBand)
  private static let verticalPadding = max(0, (Theme.Layout.editorPrBand - lineHeight) / 2)

  var body: some View {
    let inSync = drift == .inSync
    let color = inSync ? Color.theme.success : Color.theme.editorCaution
    HStack(alignment: .top, spacing: Theme.Space.note) {
      if inSync {
        EditorGlyphView(glyph: EditorGlyphs.bandCheck, size: 12, color: color)
          .frame(height: Self.lineHeight)
      }
      Text(PrPanelText.drift(drift, l10n))
        .font(Font.theme.editorPrBand)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .foregroundStyle(color)
    .padding(.horizontal, Theme.Space.step)
    .padding(.vertical, Self.verticalPadding)
    .frame(minHeight: Theme.Layout.editorPrBand)
    .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(Self.groundAlpha)))
  }
}

/// PR が無いときの作成の入口（見本 PrListPanel。padding 2 12 8）: 「プルリクエストを作成」のボタン（見本 primaryButton）と、
/// その下の 1 行 `<ブランチ> → <既定のブランチ> · ↑N`（先行が 0 か分からなければ `· ↑N` を出さない）。ブランチが GitHub に
/// 無いと確かめられた間は、ボタンを押せない姿にし、下に案内の文を出す。
private struct PrCreation: View {
  let panel: PrPanel
  let creation: BranchPullRequest.Creation
  @Environment(\.localization) private var l10n

  var body: some View {
    let enabled = creation.published != .no
    VStack(spacing: 6) {
      HStack(spacing: Theme.Space.note) {
        EditorGlyphView(
          glyph: EditorGlyphs.createPullRequest, size: 13, color: Color.theme.tabActiveText)
        Text(l10n.string(.editorPrCreate))
          .font(Font.theme.editorScmButton)
          .foregroundStyle(Color.theme.tabActiveText)
      }
      .frame(maxWidth: .infinity)
      .frame(height: Theme.Layout.editorScmCommitButton)
      .background(RoundedRectangle(cornerRadius: 3).fill(Color.theme.accentPrimary))
      .opacity(enabled ? 1 : Theme.Opacity.disabled)
      .contentShape(Rectangle())
      .onTapGesture { if enabled { panel.createPullRequest() } }
      Text(meta)
        .font(Font.theme.editorPrCreateMeta)
        .foregroundStyle(Color.theme.editorTertiary)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: .infinity)
      if !enabled {
        Text(l10n.string(.editorPrPublishFirst))
          .font(Font.theme.editorScmNote)
          .foregroundStyle(Color.theme.editorTertiary)
          .frame(maxWidth: .infinity)
      }
    }
    .padding(.top, 2)
    .padding(.horizontal, 12)
    .padding(.bottom, Theme.Space.step)
  }

  private var meta: String {
    let range = "\(creation.branch) → \(creation.defaultBranch)"
    guard let ahead = creation.ahead, ahead > 0 else { return range }
    return range + " · ↑\(ahead)"
  }
}

/// PR のパネルの列を SwiftUI に載せ、列の頭（説明）を今の中身に合わせる。
private struct PrListHost: NSViewRepresentable {
  let list: RowList<PrListSource>
  let header: PrDescriptionHeader
  let panel: PrPanel
  let description: String
  let descriptionTitle: String
  let rowsVersion: Int
  let selection: PrRowID?
  let emoji: NSFont?
  let wantsFocus: Bool

  func makeNSView(context: Context) -> RowList<PrListSource> {
    list.setHeader(header)
    return list
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: RowList<PrListSource>, context: Context)
    -> CGSize?
  {
    proposal.replacingUnspecifiedDimensions()
  }

  func updateNSView(_ list: RowList<PrListSource>, context: Context) {
    header.onToggle = { [panel] in panel.isDescriptionOpen.toggle() }
    if header.show(description, isOpen: panel.isDescriptionOpen, title: descriptionTitle) {
      list.headerDidChange()
    }
    list.update(
      rowsVersion: rowsVersion, selection: selection, emoji: emoji, wantsFocus: wantsFocus)
  }
}

/// PR のパネルの文言（理由・失敗・帯）。
enum PrPanelText {
  static func unavailable(_ reason: BranchPullRequest.Unavailable, _ l10n: LocalizationStore)
    -> String
  {
    switch reason {
    case .notGit: l10n.string(.editorScmNotManaged)
    case .detached: l10n.string(.editorPrNotDetached)
    case .defaultBranch: l10n.string(.editorPrNotDefaultBranch)
    case .ghMissing: l10n.string(.editorPrGhMissing)
    case .ghUnauthed: l10n.string(.editorPrGhUnauthed)
    case .notGitHub: l10n.string(.editorPrNotGitHub)
    case .unverified: l10n.string(.editorPrUnverified)
    case .failed(let failure): text(failure, empty: .editorPrFailedRead, l10n.language)
    }
  }

  static func failure(_ failure: PullRequestState.Failure, _ l10n: LocalizationStore) -> String {
    switch failure {
    case .read(let reason): text(reason, empty: .editorPrFailedRead, l10n.language)
    case .write(let reason): text(reason, empty: .editorPrFailedWrite, l10n.language)
    }
  }

  static func drift(_ drift: BranchPullRequest.Drift, _ l10n: LocalizationStore) -> String {
    switch drift {
    case .inSync: return l10n.string(.editorPrInSync)
    case .differs: return l10n.string(.editorPrHeadDiffers)
    case .diverged(let ahead, let behind):
      var parts: [String] = []
      if ahead > 0 { parts.append(l10n.format(.editorPrUnpushed, ahead)) }
      if behind > 0 { parts.append(l10n.format(.editorPrUnfetched, behind)) }
      return parts.joined(separator: "・")
    }
  }

  /// レビューのやりとりの読みの失敗の文。
  static func reviewReadFailure(_ failure: GitHubFailure, _ l10n: LocalizationStore) -> String {
    l10n.format(.editorPrReviewReadFailed, text(failure, empty: .editorPrFailedRead, l10n.language))
  }

  /// レビューへの書き込み（コメント・返信・解決・レビューの送信）の失敗の文。時間切れは、GitHub に届いていたかもしれないことを
  /// 告げる。
  static func writeFailure(_ failure: GitHubFailure, _ language: Language) -> String {
    if failure == .timedOut { return L10n.string(.editorPrWriteTimedOut, language) }
    return text(failure, empty: .editorPrFailedWrite, language)
  }

  /// gh の失敗の文。決まった文の種類はその文、それ以外は gh のエラー文の要点（空なら `empty`）。
  private static func text(_ failure: GitHubFailure, empty: L10nKey, _ language: Language)
    -> String
  {
    switch failure {
    case .unauthenticated: L10n.string(.editorPrFailedUnauthenticated, language)
    case .rateLimited: L10n.string(.editorPrFailedRateLimited, language)
    case .unreachable: L10n.string(.editorPrFailedUnreachable, language)
    case .timedOut: L10n.string(.editorPrFailedTimedOut, language)
    case .reason(let reason): reason.isEmpty ? L10n.string(empty, language) : reason
    }
  }
}
