import AppKit
import OrbeTestSupport
import SwiftUI
import XCTest

@testable import Orbe

/// エクスプローラーのツリーの main の仕事を計る。`ORBE_EDITOR_PERF=1` のときだけ走る（時間はマシンと環境で変わるので通常の
/// テストでは見ない）。結果は `PERF` で始まる行に出す。時間は壁時計。
///
/// P1: 名前の一覧 5 万件に対する、照合と木の組み立て 1 回（裏の仕事）。1 字（ほぼ全件が合い、1 万件で打ち切り）・3 字・一致
/// なし。どれも中央値 100ms 以下。
///
/// P2: 結果を受け取ってから、ツリーの配置が終わるまでの main の時間。一致 1 万件の結果と、一致 200 件の結果（どちらも、行が
/// 総入れ替えになる 2 つの結果を交互に受け取る）。1 万件は p95 33ms 以下、200 件は p95 16ms 以下。あわせて、材料（5 万件）を
/// 持ったツリーで、欄への打鍵 1 回から次の runloop までの main の時間を記録する（照合は裏なので、一覧の大きさに比例しない）。
///
/// P3: 連なりの先読みと連なりの行を足しても、絞り込んでいないツリーの main の時間が増えないこと。子のフォルダ 2,000 個（3 つに
/// 1 つは中身がフォルダ 1 つだけ）のフォルダを開く 1 回と、面が見え直したとき（⌘E で出し直す）の取り直し 1 回の main の時間を、
/// 行の組み立て（SwiftUI が描くときに読む）まで含めて計る。同じ 1 回の実行の中で、git の作業ツリーの根（先読みが走り、連なりの
/// 行が出る）と、git の外の根（どちらも無い）を 1 回ずつ交互に計り、同じ回の 2 つの差（git の根 − git の外の根）の中央値は
/// 2ms 以内。どちらの根も、根のサービスはほかの持ち手が握ったまま（見え直しで判定を待たない）。
@MainActor
final class FileTreePerfTests: OrbeTestCase {
  private static let folders = 2_000
  private static let rounds = 21
  /// git の根に許す、git の外の根からの増分（ms）。
  private static let allowance = 2.0

