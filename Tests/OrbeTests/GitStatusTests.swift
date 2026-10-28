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
      status.entries["new name.txt"],
      GitStatus.Entry(staged: .renamed, unstaged: nil, originalPath: "old name.txt"),
      "rename は新しいパスで引け（空白入りでも）、元パスを持つ")
    XCTAssertNil(status.entries["old name.txt"], "元パスのトークンはエントリにしない")
    XCTAssertEqual(status.row("new name.txt").paths, ["new name.txt", "old name.txt"])
    XCTAssertEqual(status.row("src/mod.swift").paths, ["src/mod.swift"])
    XCTAssertEqual(
      status.entries["conflict.txt"], GitStatus.Entry(staged: .unmerged, unstaged: .unmerged))
    XCTAssertEqual(status.entries["notes.txt"], GitStatus.Entry(staged: nil, unstaged: .untracked))
    XCTAssertEqual(status.untrackedDirectories, ["scratch"])
    XCTAssertNil(status.entries["scratch/"])
    XCTAssertNil(status.entries["build/"], "ignored は捨てる")
    XCTAssertEqual(status.entries.count, 6, "ヘッダ・不正なトークン・空は捨てる")
  }

  /// 新パスか元パスが UTF-8 でない rename の行は捨てる。元パスのトークンは読み飛ばし、次の行として読まない——元パスが
  /// `? ../sib` の形でも、根の外を指す未追跡の行にならない。
  func testARenameWithANonUTF8PathIsDroppedWithoutReadingItsOriginalAsALine() {
    var data = Data()
    for token in [
      Data(renamed("R.", "").utf8) + Data([0xFF]), Data("? ../sib".utf8),
      Data(renamed("R.", "fine.txt").utf8), Data([0xFE]) + Data("old".utf8),
      Data(ordinary(".M", "after.txt").utf8),
    ] {
      data += token + Data([0])
    }
    let status = GitStatus.parse(data)
    XCTAssertNil(status.entries["../sib"])
    XCTAssertNil(status.entries["fine.txt"], "元パスが読めない rename も捨てる")
    XCTAssertEqual(Array(status.entries.keys), ["after.txt"], "後の行はそのまま読む")
  }

  /// index 側に変化のあるパスは index の版を持ち（ステージした削除・rename の元パスは index に無い）、作業ツリー側だけの
  /// 変化・未追跡は持たない。XY が同じまま index の中身だけ変わっても、status は別の値になる（行が古い版のまま残らない）。
  func testStagedPathsCarryTheirIndexVersion() {
    let blob = String(repeating: "b", count: 40)
    func line(_ xy: String, _ mode: String, _ object: String, _ path: String) -> String {
      "1 \(xy) N... 100644 \(mode) 100644 \(zero) \(object) \(path)"
    }
    let status = parse([
      line("MM", "100644", blob, "a.txt"), line("D.", "000000", zero, "gone.txt"),
      line(".M", "100644", blob, "edited.txt"), renamed("R.", "new.txt"), "old.txt",
      "? n.txt",
    ])
    XCTAssertEqual(
      status.stagedVersions,
      [
        "a.txt": .entry(mode: "100644", object: blob), "gone.txt": .absent,
        "new.txt": .entry(mode: "100644", object: zero), "old.txt": .absent,
      ])
    let restaged = parse([
      line("MM", "100644", String(repeating: "c", count: 40), "a.txt"),
      line("D.", "000000", zero, "gone.txt"), line(".M", "100644", blob, "edited.txt"),
      renamed("R.", "new.txt"), "old.txt", "? n.txt",
    ])
    XCTAssertNotEqual(restaged, status)
  }

  /// サブモジュールのままの作業ツリー側の変化は、チェックアウトしたコミットの移動（`git add` でステージできる。中も変わったか
  /// も持つ）か、中身だけ（ステージできない）かを持つ。作業ツリーで消した・置き換えたサブモジュールと、作業ツリー側に変化の無い行は持たない。
  func testASubmoduleChangedInTheWorkingTreeIsMarkedWithHowItChanged() {
    func submodule(_ xy: String, _ sub: String, _ path: String) -> String {
      "1 \(xy) \(sub) 160000 160000 160000 \(zero) \(zero) \(path)"
    }
    let status = parse([
      submodule(".M", "S.M.", "dirty"), submodule(".M", "S..U", "untracked"),
      submodule(".M", "SCM.", "moved"), submodule(".M", "SC..", "committed"),
      submodule("M.", "S.M.", "staged"), submodule(".D", "S...", "removed"),
      submodule(".T", "S...", "replaced"), submodule("TM", "S...", "retyped"),
      ordinary(".M", "file.txt"),
    ])
    let marks = status.entries.mapValues(\.unstagedSubmodule)
    XCTAssertEqual(marks["dirty"], .content)
    XCTAssertEqual(marks["untracked"], .content)
    XCTAssertEqual(marks["moved"], .commit(dirty: true), "コミットが動き、中も変わった")
    XCTAssertEqual(marks["committed"], .commit(dirty: false))
    XCTAssertEqual(marks["staged"], .some(nil), "作業ツリー側に変化が無い")
    XCTAssertEqual(marks["removed"], .some(nil), "消したサブモジュールは restore で戻る")
    XCTAssertEqual(marks["replaced"], .some(nil), "ファイルに置き換えたサブモジュールは restore で戻る")
    XCTAssertEqual(marks["retyped"], .some(nil), "ファイルに置き換えてステージした後の編集は普通のファイルの変化")
    XCTAssertEqual(marks["file.txt"], .some(nil))
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

  /// ブランチのヘッダ: 名前・HEAD・upstream と先行/遅れ。detached と初回コミット前を区別し、upstream が在って
  /// `branch.ab` が無ければ数は不明（upstream の ref が消えた）。
  func testParsesTheBranchHeaders() {
    XCTAssertEqual(
      parse([
        "# branch.oid \(zero)", "# branch.head feat/x", "# branch.upstream origin/feat/x",
        "# branch.ab +2 -3",
      ]).branch,
      GitStatus.Branch(
        name: "feat/x", commit: zero,
        upstream: GitStatus.Upstream(
          name: "origin/feat/x", divergence: GitStatus.Divergence(ahead: 2, behind: 3))))
    XCTAssertEqual(
      parse(["# branch.oid \(zero)", "# branch.head (detached)"]).branch,
      GitStatus.Branch(name: nil, commit: zero, upstream: nil))
    XCTAssertEqual(
      parse(["# branch.oid (initial)", "# branch.head main"]).branch,
      GitStatus.Branch(name: "main", commit: nil, upstream: nil))
    XCTAssertEqual(
      parse(["# branch.oid \(zero)", "# branch.head main", "# branch.upstream origin/main"])
        .branch?.upstream,
      GitStatus.Upstream(name: "origin/main", divergence: nil))
    XCTAssertNil(parse([ordinary(".M", "m.txt")]).branch, "ヘッダの無い出力")
  }
}

extension GitStatus {
  /// その相対パスの行（rename・copy なら元パスも。テストの略記）。
  func row(_ path: String) -> Row {
    Row(path: path, originalPath: entries[path]?.originalPath)
  }

  /// 今の status から組んだ「変更」の行のうち `paths` の行を、パネルと同じ口で破棄する中身（テストの略記）。「変更」の行に
  /// 無いパスがあれば落とす（まだ監視が届いていない status から組むと、黙って何も破棄しない）。
  @MainActor
  func discarding(_ paths: String...) -> GitDiscardContent {
    let files = ScmChanges.build(self).changes.filter { paths.contains($0.path) }
    XCTAssertEqual(Set(files.map(\.path)), Set(paths), "「変更」の行")
    return ScmDiscardGate.content(files)
  }
}
