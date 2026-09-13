import XCTest

@testable import Orbe

/// porcelain v2 の解析とバッジの導出。壊れるとツリーの M / U / A の印が違うファイルに付く。
final class GitStatusTests: OrbeTestCase {
  private func parse(_ tokens: [String]) -> GitStatus {
    GitStatus.parse(Data((tokens.joined(separator: "\u{0}") + "\u{0}").utf8))
  }

  private let zero = String(repeating: "0", count: 40)

  /// `1 XY sub mH mI mW hH hI path`
  private func ordinary(_ xy: String, _ path: String) -> String {
    "1 \(xy) N... 100644 100644 100644 \(zero) \(zero) \(path)"
  }

  /// `2 XY sub mH mI mW hH hI Xscore path`（元パスは次のトークン）
  private func renamed(_ xy: String, _ path: String) -> String {
    "2 \(xy) N... 100644 100644 100644 \(zero) \(zero) R100 \(path)"
  }

  /// `u XY sub m1 m2 m3 mW h1 h2 h3 path`
  private func unmerged(_ path: String) -> String {
    "u UU N... 100644 100644 100644 100644 \(zero) \(zero) \(zero) \(path)"
  }

  func testParsesOrdinaryRenamedUnmergedAndUntrackedAndIgnoresTheRest() {
    let status = parse([
      "# branch.oid abc", "# branch.head main",
      ordinary(".M", "src/mod.swift"), ordinary("A.", "src/new.swift"), ordinary(".D", "gone.txt"),
      renamed("R.", "new name.txt"), "old name.txt", unmerged("conflict.txt"),
      "? notes.txt", "? scratch/", "! build/", "1 XY", "",
    ])
    XCTAssertEqual(
      status.entries["src/mod.swift"], GitStatus.Entry(staged: nil, unstaged: .modified))
    XCTAssertEqual(status.entries["src/new.swift"], GitStatus.Entry(staged: .added, unstaged: nil))
    XCTAssertEqual(status.entries["gone.txt"], GitStatus.Entry(staged: nil, unstaged: .deleted))
    XCTAssertEqual(
      status.entries["new name.txt"], GitStatus.Entry(staged: .renamed, unstaged: nil),
      "rename は新しいパスで引ける（空白入りでも）")
    XCTAssertNil(status.entries["old name.txt"], "元パスのトークンはエントリにしない")
    XCTAssertEqual(
      status.entries["conflict.txt"], GitStatus.Entry(staged: .unmerged, unstaged: .unmerged))
    XCTAssertEqual(status.entries["notes.txt"], GitStatus.Entry(staged: nil, unstaged: .untracked))
    XCTAssertEqual(status.untrackedDirectories, ["scratch"])
    XCTAssertNil(status.entries["scratch/"])
    XCTAssertNil(status.entries["build/"], "ignored は捨てる")
    XCTAssertEqual(status.entries.count, 6, "ヘッダ・不正なトークン・空は捨てる")
  }

  func testBadgeDerivation() {
    let status = parse([
      ordinary(".M", "m.txt"), ordinary("M.", "staged.txt"), ordinary("A.", "a.txt"),
      ordinary("AM", "am.txt"), ordinary(".T", "t.txt"), ordinary(".D", "d.txt"),
      renamed("R.", "r.txt"), "old.txt", unmerged("c.txt"), "? u.txt", "? dir/",
    ])
    XCTAssertEqual(status.badge(of: "m.txt"), .modified)
    XCTAssertEqual(status.badge(of: "staged.txt"), .modified)
    XCTAssertEqual(status.badge(of: "a.txt"), .added)
    XCTAssertEqual(status.badge(of: "am.txt"), .modified, "index に追加した後の編集は unstaged 側が勝つ")
    XCTAssertEqual(status.badge(of: "t.txt"), .modified)
    XCTAssertEqual(status.badge(of: "d.txt"), .modified, "削除も M")
    XCTAssertEqual(status.badge(of: "r.txt"), .modified, "rename も M")
    XCTAssertEqual(status.badge(of: "c.txt"), .conflicted)
    XCTAssertEqual(status.badge(of: "u.txt"), .untracked)
    XCTAssertEqual(status.badge(of: "dir"), .untracked, "未追跡ディレクトリ自身")
    XCTAssertEqual(status.badge(of: "dir/inner/x.txt"), .untracked, "未追跡ディレクトリの中")
    XCTAssertNil(status.badge(of: "directory.txt"), "前方一致は構成要素単位")
    XCTAssertNil(status.badge(of: "clean.txt"))
  }
}
