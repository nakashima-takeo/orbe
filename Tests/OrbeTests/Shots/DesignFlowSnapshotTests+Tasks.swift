import SwiftUI
import XCTest

@testable import Orbe

/// タスク画面の flow（ファイル分割の拡張）。撮り方・出力先は本体の `flow` を共有する。
extension DesignFlowSnapshotTests {
  /// 打って絞り込み・↵ で追加・space で完了・→ で右の欄・期限の編集（読めない入力は赤）・esc で一覧、
  /// agent が足しても選択が動かない、までを撮る。
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
            _ = try? palette.store.add(TaskDraft(title: "agent が足した", status: .inProgress))
            palette.reconcile()
          }
        ),
      ])
  }

  /// 表: 完了の札をオンにする（完了の行は暗い）・優先度のメニューを開いて値をオンにする（メニューは開いたまま）・
  /// メニューを閉じる・件名の列で並べてもう一度押して逆にする・右の欄で完了まで巡ると行が暗くなって同じ場所に残る・
  /// ↓ で離れても暗い行は残る・space で完了にした行は選んだまま暗くなる・もう一度 space で戻る・列の見出しを押すと
  /// 暗い行が消える・⇥ で次のタブ、までを撮る。
  func testTaskPaletteTable() throws {
    let palette = DesignSceneFixtures.taskPaletteModel()
    try flow(
      "task_palette_table", size: NSSize(width: 1440, height: 900),
      render: {
        ZStack {
          BackgroundGlow()
          TaskPaletteOverlay(model: palette)
        }
        .environment(\.localization, LocalizationStore(language: .ja))
      },
      steps: [
        ("start", {}),
        ("filter_done", { palette.toggleState(.done) }),
        ("filter_menu", { palette.toggleFilterMenu(.priority) }),
        ("filter_menu_high", { palette.togglePriorityFilter(.high) }),
        ("filter_menu_closed", { palette.closeFilterMenu() }),
        (
          "sorted_title",
          {
            palette.togglePriorityFilter(.high); palette.toggleState(.done)
            palette.setSort(.title)
          }
        ),
        ("sorted_title_reversed", { palette.setSort(.title) }),
        (
          "status_done_dimmed",
          {
            palette.enterDetail(); palette.changeValue(1); palette.changeValue(1)
          }
        ),
        (
          "dimmed_left",
          {
            palette.leaveDetail(); palette.move(1)
          }
        ),
        ("space_done_dimmed", { palette.submit() }),
        ("space_undone", { palette.submit() }),
        ("refreshed", { palette.setSort(.title) }),
        ("next_tab", { palette.setTab(palette.tab.next) }),
      ])
  }

  /// 待ちの条件: 見積もり（待っている）を選ぶ → → で右の欄 → ↓ で確認のコマンド → ↵ で開く → ↓ で実行の記録 → ↵ で
  /// 開く → 一覧へ戻り、確認が成功して解けた見積もりを選んだまま（フッターの「⌘↵ … を claude で続きから」）→ 見積もりに
  /// #221 を結び付けて GitHub タブでその行を選ぶ（フッターは同じく「⌘↵ … を claude で続きから」）、までを撮る。
  func testTaskWaitCondition() throws {
    let palette = DesignSceneFixtures.taskPaletteModel(
      DesignSceneFixtures.taskWaitConditionFile(),
      sessionTabs: DesignSceneFixtures.taskSessionTabs())
    let issue221 = DesignSceneFixtures.taskLink(.issue, "orbe", 221)
    try flow(
      "task_wait_condition", size: NSSize(width: 1440, height: 900),
      render: {
        ZStack {
          BackgroundGlow()
          TaskPaletteOverlay(model: palette)
        }
        .environment(\.localization, LocalizationStore(language: .ja))
      },
      steps: [
        ("selected", { palette.tapRow(.task(3)) }),
        ("detail", { palette.enterDetail() }),
        (
          "command",
          {
            palette.moveField(1); palette.moveField(1)
          }
        ),
        ("command_open", { palette.toggleConditionPart(.command) }),
        ("log", { palette.moveField(1) }),
        ("log_open", { palette.toggleConditionPart(.log) }),
        (
          "resolved",
          {
            palette.leaveDetail()
            let condition = palette.selectedTask!.waiting!.condition!
            let now = Date()
            palette.store.recordCheck(
              3, condition: condition.id,
              BackgroundRunResult(
                commandLine: condition.command, startedAt: now, endedAt: now, ending: .exited(0),
                output: .command(
                  stdout: .init(data: Data(DesignSceneFixtures.taskWaitOutput.utf8)),
                  stderr: .init())))
            palette.reconcile()
          }
        ),
        (
          "resolved_github",
          {
            _ = try? palette.store.update(3, TaskUpdate(links: [issue221]))
            palette.setTab(.github)
            palette.tapGitHubRow(.item(issue221.item))
          }
        ),
      ])
  }

  /// 狭い窓（tasks_small と同じ 800×560）で、待ちの条件の箱と開いた実行の記録が欄に収まる。
  func testTaskWaitConditionSmall() throws {
    let palette = DesignSceneFixtures.taskPaletteModel(
      DesignSceneFixtures.taskWaitConditionFile(),
      sessionTabs: DesignSceneFixtures.taskSessionTabs())
    try hostedTaskPaletteFlow(
      "task_wait_condition_small", palette, size: NSSize(width: 800, height: 560),
      steps: [
        (
          "command",
          { _ in
            palette.tapRow(.task(3)); palette.enterDetail()
            palette.moveField(1); palette.moveField(1)
          }
        ),
        ("command_open", { _ in palette.toggleConditionPart(.command) }),
        ("log", { _ in palette.moveField(1) }),
        ("log_open", { _ in palette.toggleConditionPart(.log) }),
      ])
  }

  /// 右の欄の Issue・PR の欄: 行に入る・⌫ で外すと焦点が同じ位置へ移る・agent が結び付けると番号だけで
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
            palette.tapRow(.task(4)); palette.enterDetail(); palette.moveField(-1)
            palette.moveField(-1)
          }
        ),
        ("unlinked", { palette.unlink(palette.selectedTask!.links[0].item) }),
        (
          "agent_linked",
          {
            var update = TaskUpdate()
            update.links =
              palette.selectedTask!.links + [DesignSceneFixtures.taskLink(.issue, "orbe", 230)]
            _ = try? palette.store.update(4, update)
            palette.reconcile()
          }
        ),
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
            palette.setTab(palette.tab.next); palette.tapGitHubRow(issue221)
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
            palette.setTab(palette.tab.next); palette.tapGitHubRow(issue221); palette.enterPane()
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
    scrollToBottom(in: host) { views in
      views.max(by: {
        $0.convert($0.bounds, to: host).minX < $1.convert($1.bounds, to: host).minX
      })
    }
  }

  /// `pick` が選んだスクロール（引数は view の木を深さ優先でたどった順）を下端まで送る。
  func scrollToBottom(in host: NSView, pick: ([NSScrollView]) -> NSScrollView?) {
    func scrollViews(_ view: NSView) -> [NSScrollView] {
      (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }
    guard let pane = pick(scrollViews(host)), let document = pane.documentView
    else { return XCTFail("スクロールが見つからない") }
    let bottom = document.isFlipped ? document.bounds.height - pane.contentView.bounds.height : 0
    pane.contentView.scroll(to: NSPoint(x: 0, y: bottom))
    pane.reflectScrolledClipView(pane.contentView)
  }

  /// タスク画面を 1 つの窓に載せたまま、手順ごとに撮る（名前と置き場は `flow` と同じ）。撮るたびに載せ直すと、
  /// キーで移った場所へ送ったスクロールが消える。
  func hostedTaskPaletteFlow(
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
