import SwiftUI
import XCTest

@testable import Orbe

/// ⌘⇧X から秘書に頼む flow（ファイル分割の拡張）。撮り方は `hostedTaskPaletteFlow`（窓に載せ、焦点を実物どおりに当てる）。
extension DesignFlowSnapshotTests {
  /// 打つ（行き先の段が出る）→ ↵（足した直後）→ #218 を選んで ⌘↵（行の直下に頼む欄）→ 補足を打つ → ↵（欄が閉じ、
  /// フッターに「秘書に頼んだ」）。
  func testTaskSecretary() throws {
    try secretaryFlow("task_secretary", size: NSSize(width: 1440, height: 900))
  }

  /// 狭い窓（SmallDetail と同じ大きさ）で、段と欄の切れ・重なり・はみ出しを見る。
  func testTaskSecretarySmall() throws {
    try secretaryFlow("task_secretary_small", size: NSSize(width: 800, height: 560))
  }

  private func secretaryFlow(_ name: String, size: NSSize) throws {
    let palette = DesignSceneFixtures.taskPaletteModel()
    palette.onAskSecretary = { _ in .success(.accepted) }
    try hostedTaskPaletteFlow(
      name, palette, size: size,
      steps: [
        ("typed", { _ in palette.query = "見積もりを山田さんに送る" }),
        ("added", { _ in palette.submit() }),
        (
          "row_ask",
          { _ in
            palette.tapRow(.task(9))
            palette.askSecretary()
          }
        ),
        ("note", { _ in palette.draftText = "直して PR まで出して" }),
        ("asked", { _ in palette.sendAsk() }),
      ])
  }
}
