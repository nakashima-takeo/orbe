import SwiftUI
import XCTest

@testable import Orbe

/// タスク画面の gallery（見本 List.png・Main.png・Wait.png・GitHub.png の中身を、1440×900 の窓で overlay ごと撮る）。
extension DesignGallerySnapshotTests {
  func renderTaskPaletteSnapshots(dir: URL) throws {
    func write(_ name: String, _ model: TaskPaletteModel, _ w: CGFloat = 1440, _ h: CGFloat = 900)
      throws
    {
      try writePNG(
        ZStack {
          BackgroundGlow()
          TaskPaletteOverlay(model: model)
        }
        .frame(width: w, height: h)
        .environment(\.localization, LocalizationStore(language: .ja)),
        size: NSSize(width: w, height: h), name: name, dir: dir)
    }
    // List: 開いた直後（完了の札だけが切れている・作成 ↓）。
    try write("tasks_design.png", DesignSceneFixtures.taskPaletteModel())

    try renderTaskTableSnapshots(write)

    let detail = DesignSceneFixtures.taskPaletteModel()
    detail.move(1)
    detail.move(1)
    detail.enterDetail()
    detail.moveField(1)
    try write("tasks_detail.png", detail)

    // 右の欄の agent の場所に居る（「claude が取り掛かっている」とフッターの「↵ issue-212 へ移る」）。
    let agent = DesignSceneFixtures.taskPaletteModel()
    agent.tapRow(.task(4))
    agent.enterDetail()
    agent.moveField(-1)
    agent.moveField(-1)
    agent.moveField(-1)
    agent.moveField(-1)
    try write("tasks_detail_agent.png", agent)

    // 右の欄の Issue・PR の欄の行に居る（「外す」とフッターの「↵ #213 を GitHub で開く」）。
    let link = DesignSceneFixtures.taskPaletteModel()
    link.tapRow(.task(4))
    link.enterDetail()
    link.moveField(-1)
    link.moveField(-1)
    try write("tasks_detail_link.png", link)

    let filtered = DesignSceneFixtures.taskPaletteModel()
    filtered.query = "経"
    try write("tasks_filtered.png", filtered)

    // 右の欄の「＋ 結び付ける」に居る（右に「ブランチの PR は自動」）。
    let addLink = DesignSceneFixtures.taskPaletteModel()
    addLink.tapRow(.task(4))
    addLink.enterDetail()
    addLink.moveField(-1)
    try write("tasks_detail_add_link.png", addLink)

    try renderTaskWaitConditionSnapshots(write)
    try renderTaskSecretarySnapshots(write)
    try renderTaskPaletteGitHubSnapshots(write)
    try renderTaskPaletteAutomationSnapshots(write)

    try write(
      "tasks_empty.png",
      DesignSceneFixtures.taskPaletteModel(
        TasksFile(version: TaskPersistence.version, nextId: 1, tasks: [])))

    // 小さい窓: カードは窓に収まり、右の欄は選択式の値が並びきる幅で止まる。
    try write("tasks_small.png", DesignSceneFixtures.taskPaletteModel(), 800, 560)
  }
}

