import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// diff を開いたときの位置——最初の変更区間を削除行まで含めて見せ、開いた時点に追いついた並びで 1 回だけ送る。壊れると、
/// 削除だけの変更の削除行が画面の外に切れる・変更の無い diff が後から跳ぶ・エージェントが書いた直後の diff が変更へ
/// 送られない。
extension EditorDiffTests {
  /// 最初の変更区間が削除だけなら、上の文脈の行から削除行の終わりまでを見せる——中ほどの区間は収まれば中央に置いて
  /// 最後の削除行まで見え、末尾の区間も削除行まで見える。インラインでも並列（右の詰め物）でも同じ。
  func testADeletionOnlyFirstChangeOpensWithTheRemovedLinesInView() throws {
    let lines = (0..<200).map { "line \($0)" }
    try repo.write("middle.txt", lines.joined(separator: "\n") + "\n")
    try repo.write("tail.txt", lines.joined(separator: "\n") + "\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "long"]).isSuccess)
    try repo.write("middle.txt", (lines[..<100] + lines[118...]).joined(separator: "\n") + "\n")
    try repo.write("tail.txt", lines[..<190].joined(separator: "\n") + "\n")
    let modes = EditorDiffModeState()
    let (tab, _) = tab()
    tab.group.view.editor.configure(
      translucency: ChromeTranslucency(), localization: LocalizationStore(language: .ja),
      fontResolver: ChromeFontResolver(), sidebar: EditorSidebarState(), diffModes: modes)
    for mode in [EditorDiff.Mode.inline, .side] {
      modes.select(mode)
      for (path, boundary) in [("middle.txt", 100), ("tail.txt", 190)] {
        let diff = try tab.group.editor.openDiff(id(path, .workingTree), as: .pinned)
        pumpMain(
          until: { diff.placement == .placed && diff.newSurface != nil },
          "\(mode) \(path): 最初の変更区間へ送る")
        let surface = try engine(diff.newSurface)
        surface.flush()
        let (first, visible) = surface.viewportLines
        let rows = surface.rows
        XCTAssertGreaterThan(visible, 19, "前提: 文脈 1 行と削除 18 行が収まる")
        XCTAssertLessThanOrEqual(
          Double(first), rows.unit(ofLine: boundary - 1), "\(mode) \(path): 上の文脈の行から")
        XCTAssertGreaterThanOrEqual(
          Double(first + visible), rows.unit(ofLine: boundary), "\(mode) \(path): 削除行の終わりまで見える")
        tab.group.editor.close(.diff(id(path, .workingTree)))
      }
    }
  }

  /// 変更の無い状態で開いた diff は、後から変更が現れても見えている位置が動かない（ファイルタブと共有する面も動かない）。
  func testADiffOpenedWithoutChangesDoesNotJumpWhenAChangeAppears() throws {
    var lines = (0..<300).map { "line \($0)" }
    try repo.write("long.txt", lines.joined(separator: "\n") + "\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "long"]).isSuccess)
    let (tab, _) = tab()
    let diff = try tab.group.editor.openDiff(id("long.txt", .workingTree), as: .pinned)
    pumpMain(until: { diff.placement == .placed }, "位置を決める")
    let surface = try engine(diff.newSurface)
    surface.flush()
    XCTAssertEqual(surface.viewport.top, RowPosition(line: 0), "前提: 変更が無いので先頭")
    lines[250] = "changed 250"
    try repo.write("long.txt", lines.joined(separator: "\n") + "\n")
    waitRows(diff, "変更が現れる") { $0.style(ofLine: 250) == DiffStyle.added }
    surface.flush()
    XCTAssertEqual(surface.viewport.top, RowPosition(line: 0), "現れた変更へ跳ばない")
  }

  /// 監視の知らせより先に開いた diff も、開いた時点の中身に追いついてから最初の変更へ送る——エージェントがファイルを書いた
  /// 直後の作業ツリー diff（ファイルタブで開いている文書）も、`git add` の直後のステージ済み diff も。
  func testADiffOpenedRightAfterAWriteRevealsTheWrittenChange() throws {
    var lines = (0..<300).map { "line \($0)" }
    try repo.write("long.txt", lines.joined(separator: "\n") + "\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "long"]).isSuccess)
    let (tab, _) = tab()
    let document = try tab.group.editor.open(repo.url("long.txt"), as: .pinned)
    XCTAssertTrue(document.waitUntilCaughtUp())
    pumpMain(until: { document.baseline != nil }, "前提: 文書が index の底を持つ")

    lines[250] = "changed 250"
    try repo.write("long.txt", lines.joined(separator: "\n") + "\n")
    let working = try tab.group.editor.openDiff(id("long.txt", .workingTree), as: .pinned)
    pumpMain(until: { working.placement == .placed }, "作業ツリー: 位置を決める")
    let surface = try engine(working.newSurface)
    surface.flush()
    XCTAssertGreaterThan(surface.viewport.top.line, 200, "作業ツリー: 書いた変更へ送る")

    lines[260] = "staged 260"
    try repo.write("long.txt", lines.joined(separator: "\n") + "\n")
    XCTAssertTrue(repo.git(["add", "long.txt"]).isSuccess)
    let staged = try tab.group.editor.openDiff(id("long.txt", .staged), as: .pinned)
    pumpMain(until: { staged.placement == .placed && staged.newSurface != nil }, "ステージ済み: 位置を決める")
    let stagedSurface = try engine(staged.newSurface)
    stagedSurface.flush()
    XCTAssertGreaterThan(stagedSurface.viewport.top.line, 200, "ステージ済み: add した変更へ送る")
  }
}
