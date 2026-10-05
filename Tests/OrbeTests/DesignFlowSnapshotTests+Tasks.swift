import SwiftUI
import XCTest

@testable import Orbe

/// タスク画面の flow（ファイル分割の拡張）。撮り方・出力先は本体の `flow` を共有する。
extension DesignFlowSnapshotTests {
  /// 打って絞り込み・↵ で追加・space で完了・→ で右の欄・期限の編集（読めない入力は赤）・esc で一覧、
  /// agent が上の欄に足しても選択が動かない・完了の欄を開く（詳細のある完了の行も沈む）、までを撮る。
  func testTaskPalette() throws {
    let palette = DesignSceneFixtures.taskPaletteModel()
    try flow(
      "task_palette", size: NSSize(width: 1440, height: 900),
      render: {
        ZStack {
          BackgroundGlow()
          TaskPaletteOverlay(model: palette)
        }
        .environment(\.localization, LocalizationStore(language: .ja))
      },
      steps: [
        ("start", {}),
        ("typed", { palette.query = "PR の説明を書く" }),
        ("added", { palette.submit() }),
        ("done", { palette.toggleDone(palette.store.tasks.last!.id) }),
        (
          "detail",
          {
            palette.move(-1); palette.enterDetail()
          }
        ),
        (
          "due_field",
          {
            palette.moveField(1); palette.moveField(1); palette.moveField(1)
          }
        ),
        (
          "due_editing",
          {
            palette.beginEditing(); palette.draftText = "あした"
          }
        ),
        ("due_invalid", { palette.endEditing(commit: true) }),
        (
          "due_set",
          {
            palette.draftText = "10/9"; palette.endEditing(commit: true)
          }
        ),
        ("back", { palette.leaveDetail() }),
        (
          "agent_inserted",
          {
            let item = try? palette.store.add(TaskDraft(title: "agent が足した", status: .inProgress))
            if let item { try? palette.store.move(item.id, .before, 1) }
            palette.reconcile()
          }
        ),
        ("done_expanded", { palette.toggleDoneExpanded() }),
      ])
  }

  /// 詳細の Issue・PR の欄: 行に入る・⌫ で外すと焦点が同じ位置へ移る・agent が結び付けると番号だけで
  /// 現れる（値はまだ届いていない）、までを撮る。
  func testTaskPaletteLinks() throws {
    let palette = DesignSceneFixtures.taskPaletteModel()
    try flow(
      "task_palette_links", size: NSSize(width: 1440, height: 900),
      render: {
        ZStack {
          BackgroundGlow()
          TaskPaletteOverlay(model: palette)
        }
        .environment(\.localization, LocalizationStore(language: .ja))
      },
      steps: [
        ("start", {}),
        (
          "link_focused",
          {
            palette.enterDetail(); palette.moveField(-1); palette.moveField(-1)
          }
        ),
        ("unlinked", { palette.unlink(palette.selectedTask!.links[0].item) }),
        (
          "agent_linked",
          {
            var update = TaskUpdate()
            update.links =
              palette.selectedTask!.links + [DesignSceneFixtures.taskLink(.issue, "orbe", 230)]
            _ = try? palette.store.update(1, update)
            palette.reconcile()
          }
        ),
      ])
  }

  /// 選んだ未完了の行の取っ手・掴んで下へ動かした途中（行のずれと落ちる位置の線）・欄の端で止まる掴んだ
  /// 行・離して並びが変わった後、を撮る。
  func testTaskPaletteDrag() throws {
    let palette = DesignSceneFixtures.taskPaletteModel()
    let height = TaskPaletteRowMetrics.line
    let start = CGPoint(x: 200, y: 300)
    try flow(
      "task_palette_drag", size: NSSize(width: 1440, height: 900),
      render: {
        ZStack {
          BackgroundGlow()
          TaskPaletteOverlay(model: palette)
        }
        .environment(\.localization, LocalizationStore(language: .ja))
      },
      steps: [
        ("grip", {}),
        ("grabbed_down", { palette.dragChanged(6, start: start, translation: height * 2.4) }),
        ("grabbed_up_edge", { palette.dragChanged(6, start: start, translation: -height * 5) }),
        ("dropped", { palette.dragEnded() }),
      ])
  }

  /// GitHub タブ: #221 をタスクにする（行が結び付いた側へ移る）・⌘L で別のタスクへ付け替えを選ぶ・↵ で付け替え・
  /// ⌘⌫ で外す（結び付いていない側へ戻る）、までを撮る。アサインの書き込みは何もしない置き場に頼む。
  func testTaskPaletteGithub() throws {
    let palette = DesignSceneFixtures.taskPaletteModel()
    let issue221 = TaskPaletteGitHubRowID.item(GitHubItemID(repo: "nakatake/orbe", number: 221)!)
    try flow(
      "task_palette_github", size: NSSize(width: 1440, height: 900),
      render: {
        ZStack {
          BackgroundGlow()
          TaskPaletteOverlay(model: palette)
        }
        .environment(\.localization, LocalizationStore(language: .ja))
      },
      steps: [
        (
          "start",
          {
            palette.toggleTab(); palette.tapGitHubRow(issue221)
          }
        ),
        (
          "pane_priority",
          {
            palette.enterPane(); palette.movePaneStop(1); palette.changePaneValue(-1)
          }
        ),
        ("made_task", { palette.submit() }),
        ("pick_task", { palette.linkSelectedGitHubItem() }),
        ("pick_moved", { palette.move(1) }),
        ("relinked", { palette.submit() }),
        ("unlinked", { palette.unlinkSelectedGitHubItem() }),
      ])
  }

