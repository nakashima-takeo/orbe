import AppKit

/// 行の中身（字組みした文字）を組む。中身の同一性（`key`）が変わったときだけ呼ぶ。
extension PrRowView {
  /// 行を描くのに要る、行の組の外の事実——確認済みの数（変更ファイルの見出しは全体、フォルダは配下、ファイルは 0 か 1）と、
  /// ツリーで見せているか、ファイルのコメントの数。
  struct Facts: Equatable {
    let viewed: Int
    let asTree: Bool
    var comments = 0
  }

  /// 行の中身の同一性——行の組の行・行の組の外の事実・言語・絵文字の字体を、値のまま比べる。
  struct Key: Equatable {
    let item: PrLayout.Item
    let facts: Facts
    let language: Language
    let emoji: String?
  }

  /// VoiceOver に渡す中身の文字列。
  static func label(_ item: PrLayout.Item, _ facts: Facts, _ language: Language) -> String {
    switch item {
    case .section(.commits, _, let count):
      "\(L10n.string(.editorPrCommits, language)), \(count.formatted())"
    case .section(.files, _, let count):
      "\(L10n.string(.editorPrFiles, language)), \(viewedText(facts, count, language))"
    case .olderCommits(let hidden): L10n.format(.editorPrOlderCommitsHidden, language, hidden)
    case .commit(let commit): commit.headline
    case .folder(let path, _, _, _): path
    case .file(let path, _, _) where facts.comments > 0:
      "\(path), \(L10n.format(.editorPrCommentCount, language, facts.comments))"
    case .file(let path, _, _): path
    }
  }

  /// 行の中の部品の説明の文。
  static func helps(_ language: Language) -> [PrControl: String] {
    [
      .tree: L10n.string(.editorPrTreeView, language),
      .list: L10n.string(.editorPrListView, language),
    ]
  }

  static func content(
    _ item: PrLayout.Item, _ facts: Facts, _ language: Language, _ emoji: NSFont?
  ) -> Content {
    switch item {
    case .section(let section, let isOpen, let count):
      return .section(self.section(section, isOpen: isOpen, count: count, facts, language))
    case .olderCommits(let hidden):
      return .note(
        TextLine(
          L10n.format(.editorPrOlderCommitsHidden, language, hidden),
          Theme.Typography.editorScmDirectory))
    case .commit(let commit):
      return .commit(
        message: TextLine(
          commit.headline, Theme.Typography.editorScmCommit, glyphs: .chrome(emoji: emoji)),
        sha: TextLine(String(commit.oid.prefix(7)), Theme.Typography.editorPrCount))
    case .folder(let path, let depth, let isOpen, let files):
      // 配下の確認済みが全部なら付いた姿、一部なら横線、無ければ空。
      let check: Check = facts.viewed == files.count ? .on : facts.viewed > 0 ? .partial : .off
      return .folder(
        Folder(
          check: check, depth: depth, isOpen: isOpen, name: name(path, emoji),
          count: TextLine("\(facts.viewed)/\(files.count)", Theme.Typography.editorPrCount),
          dimmed: check == .on))
    case .file(let path, let change, let depth):
      return .file(file(path, change: change, depth: depth, facts, emoji))
    }
  }

  /// 区分の見出し: コミットは総数のバッジ、変更ファイルは「N/M 確認済み」とツリー / リストの印。
  private static func section(
    _ section: PrSection, isOpen: Bool, count: Int, _ facts: Facts, _ language: Language
  ) -> Section {
    switch section {
    case .commits:
      Section(
        isOpen: isOpen,
        label: TextLine(L10n.string(.editorPrCommits, language), Theme.Typography.editorScmSection),
        count: TextLine(count.formatted(), Theme.Typography.editorScmCount), viewed: nil,
        asTree: nil)
    case .files:
      Section(
        isOpen: isOpen,
        label: TextLine(L10n.string(.editorPrFiles, language), Theme.Typography.editorScmSection),
        count: nil,
        viewed: TextLine(viewedText(facts, count, language), Theme.Typography.editorPrCount),
        asTree: facts.asTree)
    }
  }

  private static func viewedText(_ facts: Facts, _ count: Int, _ language: Language) -> String {
    L10n.format(.editorPrViewedCount, language, facts.viewed, count)
  }

  /// フォルダ・ファイルの名前（パスの最後の要素）。
  private static func name(_ path: String, _ emoji: NSFont?) -> TextLine {
    TextLine(
      (path as NSString).lastPathComponent, Theme.Typography.editorScmFile,
      glyphs: .chrome(emoji: emoji))
  }

  /// ファイルの行（変化の印は `GitStatus.Badge.init(_:)` の PR の規則）。リストならディレクトリも出す。
  private static func file(
    _ path: String, change: GitHubPullRequestContent.Change, depth: Int, _ facts: Facts,
    _ emoji: NSFont?
  ) -> File {
    let viewed = facts.viewed > 0
    let chip = FileChip.resolve(URL(fileURLWithPath: (path as NSString).lastPathComponent))
    let badge = GitStatus.Badge(change)
    return File(
      check: viewed ? .on : .off, depth: depth, chip: chip,
      chipText: TextLine(
        chip.glyph,
        Theme.Typography.editorChip(size: chip.fontSize(for: Theme.Layout.editorScmChip))),
      name: name(path, emoji),
      directory: facts.asTree
        ? nil
        : TextLine(
          (path as NSString).deletingLastPathComponent, Theme.Typography.editorScmDirectory,
          glyphs: .chrome(emoji: emoji)),
      badge: TextLine(badge.label, Theme.Typography.editorBadge), badgeKind: badge,
      comments: facts.comments > 0
        ? TextLine(facts.comments.formatted(), Theme.Typography.editorPrCount) : nil,
      dimmed: viewed)
  }
}
