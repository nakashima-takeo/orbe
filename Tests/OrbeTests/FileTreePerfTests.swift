import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// エクスプローラーのツリーの main の仕事を計る。`ORBE_EDITOR_PERF=1` のときだけ走る（時間はマシンと環境で変わるので通常の
/// テストでは見ない）。結果は `PERF` で始まる行に出す。時間は壁時計。
///
/// P3: 絞り込んでいないツリーで、子のフォルダ 2,000 個（3 つに 1 つは中身がフォルダ 1 つだけ）のフォルダを開く 1 回と、面が
/// 見え直したとき（⌘E で出し直す）の取り直し 1 回の main の時間。どちらも、行の組み立て（SwiftUI が描くときに読む）までを含む。
@MainActor
final class FileTreePerfTests: OrbeTestCase {
  private static let folders = 2_000
  private static let rounds = 21

  override func setUpWithError() throws {
    try super.setUpWithError()
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["ORBE_EDITOR_PERF"] == "1", "ORBE_EDITOR_PERF=1 で走る")
  }

  /// 根の下に `big`（子のフォルダ 2,000 個）を置いたツリー（見えている）。
  private func bigTree() throws -> FileTree {
    let root = TestScratch.caseDir.appendingPathComponent("tree")
    let big = root.appendingPathComponent("big")
    for index in 0..<Self.folders {
      var folder = big.appendingPathComponent(String(format: "f%04d", index))
      if index % 3 == 0 { folder.appendPathComponent("inner") }
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    let tree = FileTree(root: GitWorktreeRoot.normalizedPath(root.path))
    tree.isLive = true
    settle()
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
  }
}
