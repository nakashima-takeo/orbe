import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// Changes の上のバーとコミットのポップアップの flow（fixture は `ScmFixtures`——本物の git の場。窓に付けた面の中で撮る）:
/// バー（ブランチ名・同期 ↑N ↓M・コミットとステージ済みの行数）→ 開く（空の欄・押せない「コミット」）→ 打つ → 複数行 →
/// ▾ のメニュー（↓ で「コミットしてプッシュ」を選ぶ）→ esc でメニューだけ閉じる → 失敗する pre-commit hook で赤い行 →
/// 閉じて開き直す（赤い行は消えている）→ 狭い窓（添え書き → ブランチ名の省略 → ブランチ名の札の順に譲る）。
extension DesignFlowSnapshotTests {
  func testEditorScmCommit() throws {
    let queriesRoot = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let scene = try ScmFixtures.scene(queriesRoot: queriesRoot, in: TestScratch.caseDir)
    defer { scene.cleanup() }
    scene.warmUp()
    let panel = scene.panel
    let control = panel.control
    let popup = scene.pane.commitPopup
    pumpMain(until: { scene.isReady && panel.stagedLines != nil }, "行とステージ済みの行数が揃う")
    try renderInPlace(
      scene.pane, name: "editor_scm_commit", dir: previewDir("flows"), appearances: [true],
      steps: [
        ("bar", {}),
        ("open", { popup.open() }),
        ("typed", { control.message = "feat(editor): 分割をやめ、⌘E のオーバーレイに変更" }),
        (
          "multiline",
          {
            control.message += "\n\n左の列の欄とボタンを外し、\n上のバーの右端から開くポップアップにまとめる。"
          }
        ),
        (
          "menu",
          {
            popup.toggleMenu()
            for _ in 0..<2 { popup.menu.list.list.keyDown(with: .key(Self.arrow(.downArrow), [])) }
          }
        ),
        ("menu_closed", { popup.menu.list.list.keyDown(with: .key("\u{1b}", [])) }),
        (
          "failure",
          {
            try? Self.failingHook(in: scene.directory)
            panel.commitFromMessage(andPush: false)
            pumpMain(until: { control.failure != nil }, "赤い行")
          }
        ),
        (
          "reopened",
          {
            popup.close(.escape)
            popup.open()
          }
        ),
        (
          "narrow",
          {
            popup.close(.escape)
            scene.pane.window?.setContentSize(NSSize(width: 640, height: 640))
          }
        ),
        ("narrower", { scene.pane.window?.setContentSize(NSSize(width: 520, height: 640)) }),
      ])
  }

  /// 落ちる pre-commit hook（理由の行を出して 1 で終わる）。
  private static func failingHook(in directory: URL) throws {
    let hook = directory.appendingPathComponent(".git/hooks/pre-commit")
    try Data("#!/bin/sh\necho 'pre-commit: lint に失敗しました' >&2\nexit 1\n".utf8).write(to: hook)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
  }
}
