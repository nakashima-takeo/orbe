import AppKit

/// PR のパネルの列の源——`PrPanel` の行の組を行の列（`RowList`）へ渡し、列の操作をパネルの操作へ届ける。行の確認済みは、
/// 描くたびに PR ごとの状態から読む。
///
/// キーと焦点はソース管理の変更の列と同じ型: ↑↓ は区分の見出し・フォルダ・ファイル行を渡ってファイル行なら仮のタブで
/// PR の diff を開き（押している間は開かず、離したら開く）、← → は見出しとフォルダの開閉と親・子への移動、Enter はファイル
/// 行を普通のタブで開いて本文へ（見出し・フォルダは開閉）、Esc は選択を外す。ファイル行のシングルクリックは選んで仮の
/// タブで開き、ダブルクリックは普通のタブで開いて本文へ。見出し・フォルダのクリックは開閉。コミットの行は押せない。
final class PrListSource: RowListSource {
  let panel: PrPanel
  /// 行の文言の言語（列を載せる view が環境から写す）。
  var language = Language.systemDefault

  init(panel: PrPanel) {
    self.panel = panel
  }

  var rows: PrLayout { panel.layout }

  func rowCount(in layout: PrLayout) -> Int { layout.items.count }

  func makeRowView() -> PrRowView { PrRowView(frame: .zero) }

  func show(_ row: Int, of layout: PrLayout, in view: PrRowView, emoji: NSFont?) {
    let row = describe(layout.items[row], emoji: emoji)
    view.show(
      row.content, key: row.key + (emoji.map { "\u{0}\($0.fontName)" } ?? ""), label: row.label,
      helps: [
        .tree: L10n.string(.editorPrTreeView, language),
        .list: L10n.string(.editorPrListView, language),
      ])
  }

  func row(of selection: PrRowID, in layout: PrLayout) -> Int? { layout.index[selection] }

  func prepareRows(for appearance: NSAppearance) {
    PrRowView.prepare(for: appearance)
  }

  var wantsFocus: Bool { panel.focusRequest }

  func focusRequestDidApply() { panel.focusRequestDidApply() }

  func focusDidChange(_ focused: Bool) { panel.focusDidChange(focused) }

  func perform(_ key: RowListKey, in layout: PrLayout) {
    switch key.action {
    case .up: panel.moveSelection(by: -1, isRepeat: key.isRepeat, in: layout)
    case .down: panel.moveSelection(by: 1, isRepeat: key.isRepeat, in: layout)
    case .left: panel.moveLeft(in: layout)
    case .right: panel.moveRight(isRepeat: key.isRepeat, in: layout)
    case .enter: panel.activateSelection()
    case .escape: panel.select(nil)
    }
  }

  func keyDidRelease() { panel.navigation.keyDidRelease() }

  func click(_ row: Int, in layout: PrLayout) { panel.click(row, in: layout) }

  func doubleClick(_ row: Int, in layout: PrLayout) { panel.doubleClick(row, in: layout) }

  func press(_ row: Int, control: Int, in layout: PrLayout) -> RowListAnchor<PrRowID>? {
    guard let control = PrControl(rawValue: control) else { return nil }
    panel.press(row, control, in: layout)
    return nil
  }

  func select(_ row: Int, in layout: PrLayout) {
    panel.select(layout.id(at: row))
  }

  // MARK: - 行の中身

  /// 行の中身と、その同一性（同じなら組み直さない）と、VoiceOver に渡す文字列。
  private struct Described {
    let content: PrRowView.Content
    let key: String
    let label: String
  }

  private func describe(_ item: PrLayout.Item, emoji: NSFont?) -> Described {
    switch item {
    case .section(.commits, let isOpen, let count): commitsSection(isOpen: isOpen, count: count)
    case .section(.files, let isOpen, let count): filesSection(isOpen: isOpen, count: count)
    case .olderCommits(let hidden):
      olderCommits(hidden)
    case .commit(let commit):
      self.commit(commit, emoji: emoji)
    case .folder(let path, let depth, let isOpen, let files):
      folder(path: path, depth: depth, isOpen: isOpen, files: files, emoji: emoji)
    case .file(let path, let change, let depth):
      file(path: path, change: change, depth: depth, emoji: emoji)
    }
  }