extension DesignGallerySnapshotTests {
  /// 表（見本 Wait.png・Main.png）と、絞り込みの面・並べ替え・完了の札・右の欄で完了まで巡った状態。
  func renderTaskTableSnapshots(
    _ write: (String, TaskPaletteModel, CGFloat, CGFloat) throws -> Void
  ) throws {
    // Wait: 待ちだけに絞り、見積もりのタスクを選ぶ（右の欄に会話の行・待ちの条件の箱）。
    let wait = DesignSceneFixtures.taskPaletteModel(
      DesignSceneFixtures.taskWaitConditionFile(),
      sessionTabs: DesignSceneFixtures.taskSessionTabs())
    wait.toggleState(.todo)
    wait.toggleState(.inProgress)
    wait.tapRow(.task(3))
    try write("tasks_wait_filter.png", wait, 1440, 900)

    // Main: workspace を orbe に絞って打っている（入力欄の中のヒント・「を orbe のタスクに足す」）。
    let typing = DesignSceneFixtures.taskPaletteModel()
    typing.toggleWorkspaceFilter(DesignSceneFixtures.taskWorkspaces.opened.id)
    typing.query = "請求書を送る"
    try write("tasks_typing.png", typing, 1440, 900)

    // 絞り込みの面（workspace）を開き、orbe と work を入れた（札は「workspace: 2」）。
    let menu = DesignSceneFixtures.taskPaletteModel()
    menu.toggleFilterMenu(.workspace)
    menu.toggleWorkspaceFilter(DesignSceneFixtures.taskWorkspaces.all[0].id)
    menu.toggleWorkspaceFilter(DesignSceneFixtures.taskWorkspaces.all[1].id)
    try write("tasks_filter_menu.png", menu, 1440, 900)

    // 今年でない作成と期限（年が付いても月日と曜日まで列に収まる）。窓が狭くても同じ。
    let years = DesignSceneFixtures.taskPaletteModel(DesignSceneFixtures.taskYearDatesFile())
    try write("tasks_year_dates.png", years, 1440, 900)
    try write("tasks_year_dates_small.png", years, 800, 560)

    // 期限の列で並べた（近い順。期限なしは末尾）。
    let sorted = DesignSceneFixtures.taskPaletteModel()
    sorted.setSort(.due)
    try write("tasks_sorted_due.png", sorted, 1440, 900)

    // 完了の札を入れ、完了のタスクを選ぶ: 行が沈み、フッターに「⌘↵ agent を開く」が出る（未完了のタスクと同じ）。
    let doneSelected = DesignSceneFixtures.taskPaletteModel()
    doneSelected.toggleState(.done)
    doneSelected.tapRow(.task(8))
    try write("tasks_done_selected.png", doneSelected, 1440, 900)

    // 右の欄で完了まで巡る: 行は絞り込みに合わなくなっても残り、右の欄に居続ける。
    let cycled = DesignSceneFixtures.taskPaletteModel()
    cycled.enterDetail()
    cycled.changeValue(1)
    cycled.changeValue(1)
    try write("tasks_status_done_kept.png", cycled, 1440, 900)
  }
}

extension DesignGallerySnapshotTests {
  /// GitHub タブ（見本 XTGitHub1.png・XTGitHub2.png）と、選ぶ状態・使えないとき。
  func renderTaskPaletteGitHubSnapshots(
    _ write: (String, TaskPaletteModel, CGFloat, CGFloat) throws -> Void
  ) throws {
    let id = { (number: Int) in
      TaskPaletteGitHubRowID.item(GitHubItemID(repo: "nakatake/orbe", number: number)!)
    }
    // XTGitHub1: 結び付いていない #221 を選ぶ（右の欄に「自分をアサインする」・優先度・期限）。
    let unlinked = DesignSceneFixtures.taskPaletteModel()
    unlinked.setTab(unlinked.tab.next)
    unlinked.tapGitHubRow(id(221))
    try write("tasks_github.png", unlinked, 1440, 900)

    // XTGitHub2: 結び付いている #213 を選ぶ（結び付いているタスクと「#212 を開く」）。
    let linked = DesignSceneFixtures.taskPaletteModel()
    linked.setTab(linked.tab.next)
    linked.tapGitHubRow(id(213))
    try write("tasks_github_linked.png", linked, 1440, 900)

    // チーム宛だけのレビュー依頼の PR（「自分をレビュアーにする」）。右の欄の優先度に居る。
    let team = DesignSceneFixtures.taskPaletteModel()
    team.setTab(team.tab.next)
    team.tapGitHubRow(id(231))
    team.enterPane()
    team.movePaneStop(1)
    try write("tasks_github_reviewer.png", team, 1440, 900)

    // 「レビュー依頼」と「担当が自分」の札を入れる（どちらかに当たる項目）。
    let filtered = DesignSceneFixtures.taskPaletteModel()
    filtered.setTab(filtered.tab.next)
    filtered.toggleGitHubRelation(.reviewRequested)
    filtered.toggleGitHubRelation(.assigned)
    try write("tasks_github_review_requests.png", filtered, 1440, 900)

    // 「さらに」を開いた Issue の区分。
    let expanded = DesignSceneFixtures.taskPaletteModel()
    expanded.setTab(expanded.tab.next)
    expanded.expand(.issue)
    try write("tasks_github_expanded.png", expanded, 1440, 900)

    // ⌘L: #221 を結び付けるタスクを、タスクのタブで選ぶ。
    let pickTask = DesignSceneFixtures.taskPaletteModel()
    pickTask.setTab(pickTask.tab.next)
    pickTask.tapGitHubRow(id(221))
    pickTask.linkSelectedGitHubItem()
    pickTask.move(1)
    try write("tasks_github_pick_task.png", pickTask, 1440, 900)

    // 右の欄の「＋ 結び付ける」から、#212 に結び付ける項目を GitHub タブで選ぶ（#213 は付け替え）。
    let pickItem = DesignSceneFixtures.taskPaletteModel()
    pickItem.tapRow(.task(4))
    pickItem.enterDetail()
    pickItem.moveField(-1)
    pickItem.beginPickingItem()
    pickItem.tapGitHubRow(id(213))
    try write("tasks_github_pick_item.png", pickItem, 1440, 900)

    // gh が無い（前回の一覧も無い）。
    let missing = DesignSceneFixtures.taskPaletteModel(openLists: { viewer in
      GitHubOpenLists(
        roots: [
          DesignSceneFixtures.taskRoot: .init(resolution: .unavailable(.ghMissing), repo: nil)
        ], source: .idle, viewer: viewer)
    })
    missing.setTab(missing.tab.next)
    try write("tasks_github_unavailable.png", missing, 1440, 900)
  }
}

