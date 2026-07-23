import SwiftUI
import XCTest

@testable import Orbe

/// ⌘H ヘルプオーバーレイの gallery（design 正典 CmdHelp / Cmd_H_Help.dc.html 突合用）。
/// ステージは design 原典と同寸 920×720（モーダル上限 760×656 が原寸で出る）。
/// トップ / 一覧（すべて）/ 検索絞り込み / キー絞り込み＋実押下点灯を撮る（ファイル分割の拡張）。
extension DesignGallerySnapshotTests {
  func renderHelpSnapshots(dir: URL) throws {
    func write(
      _ name: String, _ model: HelpModel, stage: NSSize = NSSize(width: 920, height: 720)
    ) throws {
      try writePNG(
        ZStack {
          BackgroundGlow()
          HelpOverlay(model: model)
        }
        .frame(width: stage.width, height: stage.height)
        .environment(\.localization, LocalizationStore(language: .ja)),
        size: stage, name: name, dir: dir)
    }

    // トップビュー（基本操作＋凡例）。
    try write("help_top.png", HelpModel())

    // 一覧ビュー（すべて・29 行）。
    let all = HelpModel()
    all.category = .all
    try write("help_list.png", all)

    // 検索絞り込み（「基本操作」のまま一覧へ自動遷移するケース）。
    let search = HelpModel()
    search.query = "タブ"
    try write("help_search.png", search)

    // キー絞り込み（T 選択）＋実押下（⌘⇧）点灯＝キーボード可視化の 3 種の光り方を 1 枚に。
    let lit = HelpModel()
    lit.fkey = "t"
    lit.pressed = ["cmd", "shift"]
    try write("help_keyboard_lit.png", lit)

    // 縮小域（パネルが 760×656 を下回る小窓）。design 見本は未定義＝Orbe 設計の縮小挙動を検証する。
    let small = HelpModel()
    small.category = .all
    try write("help_small.png", small, stage: NSSize(width: 640, height: 520))
    try write("help_tiny.png", HelpModel(), stage: NSSize(width: 420, height: 360))
  }
}
