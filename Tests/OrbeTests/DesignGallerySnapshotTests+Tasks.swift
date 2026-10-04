import SwiftUI
import XCTest

@testable import Orbe

/// タスク画面の gallery（見本 XTTasks.png と同じ 1440×900 の窓で、overlay ごと撮る）。
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
    try write("tasks_design.png", DesignSceneFixtures.taskPaletteModel())

    let detail = DesignSceneFixtures.taskPaletteModel()
    detail.move(1)
    detail.move(1)
    detail.enterDetail()
    detail.moveField(1)
    try write("tasks_detail.png", detail)

    // 詳細の agent の場所に居る（「claude が取り掛かっている」とフッターの「↵ issue-212 へ移る」）。
    let agent = DesignSceneFixtures.taskPaletteModel()
    agent.enterDetail()
    agent.moveField(-1)
    agent.moveField(-1)
    agent.moveField(-1)
    try write("tasks_detail_agent.png", agent)

    // 詳細の Issue・PR の欄の行に居る（「外す」とフッターの「↵ #213 を GitHub で開く」）。
    let link = DesignSceneFixtures.taskPaletteModel()
    link.enterDetail()
    link.moveField(-1)
    try write("tasks_detail_link.png", link)

    let filtered = DesignSceneFixtures.taskPaletteModel()
    filtered.query = "経"
    try write("tasks_filtered.png", filtered)

    let expanded = DesignSceneFixtures.taskPaletteModel()
    expanded.jump(1)
    expanded.submit()
    try write("tasks_done_expanded.png", expanded)

    // 詳細の「＋ 結び付ける」に居る（右に「ブランチの PR は自動」）。
    let addLink = DesignSceneFixtures.taskPaletteModel()
    addLink.enterDetail()
    addLink.moveField(-1)
    try write("tasks_detail_add_link.png", addLink)

    try renderTaskPaletteGitHubSnapshots(write)

    try write(
      "tasks_empty.png",
      DesignSceneFixtures.taskPaletteModel(
        TasksFile(version: TaskPersistence.version, nextId: 1, tasks: [])))

    // 小さい窓: カードは窓に収まり、詳細の欄はカードの 1/3 で一緒に縮む。
    try write("tasks_small.png", DesignSceneFixtures.taskPaletteModel(), 800, 560)
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
    unlinked.toggleTab()
    unlinked.tapGitHubRow(id(221))
    try write("tasks_github.png", unlinked, 1440, 900)

    // XTGitHub2: 結び付いている #213 を選ぶ（結び付いているタスクと「#212 を開く」）。
    let linked = DesignSceneFixtures.taskPaletteModel()
    linked.toggleTab()
    linked.tapGitHubRow(id(213))
    try write("tasks_github_linked.png", linked, 1440, 900)

    // チーム宛だけのレビュー依頼の PR（「自分をレビュアーにする」）。右の欄の優先度に居る。
    let team = DesignSceneFixtures.taskPaletteModel()
    team.toggleTab()
    team.tapGitHubRow(id(231))
    team.enterPane()
    team.movePaneStop(1)
    try write("tasks_github_reviewer.png", team, 1440, 900)

    // ⇥ で「レビュー依頼」に絞る。
    let filtered = DesignSceneFixtures.taskPaletteModel()
    filtered.toggleTab()
    filtered.cycleGitHubFilter()
    filtered.cycleGitHubFilter()
    filtered.cycleGitHubFilter()
    try write("tasks_github_review_requests.png", filtered, 1440, 900)

    // 「さらに」を開いた Issue の区分。
    let expanded = DesignSceneFixtures.taskPaletteModel()
    expanded.toggleTab()
    expanded.expand(.issue)
    try write("tasks_github_expanded.png", expanded, 1440, 900)

    // ⌘L: #221 を結び付けるタスクを、タスクのタブで選ぶ。
    let pickTask = DesignSceneFixtures.taskPaletteModel()
    pickTask.toggleTab()
    pickTask.tapGitHubRow(id(221))
    pickTask.linkSelectedGitHubItem()
    pickTask.move(1)
    try write("tasks_github_pick_task.png", pickTask, 1440, 900)

    // 詳細の「＋ 結び付ける」から、#212 に結び付ける項目を GitHub タブで選ぶ（#213 は付け替え）。
    let pickItem = DesignSceneFixtures.taskPaletteModel()
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
    missing.toggleTab()
    try write("tasks_github_unavailable.png", missing, 1440, 900)
  }
}
