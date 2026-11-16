import XCTest

@testable import Orbe

/// PR のパネルの行の組（`PrLayout.build`）——区分の見出し、コミットの欠けの行、変更ファイルのツリーとリストの並び、
/// フォルダの配下のファイル。
///
/// 壊れると何が起きるか: ツリーでフォルダとファイルが混ざって並ぶ・深いファイルがフォルダの外に出る。フォルダの
/// チェックと「確認済みの数/ファイルの数」が孫のファイルを数えず、まとめて付けても孫が残る。リストが GitHub の返した
/// 順のまま並ぶ。250 件を超える PR で、見えていないコミットがあることが分からない。
final class PrLayoutTests: OrbeTestCase {
  private let paths = [
    "src/b.swift", "README.md", "src/a/x.swift", "docs/z.md", "Z.txt", "src/a/y.swift",
  ]

  private func content(
    files: [String] = [], commitCount: Int = 0, commits: Int = 0
  ) -> GitHubPullRequestContent {
    GitHubPullRequestContent(
      nodeID: "PR_1", number: 7, title: "題", url: "https://github.com/o/r/pull/7", isDraft: false,
      state: .open, body: "", author: "me", baseRefName: "main", headRefName: "feat",
      baseCommit: "b", headCommit: "h", commitCount: commitCount,
      commits: (0..<commits).map { .init(oid: "c\($0)", headline: "コミット \($0)") },
      files: files.map { .init(path: $0, change: .modified, isViewed: false) })
  }

  /// 行を「種類 字下げ パス」の字にする（フォルダは開閉も）。
  private func rows(_ layout: PrLayout) -> [String] {
    layout.items.compactMap {
      switch $0 {
      case .folder(let path, let depth, let isOpen, _):
        "folder \(depth) \(path)\(isOpen ? "" : " 畳")"
      case .file(let path, _, let depth): "file \(depth) \(path)"
      default: nil
      }
    }
  }

  private func descendants(of folder: String, in layout: PrLayout) -> Set<String>? {
    for item in layout.items {
      if case .folder(folder, _, _, let files) = item { return Set(files) }
    }
    return nil
  }

  /// ツリーはどの段でもフォルダが先・名前順で、フォルダは配下のすべてのファイル（孫を含む）を持つ。畳んだフォルダは
  /// 子の行を出さないが、配下のファイルは持ったまま。
  func testTheTreePutsFoldersFirstAndEachFolderHoldsAllItsFiles() throws {
    let open = PrLayout.build(content(files: paths), asTree: true, closed: [], closedFolders: [])
    XCTAssertEqual(
      rows(open),
      [
        "folder 0 docs", "file 1 docs/z.md",
        "folder 0 src", "folder 1 src/a", "file 2 src/a/x.swift", "file 2 src/a/y.swift",
        "file 1 src/b.swift",
        "file 0 README.md", "file 0 Z.txt",
      ])
    XCTAssertEqual(
      descendants(of: "src", in: open), ["src/b.swift", "src/a/x.swift", "src/a/y.swift"])
    XCTAssertEqual(descendants(of: "src/a", in: open), ["src/a/x.swift", "src/a/y.swift"])

    let closed = PrLayout.build(
      content(files: paths), asTree: true, closed: [], closedFolders: ["src"])
    XCTAssertEqual(
      rows(closed),
      ["folder 0 docs", "file 1 docs/z.md", "folder 0 src 畳", "file 0 README.md", "file 0 Z.txt"])
    XCTAssertEqual(
      descendants(of: "src", in: closed), ["src/b.swift", "src/a/x.swift", "src/a/y.swift"])
  }

  /// リストはフォルダの行を持たず、すべてのファイルを字下げ無しにパス順（同じ階層ではファイルが先）で並べる。
  func testTheListIsFlatInPathOrder() {
    let layout = PrLayout.build(content(files: paths), asTree: false, closed: [], closedFolders: [])
    XCTAssertEqual(
      rows(layout),
      [
        "file 0 README.md", "file 0 Z.txt", "file 0 docs/z.md", "file 0 src/b.swift",
        "file 0 src/a/x.swift", "file 0 src/a/y.swift",
      ])
  }

  /// 総数が読めたコミットより多ければ、コミットの区分の先頭に欠けの行（数は差）を置く。同じなら置かない。
  func testHiddenCommitsAreAnnouncedFirst() {
    let truncated = PrLayout.build(
      content(commitCount: 252, commits: 250), asTree: true, closed: [], closedFolders: [])
    XCTAssertEqual(truncated.items[0], .section(.commits, isOpen: true, count: 252))
    XCTAssertEqual(truncated.items[1], .olderCommits(2))
    XCTAssertEqual(truncated.id(at: 2), .commit("c0"))

    let whole = PrLayout.build(
      content(commitCount: 3, commits: 3), asTree: true, closed: [], closedFolders: [])
    XCTAssertEqual(whole.id(at: 1), .commit("c0"))
  }

  /// 畳んだ区分は見出しだけを出し、見出しの数は畳んでも変わらない。
  func testAClosedSectionShowsOnlyItsHeader() {
    let layout = PrLayout.build(
      content(files: paths, commitCount: 252, commits: 250), asTree: true,
      closed: [.commits, .files], closedFolders: [])
    XCTAssertEqual(
      layout.items,
      [
        .section(.commits, isOpen: false, count: 252),
        .section(.files, isOpen: false, count: paths.count),
      ])
  }
}
