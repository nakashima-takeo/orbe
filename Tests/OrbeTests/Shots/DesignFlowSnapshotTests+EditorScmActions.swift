import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// Changes の実行中の札・失敗の札・破棄の確認・変更なしの flow（fixture は `ScmFixtures`——本物の git の場。窓に付けた面の
/// 中で、dark と light で撮る）: 返らない pre-commit hook のコミットで実行中の札 → コミットのポップアップを開く（札は
/// ポップアップの下）→ 止める → upstream の無いブランチのプルで失敗の札 → × で消す → 追跡中のファイルの「変更を破棄」で
/// 面の中の確認 → esc でキャンセル → 未追跡のファイルを足して「すべての変更を破棄」の確認（件数とゴミ箱の一文）→ 端末で
/// すべてコミットして変更なし。
extension DesignFlowSnapshotTests {
  func testEditorScmActions() throws {
    let queriesRoot = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let scene = try ScmFixtures.scene(queriesRoot: queriesRoot, in: TestScratch.caseDir)
    defer { scene.cleanup() }
    scene.warmUp()
    pumpMain(until: { scene.isReady }, "行・グラフ・HEAD の push 済みが揃う")
    try renderInPlace(
      scene.pane, name: "editor_scm_actions", dir: previewDir("flows"), appearances: [true, false],
      steps: runningSteps(scene) + failureSteps(scene) + discardSteps(scene))
  }

  /// 実行中の札（ポップアップを開いた姿を含む）と止める。
  private func runningSteps(_ scene: ScmFixtures.Scene) -> [(label: String, action: () -> Void)] {
    let panel = scene.panel
    let control = panel.control
    let popup = scene.pane.commitPopup
    return [
      (
        "running",
        {
          try? Self.stallingHook(in: scene.directory)
          control.message = "wip"
          panel.commitSnapshot().commit()
          pumpMain(until: { control.cardOperation != nil }, "実行中の札が出る")
        }
      ),
      ("running_popup", { popup.open() }),
      (
        "stopped",
        {
          popup.close(.escape)
          control.cardOperation?.stop()
          pumpMain(until: { control.operations.isEmpty }, "止めた")
          try? FileManager.default.removeItem(
            at: scene.directory.appendingPathComponent(".git/hooks/pre-commit"))
        }
      ),
    ]
  }

  /// upstream の無いブランチのプルで失敗の札を出し、× で消す。
  private func failureSteps(_ scene: ScmFixtures.Scene) -> [(label: String, action: () -> Void)] {
    let panel = scene.panel
    let control = panel.control
    let git = scene.git
    return [
      (
        "failure",
        {
          try? git(["branch", "--unset-upstream"])
          pumpMain(until: { panel.branch?.upstream == nil }, "upstream が外れる")
          control.pull()
          pumpMain(until: { control.failure != nil }, "失敗の札")
        }
      ),
      (
        "failure_dismissed",
        {
          control.clearFailure()
          try? git(["branch", "--set-upstream-to=origin/main"])
          pumpMain(until: { panel.branch?.upstream != nil }, "upstream が戻る")
        }
      ),
    ]
  }

  /// 破棄の確認（1 件・すべて）と、すべてコミットした後の変更なし。
  private func discardSteps(_ scene: ScmFixtures.Scene) -> [(label: String, action: () -> Void)] {
    let panel = scene.panel
    let pane = scene.pane
    let git = scene.git
    let press = { (path: String?, control: ScmControl) in
      guard let row = panel.layout.index[ScmRowID(section: .changes, path: path)] else {
        return XCTFail("変更の行 \(path ?? "見出し") が無い")
      }
      panel.press(row, control, in: panel.layout)
    }
    return [
      ("discard", { press("README.md", .discard) }),
      ("discard_cancelled", { pane.window?.firstResponder?.keyDown(with: .key("\u{1b}", [])) }),
      (
        "discard_all",
        {
          try? Data("メモ\n".utf8).write(to: scene.directory.appendingPathComponent("notes.txt"))
          pumpMain(until: { panel.changes.changes.count == 4 }, "未追跡の行が加わる")
          press(nil, .discardAll)
        }
      ),
      (
        "empty",
        {
          pane.confirm.close(.owner)
          try? git(["add", "-A"])
          try? git(["commit", "-qm", "README: 畳んでから渡す"])
          pumpMain(until: { panel.count == 0 && panel.listState == .none }, "変更なし")
        }
      ),
    ]
  }

  /// 返らない pre-commit hook（止めるまで待つ。60 秒で自分から抜ける）。
  private static func stallingHook(in directory: URL) throws {
    let hook = directory.appendingPathComponent(".git/hooks/pre-commit")
    try Data("#!/bin/sh\nsleep 60\n".utf8).write(to: hook)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
  }
}