  override func setUpWithError() throws {
    try super.setUpWithError()
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["ORBE_EDITOR_PERF"] == "1", "ORBE_EDITOR_PERF=1 で走る")
  }

  /// ツリーの根のサービスの、ほかの持ち手。
  private var services: [RootFiles] = []

  override func tearDownWithError() throws {
    services = []
    try super.tearDownWithError()
  }

  /// 根の下に `big`（子のフォルダ 2,000 個）を置いたツリー（見えている）を、git の作業ツリーの根と git の外の根で 1 つずつ。
  private func bigTrees() throws -> (git: FileTree, plain: FileTree) {
    let repo = try TempGitRepo(name: "tree", initialCommit: false)
    let outside = TestScratch.caseDir.appendingPathComponent("plain-\(UUID().uuidString)")
    var trees: [FileTree] = []
    for dir in [repo.dir, outside] {
      let big = dir.appendingPathComponent("big")
      for index in 0..<Self.folders {
        var folder = big.appendingPathComponent(String(format: "f%04d", index))
        if index % 3 == 0 { folder.appendPathComponent("inner") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      }
      let root = GitWorktreeRoot.normalizedPath(dir.path)
      services.append(RootFiles.shared(for: root))
      let tree = FileTree(root: root)
      tree.isLive = true
      trees.append(tree)
    }
    let (git, plain) = (trees[0], trees[1])
    pumpMain(until: { self.services[0].repo != nil }, "前提: 片方の根は git の作業ツリー")
    XCTAssertNil(services[1].repo, "前提: もう片方の根は git の外")
    // git の根で `big` の子の連なりが先読みで出るまで待つ。以後の回は、開いた時点で覚えから連なりの行が出る。
    git.toggle("big")
    pumpMain(until: { self.chainRows(git) == Self.folders / 3 + 1 }, "前提: git の根では連なりの行が出る")
    git.toggle("big")
    plain.toggle("big")
    settle()
    XCTAssertEqual(chainRows(plain), 0, "前提: git の外の根では連なりの行が出ない")
    plain.toggle("big")
    settle()
    return (git, plain)
  }

  /// 連なりの行の数。
  private func chainRows(_ tree: FileTree) -> Int {
    tree.rows.filter { !$0.prefix.isEmpty }.count
  }

  /// 裏から届く仕事を捌き終えるまで main を回す（計る 1 回に、前の回の残りを混ぜない）。
  private func settle() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
  }

  private func time(_ body: () -> Void) -> Double {
    let began = CACurrentMediaTime()
    body()
    return (CACurrentMediaTime() - began) * 1000
  }

  // MARK: - P1・P2

  private static let names = 50_000

  /// 5 万件の相対パス（100 フォルダ × 10 フォルダ × 50 ファイル。名前は `file<番号>.swift`）。ディスクには作らない。
  private static func paths() -> [String] {
    (0..<names).map { index in
      String(format: "dir%02d/sub%d/file%05d.swift", index / 500, (index / 50) % 10, index)
    }
  }

  private func index() -> FileTreeFilter.Index {
    FileTreeFilter.index(
      root: TestScratch.caseDir, paths: Self.paths(), isTruncated: false)
  }

  func testMatchingFiftyThousandNames() throws {
    let index = index()
    for (label, text, expected) in [
      ("1-char", "e", FileTreeFilter.matchLimit), ("3-char", "123", nil), ("no-match", "zzq", 0),
    ] {
      var times: [Double] = []
      for _ in 0..<9 {
        var result: FileTreeFilter.Result?
        times.append(time { result = FileTreeFilter.result(of: index, text: text) })
        if let expected { XCTAssertEqual(result?.matchCount, expected, label) }
      }
      reportPerf("P1", label, times)
      XCTAssertLessThanOrEqual(median(times), 100, label)
    }
  }

  /// 根を握らないツリー（対象の一覧を取りに行かない）を、エクスプローラーとして 264×800 で配置する。
  private func hostedExplorer() -> (FileTree, NSHostingView<AnyView>) {
    let tree = FileTree(root: GitWorktreeRoot.normalizedPath(TestScratch.caseDir.path))
    let host = NSHostingView(
      rootView: AnyView(ExplorerView(shell: EditorShellModel(), tree: tree)))
    host.frame = NSRect(x: 0, y: 0, width: 264, height: 800)
    host.layoutSubtreeIfNeeded()
    return (tree, host)
  }

  func testReceivingAResultLaysOutTheTree() throws {
    let index = index()
    for (label, texts, limit) in [
      ("10000-matches", ["e", "s"], 33.0), ("200-matches", ["1234", "2345"], 16.0),
    ] {
      let results = texts.map { FileTreeFilter.result(of: index, text: $0) }
      let (tree, host) = hostedExplorer()
      var times: [Double] = []
      for round in 0..<21 {
        let result = results[round % 2]
        tree.setFilterText(result.text)
        times.append(
          time {
            tree.filter.receive(result)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(mode: .default, before: Date())
          })
        XCTAssertEqual(tree.filter.shown?.text, result.text)
      }
      reportPerf("P2", label, times)
      let sorted = times.sorted()
      XCTAssertLessThanOrEqual(
        sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))], limit, label)
    }
  }

  func testTypingInTheFilterDoesNotWaitForTheMatch() throws {
    let (tree, host) = hostedExplorer()
    tree.filter.adopt(index())
    var times: [Double] = []
    for round in 0..<21 {
      let text = round % 2 == 0 ? "fi" : "fil"
      times.append(
        time {
          tree.setFilterText(text)
          host.layoutSubtreeIfNeeded()
          RunLoop.main.run(mode: .default, before: Date())
        })
      settle()
    }
    reportPerf("P2", "keystroke", times, digits: 2)
  }

  // MARK: - P3

  func testOpeningAFolderOfTwoThousandFolders() throws {
    let trees = try bigTrees()
    compare("open-2000-folders", trees) { tree in
      let elapsed = time {
        tree.toggle("big")
        _ = tree.rows
      }
      XCTAssertEqual(tree.rows.count, Self.folders + 1, "前提: 2,000 個の子が出る")
      settle()
      tree.toggle("big")
      settle()
      return elapsed
    }
  }

  func testRelistingOnShowWithTwoThousandFolders() throws {
    let trees = try bigTrees()
    trees.git.toggle("big")
    trees.plain.toggle("big")
    settle()
    compare("relist-on-show-2000-folders", trees) { tree in
      tree.isLive = false
      let elapsed = time {
        tree.isLive = true
        _ = tree.rows
      }
      settle()
      return elapsed
    }
  }

  /// 2 つの根で `measure` を 1 回ずつ、先に計る根を回ごとに入れ替えて `rounds` 回計り、時間を出す。同じ回の 2 つの差（git の
  /// 根 − git の外の根）の中央値が `allowance` 以内かを確かめる——隣り合って計った 2 つを比べ、実行の中の負荷の揺れを差から除く。
  private func compare(
    _ name: String, _ trees: (git: FileTree, plain: FileTree), _ measure: (FileTree) -> Double
  ) {
    var git: [Double] = []
    var plain: [Double] = []
    for round in 0..<Self.rounds {
      if round % 2 == 0 {
        git.append(measure(trees.git))
        plain.append(measure(trees.plain))
      } else {
        plain.append(measure(trees.plain))
        git.append(measure(trees.git))
      }
    }
    let differences = zip(git, plain).map { $0 - $1 }
    reportPerf("P3", name + "-git", git, digits: 2)
    reportPerf("P3", name + "-plain", plain, digits: 2)
    reportPerf("P3", name + "-difference", differences, digits: 2)
    XCTAssertLessThanOrEqual(median(differences), Self.allowance, name)
  }

  private func median(_ times: [Double]) -> Double {
    times.sorted()[times.count / 2]
  }
}
