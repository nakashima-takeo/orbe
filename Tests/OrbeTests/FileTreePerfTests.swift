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
/// P3: 絞り込んでいないツリーで、子のフォルダ 2,000 個（3 つに 1 つは中身がフォルダ 1 つだけ）のフォルダを開く 1 回と、面が
/// 見え直したとき（⌘E で出し直す）の取り直し 1 回の main の時間。どちらも、行の組み立て（SwiftUI が描くときに読む）までを含む。
/// 根は git の作業ツリー（先読みが走る根）で、根のサービスはほかの持ち手が握ったまま（見え直しで判定を待たない）。
/// 連なりの先読みは裏で行うので、main の時間は先読みを入れる前の中央値 ＋ 2ms 以内に収める。入れる前の値は、同じ測定を
/// macOS 27.2・負荷平均 約 40（並行のビルドあり）で、開く 17.4ms・取り直し 17.2ms（中央値）。
@MainActor
final class FileTreePerfTests: OrbeTestCase {
  private static let folders = 2_000
  private static let rounds = 21
  /// 先読みを入れる前の中央値（ms）と、それに許す増分。
  private static let openBefore = 17.4
  private static let relistBefore = 17.2
  private static let allowance = 2.0

  override func setUpWithError() throws {
    try super.setUpWithError()
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["ORBE_EDITOR_PERF"] == "1", "ORBE_EDITOR_PERF=1 で走る")
  }

  /// ツリーの根のサービスの、ほかの持ち手。
  private var service: RootFiles?

  override func tearDownWithError() throws {
    service = nil
    try super.tearDownWithError()
  }

  /// git の作業ツリーの根の下に `big`（子のフォルダ 2,000 個）を置いたツリー（見えている）。
  private func bigTree() throws -> FileTree {
    let repo = try TempGitRepo(name: "tree", initialCommit: false)
    let big = repo.dir.appendingPathComponent("big")
    for index in 0..<Self.folders {
      var folder = big.appendingPathComponent(String(format: "f%04d", index))
      if index % 3 == 0 { folder.appendPathComponent("inner") }
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    service = RootFiles.shared(for: repo.root)
    let tree = FileTree(root: repo.root)
    tree.isLive = true
    settle()
    XCTAssertNotNil(service?.repo, "前提: 根は git の作業ツリー")
    return tree
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
    let tree = try bigTree()
    var times: [Double] = []
    for _ in 0..<Self.rounds {
      times.append(
        time {
          tree.toggle("big")
          _ = tree.rows
        })
      XCTAssertEqual(tree.rows.count, Self.folders + 1, "前提: 2,000 個の子が出る")
      settle()
      tree.toggle("big")
      settle()
    }
    reportPerf("P3", "open-2000-folders", times, digits: 2)
    XCTAssertLessThanOrEqual(median(times), Self.openBefore + Self.allowance)
  }

  func testRelistingOnShowWithTwoThousandFolders() throws {
    let tree = try bigTree()
    tree.toggle("big")
    settle()
    var times: [Double] = []
    for _ in 0..<Self.rounds {
      tree.isLive = false
      times.append(
        time {
          tree.isLive = true
          _ = tree.rows
        })
      settle()
    }
    reportPerf("P3", "relist-on-show-2000-folders", times, digits: 2)
    XCTAssertLessThanOrEqual(median(times), Self.relistBefore + Self.allowance)
  }

  private func median(_ times: [Double]) -> Double {
    times.sorted()[times.count / 2]
  }
}
