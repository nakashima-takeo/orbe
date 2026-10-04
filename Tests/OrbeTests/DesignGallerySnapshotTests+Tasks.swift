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

    let github = DesignSceneFixtures.taskPaletteModel()
    github.toggleTab()
    try write("tasks_github.png", github)

    try write(
      "tasks_empty.png",
      DesignSceneFixtures.taskPaletteModel(
        TasksFile(version: TaskPersistence.version, nextId: 1, tasks: [])))

    // 小さい窓: カードは窓に収まり、詳細の欄はカードの 1/3 で一緒に縮む。
    try write("tasks_small.png", DesignSceneFixtures.taskPaletteModel(), 800, 560)
  }
}