  /// 小さい窓（tasks_small と同じ 800×560）で、右の欄を ↓ で下端の詳細の欄まで進むと、強調された項目が見える
  /// 位置へ送られ、詳細の欄を編集する（フッターは「esc 確定」だけ）・確定すると欄に居たまま終わる・esc → ↓ で
  /// 次のタスクを選ぶと右の欄が先頭から見える、までを撮る。
  func testTaskPaletteSmallDetail() throws {
    let palette = DesignSceneFixtures.taskPaletteModel()
    try hostedTaskPaletteFlow(
      "task_palette_small_detail", palette, size: NSSize(width: 800, height: 560),
      steps: [
        ("status", { _ in palette.enterDetail() }),
        (
          "due",
          { _ in
            palette.moveField(1); palette.moveField(1); palette.moveField(1)
          }
        ),
        (
          "description",
          { _ in
            palette.moveField(1); palette.moveField(1)
          }
        ),
        (
          "description_editing",
          { _ in
            palette.beginEditing(); palette.draftText += "\n2 行目"
          }
        ),
        ("description_committed", { _ in palette.endEditing(commit: true) }),
        (
          "next_task",
          { _ in
            palette.leaveDetail(); palette.move(1)
          }
        ),
      ])
  }

  /// 窓が低い（800×480）とき、GitHub タブの結び付いていない行の右の欄は欄の幅に収まってフッターを切らず、
  /// ↓ で期限まで進むと見える位置へ送られ、下端まで送るとボタンが縦に積まれ、別の項目を選ぶと欄が先頭から
  /// 見える、までを撮る。
  func testTaskPaletteSmallGithub() throws {
    let palette = DesignSceneFixtures.taskPaletteModel()
    let issue221 = TaskPaletteGitHubRowID.item(GitHubItemID(repo: "nakatake/orbe", number: 221)!)
    let issue220 = TaskPaletteGitHubRowID.item(GitHubItemID(repo: "nakatake/orbe", number: 220)!)
    try hostedTaskPaletteFlow(
      "task_palette_small_github", palette, size: NSSize(width: 800, height: 480),
      steps: [
        (
          "pane_assign",
          { _ in
            palette.toggleTab(); palette.tapGitHubRow(issue221); palette.enterPane()
          }
        ),
        (
          "pane_due",
          { _ in
            palette.movePaneStop(1); palette.movePaneStop(1)
          }
        ),
        ("pane_bottom", { host in self.scrollRightmostToBottom(in: host) }),
        ("next_item", { _ in palette.tapGitHubRow(issue220) }),
      ])
  }

  /// いちばん右のスクロール（GitHub タブの右の欄）を下端まで送る。
  private func scrollRightmostToBottom(in host: NSView) {
    func scrollViews(_ view: NSView) -> [NSScrollView] {
      (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }
    guard
      let pane = scrollViews(host).max(by: {
        $0.convert($0.bounds, to: host).minX < $1.convert($1.bounds, to: host).minX
      }),
      let document = pane.documentView
    else { return XCTFail("右の欄のスクロールが見つからない") }
    let bottom = document.isFlipped ? document.bounds.height - pane.contentView.bounds.height : 0
    pane.contentView.scroll(to: NSPoint(x: 0, y: bottom))
    pane.reflectScrolledClipView(pane.contentView)
  }

  /// タスク画面を 1 つの窓に載せたまま、手順ごとに撮る（名前と置き場は `flow` と同じ）。撮るたびに載せ直すと、
  /// キーで移った場所へ送ったスクロールが消える。
  private func hostedTaskPaletteFlow(
    _ name: String, _ palette: TaskPaletteModel, size: NSSize,
    steps: [(label: String, action: (NSView) -> Void)]
  ) throws {
    let appearance = NSAppearance(named: .darkAqua)
    let host = NSHostingView(
      rootView: ZStack {
        BackgroundGlow()
        TaskPaletteOverlay(model: palette)
      }
      .frame(width: size.width, height: size.height)
      .environment(\.localization, LocalizationStore(language: .ja)))
    host.frame = NSRect(origin: .zero, size: size)
    host.appearance = appearance
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = appearance
    window.contentView = host
    defer { window.contentView = nil }
    let dir = previewDir("flows")
    for (index, step) in steps.enumerated() {
      step.action(host)
      host.layoutSubtreeIfNeeded()
      RunLoop.current.run(until: Date().addingTimeInterval(0.3))
      let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: rep)
      let url = dir.appendingPathComponent(
        String(format: "%@_%02d_%@.png", name, index, step.label))
      try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
      print("[flow] wrote \(url.path)")
    }
  }
}
