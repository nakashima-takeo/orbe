import SwiftUI
import XCTest

@testable import Orbe

/// ⌘⇧X の入力の行き先（入力欄の中のヒント）・足した直後（1440×900）と、長いタイトル・狭い窓の最悪条件。
extension DesignGallerySnapshotTests {
  func renderTaskSecretarySnapshots(
    _ write: (String, TaskPaletteModel, CGFloat, CGFloat) throws -> Void
  ) throws {
    // 入力欄に打つと、入力欄の中に「↵ タスクに追加」「⌘↵ agent に任せる」が出て、一致するタスクが表に並ぶ。
    let destination = DesignSceneFixtures.taskPaletteModel()
    destination.query = "見積もり"
    try write("tasks_destination.png", destination, 1440, 900)

    let longTitle = DesignSceneFixtures.taskPaletteModel()
    longTitle.toggleWorkspaceFilter(DesignSceneFixtures.taskWorkspaces.opened.id)
    longTitle.query = DesignSceneFixtures.taskSecretaryLongText
    try write("tasks_destination_long.png", longTitle, 1440, 900)

    // ↵ で足した直後（右の欄の見出しが「タスク · 今 ⌘⇧X から足した」）。
    let added = DesignSceneFixtures.taskPaletteModel()
    added.query = "見積もりを山田さんに送る"
    added.submit()
    try write("tasks_added.png", added, 1440, 900)

    try write("tasks_destination_small.png", destination, 800, 560)
  }
}

extension DesignSceneFixtures {
  static let taskSecretaryLongText =
    "見積もりの数字を経理に確認してから山田さんに送り、返事が来たら来週の定例の議題に足して、"
    + "決まったことを Slack の #sales に共有しておく"
}
