import SwiftUI
import XCTest

@testable import Orbe

/// ⌘⇧X の「agent に任せる」と行の「agent を開く」の flow（ファイル分割の拡張）。撮り方は `hostedTaskPaletteFlow`（窓に載せ、
/// 焦点を実物どおりに当てる）。
extension DesignFlowSnapshotTests {
  /// 打つ（入力欄の中にキーの案内が出る）→ ⌘↵ が断られる（claude が無い。打った文が残り、フッターに赤）→
  /// ↵（足した直後）→ #218 を選ぶ（フッターに「⌘↵ agent を開く」）→ 右の欄へ入る。
  func testTaskSecretary() throws {
    try secretaryFlow("task_secretary", size: NSSize(width: 1440, height: 900))
  }

  /// 狭い窓（SmallDetail と同じ大きさ）で、入力欄の中のヒントとフッターの切れ・重なり・はみ出しを見る。
  func testTaskSecretarySmall() throws {
    try secretaryFlow("task_secretary_small", size: NSSize(width: 800, height: 560))
  }

  private func secretaryFlow(_ name: String, size: NSSize) throws {
    let palette = DesignSceneFixtures.taskPaletteModel()
    palette.onAskSecretary = { _ in .claudeMissing }
    try hostedTaskPaletteFlow(
      name, palette, size: size,
      steps: [
        ("typed", { _ in palette.query = "見積もりを山田さんに送る" }),
        ("refused", { _ in palette.askWithQuery() }),
        ("added", { _ in palette.submit() }),
        ("row", { _ in palette.tapRow(.task(9)) }),
        ("detail", { _ in palette.enterDetail() }),
      ])
  }
}
