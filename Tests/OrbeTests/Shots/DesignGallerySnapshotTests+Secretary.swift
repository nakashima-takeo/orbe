import SwiftUI
import XCTest

@testable import Orbe

/// ⌘⇧X の行き先の段・足した直後・行から秘書に頼む欄（見本 R3Ask.png・R3Added.png・R3RowAsk.png と同じ 1440×900）と、
/// 長いタイトル・長い補足・狭い窓の最悪条件。
extension DesignGallerySnapshotTests {
  func renderTaskSecretarySnapshots(
    _ write: (String, TaskPaletteModel, CGFloat, CGFloat) throws -> Void
  ) throws {
    // R3Ask: 入力欄に打つと行き先の段が出て、一致するタスクが下に並ぶ。
    let destination = DesignSceneFixtures.taskPaletteModel()
    destination.query = "見積もり"
    try write("tasks_destination.png", destination, 1440, 900)

    let longTitle = DesignSceneFixtures.taskPaletteModel()
    longTitle.setScope(.opened)
    longTitle.query = DesignSceneFixtures.taskSecretaryLongText
    try write("tasks_destination_long.png", longTitle, 1440, 900)

    // R3Added: ↵ で足した直後（未着手の中の先頭・今足した・範囲が「すべて」だった）。
    let added = DesignSceneFixtures.taskPaletteModel()
    added.query = "見積もりを山田さんに送る"
    added.submit()
    try write("tasks_added.png", added, 1440, 900)

    // R3RowAsk: #218 の行の直下に頼む欄。
    try write("tasks_row_ask.png", DesignSceneFixtures.taskRowAskModel("直して PR まで出して"), 1440, 900)
    try write(
      "tasks_row_ask_long.png",
      DesignSceneFixtures.taskRowAskModel(DesignSceneFixtures.taskSecretaryLongText), 1440, 900)

    // 頼んだ後（フッターの「秘書に頼んだ — 手が空いたら届く」）。
    let asked = DesignSceneFixtures.taskPaletteModel()
    asked.onAskSecretary = { _ in .success(.queued) }
    asked.query = "見積もりを山田さんに送る"
    asked.askSecretary()
    try write("tasks_asked.png", asked, 1440, 900)

    try write("tasks_destination_small.png", destination, 800, 560)
    try write(
      "tasks_row_ask_small.png", DesignSceneFixtures.taskRowAskModel("直して PR まで出して"), 800, 560)
  }
}

extension DesignSceneFixtures {
  static let taskSecretaryLongText =
    "見積もりの数字を経理に確認してから山田さんに送り、返事が来たら来週の定例の議題に足して、"
    + "決まったことを Slack の #sales に共有しておく"

  /// #218（Dispatch: fetch 待ちの間 Esc が効かない）を選んで、行の直下に頼む欄を開き、補足を打った状態。
  @MainActor
  static func taskRowAskModel(_ note: String) -> TaskPaletteModel {
    let palette = taskPaletteModel()
    palette.openAsk(9)
    palette.draftText = note
    return palette
  }
}
