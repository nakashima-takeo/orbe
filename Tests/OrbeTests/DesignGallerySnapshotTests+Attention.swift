import SwiftUI
import XCTest

@testable import Orbe

/// Attention（第10シーン: パレット / 第11シーン: メニューバー投影）のギャラリー。
/// visual-check が orbe_design の見本と突き合わせるピクセル入力。
extension DesignGallerySnapshotTests {

  /// design 正典 attentionSnapshot.tsx と同じ 6 行（working 2 / waiting 2 / done 2・新しい順）。
  private func attentionFixtureRows() -> [AttentionRow] {
    let now = Date()
    return [
      AttentionRow(
        paneId: 9006, workspaceName: "api-gateway", tabTitle: "deploy スクリプト整理",
        state: "waiting",
        message: "ビルド成果物の掃除方法を選んでください。1) rm -rf dist で全削除して作り直す 2) dist/legacy だけ残して選択削除 "
          + "3) 何もしない。CI キャッシュは 1) の場合のみ無効化が必要です。どれで進めますか？",
        stateChangedAt: now.addingTimeInterval(-45)),
      AttentionRow(
        paneId: 9005, workspaceName: "ghostty-fork", tabTitle: "renderer テスト追加",
        state: "working", message: nil, stateChangedAt: now.addingTimeInterval(-60)),
      AttentionRow(
        paneId: 9004, workspaceName: "orbe-core", tabTitle: "docs 同期", state: "done",
        message: "PR #142 を作成しました +18 −4。emit API の説明を README と docs/emit.md の両方に反映済み。",
        stateChangedAt: now.addingTimeInterval(-2 * 60)),
      AttentionRow(
        paneId: 9003, workspaceName: "orbe-core", tabTitle: "emit API 移行", state: "waiting",
        message: "Bash の許可が必要です — bin/rails db:migrate（スキーマに 2 テーブル追加）",
        stateChangedAt: now.addingTimeInterval(-3 * 60)),
      AttentionRow(
        paneId: 9002, workspaceName: "orbe-core", tabTitle: "emit API 移行", state: "working",
        message: nil, stateChangedAt: now.addingTimeInterval(-4 * 60)),
      AttentionRow(
        paneId: 9001, workspaceName: "orbe-remote-ios", tabTitle: "CI 修復", state: "done",
        message: "build OK — 変更なし", stateChangedAt: now.addingTimeInterval(-8 * 60)),
    ]
  }

  func renderAttentionSnapshots(dir: URL) throws {
    let stage = NSSize(width: 640, height: 520)

    // パレット（第10シーン同データ・overlay ごと・突合用）。
    let palette = AttentionPaletteModel(localization: LocalizationStore(language: .ja))
    palette.setRows(attentionFixtureRows())
    palette.render.selected = 0
    try writePNG(
      ZStack {
        BackgroundGlow()
        PaletteOverlay(model: palette.render)
      }.frame(width: stage.width, height: stage.height),
      size: stage, name: "attention_palette.png", dir: dir)

    // 空状態（情報行 1 本）。
    let empty = AttentionPaletteModel(localization: LocalizationStore(language: .ja))
    try writePNG(
      ZStack {
        BackgroundGlow()
        PaletteOverlay(model: empty.render)
      }.frame(width: stage.width, height: stage.height),
      size: stage, name: "attention_palette_empty.png", dir: dir)

    // メニューバーアイテムの 4 態（①静か ②滲み出し ③収縮 ④ドロップダウン中）を縦に並べる。
    let rows = attentionFixtureRows()
    let quietStore = AttentionStore()
    let transientStore = AttentionStore()
    transientStore.rows = rows
    transientStore.noteTransient(rows[3])  // "Bash の許可が必要です…" の waiting
    let countStore = AttentionStore()
    countStore.rows = rows
    let openUI = MenuBarUIState()
    openUI.dropdownOpen = true
    let strip = VStack(alignment: .trailing, spacing: Theme.Space.beat) {
      MenuBarStatusView(store: quietStore, ui: MenuBarUIState())
      MenuBarStatusView(store: transientStore, ui: MenuBarUIState())
      MenuBarStatusView(store: countStore, ui: MenuBarUIState())
      MenuBarStatusView(store: countStore, ui: openUI)
    }
    .padding(Theme.Space.bar)
    .background(Color.theme.bgBase)
    try writePNG(
      strip, size: NSSize(width: 420, height: 180), name: "menubar_states.png", dir: dir)

    // ドロップダウン（第11シーン④・幅 420・working 集約・フッター・権限ヒントなし/あり）。
    let store = AttentionStore()
    store.rows = rows
    for (name, granted) in [("menubar_dropdown.png", true), ("menubar_dropdown_hint.png", false)] {
      try writePNG(
        MenuBarDropdownView(
          store: store, localization: LocalizationStore(language: .ja),
          permissionGranted: granted,
          onSelectRow: { _ in }, onOpenOrbe: {}, onPermissionHint: {}
        )
        .padding(Theme.Space.phrase)
        .background(Color.theme.bgSunken),
        size: NSSize(width: 470, height: 520), name: name, dir: dir)
    }
  }
}