  private func commitsSection(isOpen: Bool, count: Int) -> Described {
    let title = L10n.string(.editorPrCommits, language)
    let text = count.formatted()
    return Described(
      content: .section(
        PrRowView.Section(
          isOpen: isOpen, label: TextLine(title, Theme.Typography.editorScmSection),
          count: TextLine(text, Theme.Typography.editorScmCount), viewed: nil, asTree: nil)),
      key: "c\(isOpen)\(text)\(language)", label: "\(title), \(text)")
  }

  private func filesSection(isOpen: Bool, count: Int) -> Described {
    let title = L10n.string(.editorPrFiles, language)
    let viewed = L10n.format(
      .editorPrViewedCount, language, panel.state?.viewedCount.viewed ?? 0, count)
    let asTree = panel.asTree
    return Described(
      content: .section(
        PrRowView.Section(
          isOpen: isOpen, label: TextLine(title, Theme.Typography.editorScmSection), count: nil,
          viewed: TextLine(viewed, Theme.Typography.editorPrCount), asTree: asTree)),
      key: "s\(isOpen)\(viewed)\(asTree)\(language)", label: "\(title), \(viewed)")
  }

  private func olderCommits(_ hidden: Int) -> Described {
    let text = L10n.format(.editorPrOlderCommitsHidden, language, hidden)
    return Described(
      content: .note(TextLine(text, Theme.Typography.editorScmDirectory)), key: "o\(text)",
      label: text)
  }

  private func commit(_ commit: GitHubPullRequestContent.Commit, emoji: NSFont?) -> Described {
    Described(
      content: .commit(
        message: TextLine(
          commit.headline, Theme.Typography.editorScmCommit, glyphs: .chrome(emoji: emoji)),
        sha: TextLine(String(commit.oid.prefix(7)), Theme.Typography.editorPrCount)),
      key: "m\(commit.oid)\u{0}\(commit.headline)", label: commit.headline)
  }

  private func folder(
    path: String, depth: Int, isOpen: Bool, files: [String], emoji: NSFont?
  ) -> Described {
    let name = (path as NSString).lastPathComponent
    let viewed = panel.viewedCount(of: files)
    let check: PrRowView.Check = viewed == files.count ? .on : viewed > 0 ? .partial : .off
    let count = "\(viewed)/\(files.count)"
    return Described(
      content: .folder(
        PrRowView.Folder(
          check: check, depth: depth, isOpen: isOpen,
          name: TextLine(name, Theme.Typography.editorScmFile, glyphs: .chrome(emoji: emoji)),
          count: TextLine(count, Theme.Typography.editorPrCount), dimmed: check == .on)),
      key: "d\(path)\u{0}\(depth)\(isOpen)\(count)", label: path)
  }

  /// ファイルの行。変化の印は、追加は A、ほかは M（ソース管理と同じ 2 色の印に寄せる）。
  private func file(
    path: String, change: GitHubPullRequestContent.Change, depth: Int, emoji: NSFont?
  ) -> Described {
    let viewed = panel.state?.isViewed(path) ?? false
    let name = (path as NSString).lastPathComponent
    let chip = FileChip.resolve(URL(fileURLWithPath: name))
    let badge: GitStatus.Badge = change == .added ? .added : .modified
    let asTree = panel.asTree
    let directory = (path as NSString).deletingLastPathComponent
    return Described(
      content: .file(
        PrRowView.File(
          check: viewed ? .on : .off, depth: depth, chip: chip,
          chipText: TextLine(
            chip.glyph,
            Theme.Typography.editorChip(size: chip.fontSize(for: Theme.Layout.editorScmChip))),
          name: TextLine(name, Theme.Typography.editorScmFile, glyphs: .chrome(emoji: emoji)),
          directory: asTree
            ? nil
            : TextLine(
              directory, Theme.Typography.editorScmDirectory, glyphs: .chrome(emoji: emoji)),
          badge: TextLine(badge.label, Theme.Typography.editorBadge), badgeKind: badge,
          dimmed: viewed)),
      key: "f\(path)\u{0}\(depth)\(change)\(viewed)\(asTree)", label: path)
  }
}
