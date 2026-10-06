import Foundation

/// 結び付いた GitHub の Issue・PR の表示規則（主の印と番号・PR の段階・CI を出すか・「レビュー」・リポジトリ名を
/// 添えるか）。どの画面もここを読むだけで、自分では規則を持たない——行と右の欄で出し方がずれないため。
enum GitHubItemText {
  /// 主の結び付きの印と番号（保存した結び付きだけで決まる）。
  struct Mark: Equatable {
    let kind: GitHubItemKind
    let number: Int
  }

  /// PR の状態を 1 語で言うときの段階。
  enum PullRequestPhase: Equatable {
    case merged, closed, draft, reviewRequired, approved, changesRequested
  }

  /// 主が Issue のときの、最初に結び付いた PR の札。値が無い・実体が PR でなければ番号だけ。
  struct PullRequestBadge: Equatable {
    let number: Int
    let phase: PullRequestPhase?
    let checks: GitHubItemSummary.Checks?
  }

  /// 項目 1 つの状態（Issue は open / closed、PR は CI と段階）。
  enum State: Equatable {
    case issue(open: Bool)
    case pullRequest(checks: GitHubItemSummary.Checks?, phase: PullRequestPhase?)
  }

  /// 主の印と番号。結び付きが無ければ nil。
  static func mark(_ links: [TaskLink]) -> Mark? {
    links.first.map { Mark(kind: $0.kind, number: $0.item.number) }
  }

  /// 結び付いた項目の値。保存した種別と実体の種別が違えば無いものとして扱う（番号だけを出す）。
  static func summary(_ link: TaskLink, _ items: [GitHubItemID: GitHubItemAnswer])
    -> GitHubItemSummary?
  {
    guard case .found(let summary) = items[link.item], summary.kind == link.kind else { return nil }
    return summary
  }

  /// 番号の表示。主と同じリポジトリなら `#213`、違えば `<リポジトリ名>#213`。
  static func label(_ item: GitHubItemID, primary: GitHubItemID?) -> String {
    item.repo == primary?.repo ? "#\(item.number)" : "\(item.repoName)#\(item.number)"
  }

  /// 強いものを先に取る（マージ済み > 閉じた > 下書き > レビュー状態）。PR でなければ nil。レビュー状態が無い
  /// open の PR も nil。
  static func phase(_ summary: GitHubItemSummary) -> PullRequestPhase? {
    guard let pullRequest = summary.pullRequest else { return nil }
    switch summary.state {
    case .merged: return .merged
    case .closed: return .closed
    case .open:
      if pullRequest.isDraft { return .draft }
      switch pullRequest.review {
      case .reviewRequired: return .reviewRequired
      case .approved: return .approved
      case .changesRequested: return .changesRequested
      case nil: return nil
      }
    }
  }

  /// 出す CI。終わった（マージ済み・閉じた）PR では出さない。
  static func checks(_ summary: GitHubItemSummary) -> GitHubItemSummary.Checks? {
    summary.state == .open ? summary.pullRequest?.checks : nil
  }

  static func state(_ summary: GitHubItemSummary) -> State {
    guard summary.pullRequest != nil else { return .issue(open: summary.state == .open) }
    return .pullRequest(checks: checks(summary), phase: phase(summary))
  }

  /// 主が Issue で PR も結び付いていれば、最初の PR の札。
  static func pullRequestBadge(_ links: [TaskLink], _ items: [GitHubItemID: GitHubItemAnswer])
    -> PullRequestBadge?
  {
    guard links.first?.kind == .issue, let link = links.first(where: { $0.kind == .pr }) else {
      return nil
    }
    let summary = summary(link, items)
    return PullRequestBadge(
      number: link.item.number, phase: summary.flatMap(phase), checks: summary.flatMap(checks))
  }

  /// 主が PR で、その作成者が自分（login の大小文字は問わない）と違うか。値か自分が分からなければ false。
  static func needsReview(
    _ links: [TaskLink], _ items: [GitHubItemID: GitHubItemAnswer], viewerLogin: String?
  ) -> Bool {
    guard let primary = links.first, primary.kind == .pr, let viewerLogin,
      let pullRequest = summary(primary, items)?.pullRequest
    else { return false }
    return pullRequest.author?.lowercased() != viewerLogin.lowercased()
  }

  static func phaseText(_ phase: PullRequestPhase, _ language: Language) -> String {
    let key: L10nKey =
      switch phase {
      case .merged: .taskPalettePRMerged
      case .closed: .taskPalettePRClosed
      case .draft: .taskPalettePRDraft
      case .reviewRequired: .taskPalettePRReviewRequired
      case .approved: .taskPalettePRApproved
      case .changesRequested: .taskPalettePRChangesRequested
      }
    return L10n.string(key, language)
  }

  static func issueStateText(open: Bool, _ language: Language) -> String {
    L10n.string(open ? .taskPaletteIssueOpen : .taskPaletteIssueClosed, language)
  }
}
