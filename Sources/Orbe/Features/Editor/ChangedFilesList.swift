import Foundation
import OrbeEditorCore

/// Changes の変更ファイルの一覧の行の組——ソース管理パネルの状態の 2 区分（どちらもパス順）の写し。区分ごとに見出しの行
/// （「ステージされている変更 N」「変更 N」）を置き、0 件の区分は見出しごと出さない。行の番号から、見出しの行か、どの区分の
/// 何番目のファイルかを計算で答える。同一性は、その行の diff の識別（`EditorDiff.Key`）。
struct ScmChangedFilesRows: EditorItemListRows {
  let root: String
  let changes: ScmChanges
  private let titles: [ScmSection: String]
  /// 出す区分と、その見出しの行の番号。
  private let sections: [(section: ScmSection, heading: Int)]
  let count: Int

  init(root: String, changes: ScmChanges, titles: [ScmSection: String]) {
    self.root = root
    self.changes = changes
    self.titles = titles
    var sections: [(section: ScmSection, heading: Int)] = []
    var next = 0
    for section in [ScmSection.staged, .changes] {
      let files = changes.files(in: section).count
      guard files > 0 else { continue }
      sections.append((section, next))
      next += files + 1
    }
    self.sections = sections
    count = next
  }

  func row(at index: Int) -> EditorItemListRow {
    let (section, offset) = locate(index)
    let files = changes.files(in: section)
    guard let offset else {
      return .heading(title: titles[section] ?? "", count: files.count, key: nil)
    }
    let file = files[offset]
    return .file(.changed(file.path, root: root, badge: file.badge))
  }

  func id(at index: Int) -> AnyHashable? {
    let (section, offset) = locate(index)
    guard let offset else { return nil }
    return EditorDiff.Key(
      root: root, path: changes.files(in: section)[offset].path,
      kind: section == .staged ? .staged : .workingTree)
  }

  func index(of id: AnyHashable) -> Int? {
    guard let key = id.base as? EditorDiff.Key, key.root == root else { return nil }
    let section: ScmSection
    switch key.kind {
    case .staged: section = .staged
    case .workingTree: section = .changes
    case .pullRequest: return nil
    }
    guard let heading = sections.first(where: { $0.section == section })?.heading else {
      return nil
    }
    return changes.index(in: section, path: key.path).map { heading + 1 + $0 }
  }

  /// 行 `index` の区分と、区分の中の番号（見出しの行なら nil）。
  private func locate(_ index: Int) -> (ScmSection, Int?) {
    let part = sections.last { $0.heading <= index } ?? sections[0]
    let offset = index - part.heading - 1
    return (part.section, offset < 0 ? nil : offset)
  }
}

/// PR の変更ファイルの一覧の行の組——見出しの行（「変更ファイル N」）と、変更ファイルをリスト表示と同じ順に並べた列。行 0 が
/// 見出し、行 i + 1 がファイル i。確認済みは作った時点の写しで、確認済みのファイルは名前を弱い色にする。同一性は、その行の
/// PR の diff の識別（`EditorDiff.Key`）。
struct PrChangedFilesRows: EditorItemListRows {
  let root: String
  let state: PullRequestState
  /// 変更ファイル（リスト表示と同じパス順）。
  let files: [GitHubPullRequestContent.File]
  let viewed: PullRequestState.ViewedSnapshot
  let title: String

  var count: Int { files.count + 1 }

  func row(at index: Int) -> EditorItemListRow {
    guard index > 0 else { return .heading(title: title, count: files.count, key: nil) }
    let file = files[index - 1]
    return .file(
      .changed(
        file.path, root: root, badge: GitStatus.Badge(file.change),
        isDimmed: viewed.contains(file.path)))
  }

  func id(at index: Int) -> AnyHashable? {
    guard index > 0 else { return nil }
    return EditorDiff.Key(root: root, path: files[index - 1].path, kind: .pullRequest(state))
  }

  func index(of id: AnyHashable) -> Int? {
    guard let key = id.base as? EditorDiff.Key, key.root == root,
      key.kind == .pullRequest(state)
    else { return nil }
    return FileNameOrder.index(of: key.path, in: files, path: \.path).map { $0 + 1 }
  }
}

extension EditorItemListRow.File {
  /// 変更ファイル（根 `root` からの相対パス `path`）の行。ディレクトリは根からの相対（根の直下なら空）。右の印（× と丸）は
  /// 出さない。
  static func changed(
    _ path: String, root: String, badge: GitStatus.Badge, isDimmed: Bool = false
  ) -> Self {
    let slash = path.lastIndex(of: "/")
    return Self(
      chip: FileChip.resolve(URL(fileURLWithPath: root).appendingPathComponent(path)),
      name: slash.map { String(path[path.index(after: $0)...]) } ?? path, isDimmed: isDimmed,
      directory: slash.map { String(path[..<$0]) } ?? "", badge: badge)
  }
}

/// 変更ファイルの一覧を一覧の器に載せる側。中身は、本体の diff の種類で決まる——Changes はソース管理パネルの状態の 2 区分、
/// PR は diff が持つ PR ごとの状態の変更ファイル。行を決めたら（↵・クリック）、その diff を開いて本文へフォーカスを移す（左の列の一覧でも、
/// その行が選ばれる）。詳細は持たない。
@MainActor
final class ChangedFilesList: EditorItemListOwner {
  private unowned let pane: EditorPaneView
  /// PR の変更ファイルを並べた列と、並べた元の中身（中身が読み直されるまで並べ直さない）。
  private var ordered: (content: GitHubPullRequestContent, files: [GitHubPullRequestContent.File])?

  init(pane: EditorPaneView) {
    self.pane = pane
  }

  /// 開いたときに選ぶ行は、本体の diff の行（一覧に無ければ選ばない）。
  func itemListContent() -> EditorItemListContent {
    let language = pane.localization.language
    let shown = pane.diff?.id
    let rows: any EditorItemListRows
    if let shown, case .pullRequest(let state) = shown.kind {
      rows = PrChangedFilesRows(
        root: shown.root, state: state, files: order(state.content), viewed: state.viewedSnapshot,
        title: L10n.string(.editorPrFiles, language))
    } else {
      rows = ScmChangedFilesRows(
        root: pane.scm.root, changes: pane.scm.changes,
        titles: [
          .staged: L10n.string(.editorScmStaged, language),
          .changes: L10n.string(.editorScmChanges, language),
        ])
    }
    let selected = shown.flatMap { rows.index(of: $0) == nil ? nil : AnyHashable($0) }
    return EditorItemListContent(
      rows: rows, initialSelection: selected,
      hints: [
        EditorItemListHint(
          key: .glyph(EditorGlyphs.returnKey), label: L10n.string(.editorItemListOpen, language)),
        EditorItemListHint(
          key: .text("esc"), label: L10n.string(.editorItemListClose, language)),
      ])
  }

  func itemListDetail(of id: AnyHashable) -> EditorItemListContent? { nil }

  func itemListCommit(_ id: AnyHashable) -> EditorItemListOutcome {
    if let key = id.base as? EditorDiff.Key { pane.openScmDiff(key, .commit) }
    return .close
  }

  func itemListPress(_ id: AnyHashable) -> EditorItemListOutcome { .stay }

  /// PR の中身 `content` の変更ファイルを、リスト表示と同じ順に並べた列。
  private func order(_ content: GitHubPullRequestContent?) -> [GitHubPullRequestContent.File] {
    guard let content else { return [] }
    if let ordered, ordered.content == content { return ordered.files }
    let files = PrLayout.listOrder(content.files)
    ordered = (content, files)
    return files
  }
}
