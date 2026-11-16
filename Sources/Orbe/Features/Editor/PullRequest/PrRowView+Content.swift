import AppKit

/// 行の中身（字組みした文字）を組む。中身の同一性（`key`）が変わったときだけ呼ぶ。
extension PrRowView {
  /// 行を描くのに要る、行の組の外の事実——確認済みの数（変更ファイルの見出しは全体、フォルダは配下、ファイルは 0 か 1）と、
  /// ツリーで見せているか。
  struct Facts: Equatable {
    let viewed: Int
    let asTree: Bool
  }

  static func key(_ item: PrLayout.Item, _ facts: Facts, _ language: Language) -> String {
    switch item {
    case .section(let section, let isOpen, let count):
      "s\(section)\(isOpen)\(count)\(facts.viewed)\(facts.asTree)\(language)"
    case .olderCommits(let hidden): "o\(hidden)\(language)"
    case .commit(let commit): "m\(commit.oid)\u{0}\(commit.headline)"
    case .folder(let path, let depth, let isOpen, let files):
      "d\(path)\u{0}\(depth)\(isOpen)\(facts.viewed)/\(files.count)"
    case .file(let path, let change, let depth):
      "f\(path)\u{0}\(depth)\(change)\(facts.viewed)\(facts.asTree)"
    }
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
    case .folder(let path, _, _, _), .file(let path, _, _): path
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
      .section(self.section(section, isOpen: isOpen, count: count, facts, language))
    case .olderCommits(let hidden):
      .note(
        TextLine(
          L10n.format(.editorPrOlderCommitsHidden, language, hidden),
          Theme.Typography.editorScmDirectory))
    case .commit(let commit):
      .commit(
        message: TextLine(
          commit.headline, Theme.Typography.editorScmCommit, glyphs: .chrome(emoji: emoji)),
        sha: TextLine(String(commit.oid.prefix(7)), Theme.Typography.editorPrCount))
    case .folder(let path, let depth, let isOpen, let files):
      .folder(folder(path, depth: depth, isOpen: isOpen, total: files.count, facts, emoji))
    case .file(let path, let change, let depth):
      .file(file(path, change: change, depth: depth, facts, emoji))
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

  private static func folder(
    _ path: String, depth: Int, isOpen: Bool, total: Int, _ facts: Facts, _ emoji: NSFont?
  ) -> Folder {
    let check: Check = facts.viewed == total ? .on : facts.viewed > 0 ? .partial : .off
    return Folder(
      check: check, depth: depth, isOpen: isOpen,
      name: TextLine(
        (path as NSString).lastPathComponent, Theme.Typography.editorScmFile,
        glyphs: .chrome(emoji: emoji)),
      count: TextLine("\(facts.viewed)/\(total)", Theme.Typography.editorPrCount),
      dimmed: check == .on)
  }

  /// ファイルの行。変化の印は、追加は A、ほかは M（ソース管理と同じ 2 色の印に寄せる）。リストならディレクトリも出す。
  private static func file(
    _ path: String, change: GitHubPullRequestContent.Change, depth: Int, _ facts: Facts,
    _ emoji: NSFont?
  ) -> File {
    let viewed = facts.viewed > 0
    let name = (path as NSString).lastPathComponent
    let chip = FileChip.resolve(URL(fileURLWithPath: name))
    let badge: GitStatus.Badge = change == .added ? .added : .modified
    return File(
      check: viewed ? .on : .off, depth: depth, chip: chip,
      chipText: TextLine(
        chip.glyph,
        Theme.Typography.editorChip(size: chip.fontSize(for: Theme.Layout.editorScmChip))),
      name: TextLine(name, Theme.Typography.editorScmFile, glyphs: .chrome(emoji: emoji)),
      directory: facts.asTree
        ? nil
        : TextLine(
          (path as NSString).deletingLastPathComponent, Theme.Typography.editorScmDirectory,
          glyphs: .chrome(emoji: emoji)),
      badge: TextLine(badge.label, Theme.Typography.editorBadge), badgeKind: badge,
      dimmed: viewed)
  }
}