extension DesignGallerySnapshotTests {
  /// 待ちの条件（見本 SlWait.png・SlResolved.png）。見積もりのタスク（ID 3）を選ぶ。
  func renderTaskWaitConditionSnapshots(
    _ write: (String, TaskPaletteModel, CGFloat, CGFloat) throws -> Void
  ) throws {
    func model(_ file: TasksFile, tabs: AgentSessionTabs? = nil) -> TaskPaletteModel {
      let palette = DesignSceneFixtures.taskPaletteModel(
        file, sessionTabs: tabs ?? DesignSceneFixtures.taskSessionTabs())
      palette.tapRow(.task(3))
      return palette
    }
    // SlWait: 待っている間（会話のタブがある）。
    try write(
      "tasks_wait_condition.png", model(DesignSceneFixtures.taskWaitConditionFile()), 1440, 900)

    // 会話のタブが無い（「claude 2日前の会話」だけ）。実行の記録を開いている。
    let noTab = model(DesignSceneFixtures.taskWaitConditionFile(), tabs: AgentSessionTabs())
    noTab.toggleConditionPart(.log)
    try write("tasks_wait_condition_log.png", noTab, 1440, 900)

    // SlResolved: 解けた後。
    try write(
      "tasks_wait_resolved.png",
      model(
        DesignSceneFixtures.taskWaitConditionFile(
          resolved: .satisfied(output: DesignSceneFixtures.taskWaitOutput))), 1440, 900)

    // 期限が来た後。
    try write(
      "tasks_wait_expired.png",
      model(DesignSceneFixtures.taskWaitConditionFile(resolved: .expired)), 1440, 900)

    // 期限までにもう確かめない最後の間隔（「期限まで確認なし」）。
    try write(
      "tasks_wait_last_interval.png",
      model(
        DesignSceneFixtures.taskWaitConditionFile(
          deadline: DesignSceneFixtures.taskToday.addingTimeInterval(5 * 60))), 1440, 900)

    // 確認の出力の 1 行目が長い（行の札は上限幅で末尾を省略する）。作業ディレクトリが消えていて続きから始められない。
    let long = model(
      DesignSceneFixtures.taskWaitConditionFile(
        resolved: .satisfied(
          output: String(repeating: "@sato · CHANGES_REQUESTED · 長いレビューの要約 ", count: 8))))
    long.continuationBlock = { _ in .directoryMissing }
    try write("tasks_wait_resolved_blocked.png", long, 1440, 900)
  }
}
