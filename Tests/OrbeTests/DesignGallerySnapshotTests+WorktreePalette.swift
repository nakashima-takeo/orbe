import SwiftUI
import XCTest

@testable import Orbe

/// worktree パレットの gallery（list の各状態と clean の 3 画面。ファイル分割の拡張）。
extension DesignGallerySnapshotTests {
  /// worktree パレット（実データ形の決定的サンプル・overlay ごと・突合用）。
  /// 多件数は通常/低い窓（360）で cap＋内部スクロール、狭幅（360）で truncate を検証する。
  func renderWorktreePaletteSnapshots(dir: URL) throws {
    func write(_ n: String, _ m: WorktreePaletteModel, _ w: CGFloat = 640, _ h: CGFloat = 520)
      throws
    { try writeWorktreePalette(n, m, w, h, dir: dir) }
    // design 正典（XTWorktree / XTBranch / XTNew）と同じカード幅 720 で並べる。
    try write("worktree_palette_design.png", DesignSceneFixtures.worktreePaletteModel(), 752)
    try write(
      "worktree_palette_branch.png", DesignSceneFixtures.worktreePaletteBranchModel(), 752)
    try write(
      "worktree_palette_new_branch.png", DesignSceneFixtures.worktreePaletteNewBranchModel(), 752)
    try write(
      "worktree_palette_base_picker.png", DesignSceneFixtures.worktreePaletteBasePickerModel(),
      752)
    try write(
      "worktree_palette_directory.png", DesignSceneFixtures.worktreePaletteDirectoryModel(), 752)
    // 狭い窓でもベースの選択肢がカードからはみ出さない（名前が縮む）。
    try write(
      "worktree_palette_new_branch_narrow.png",
      DesignSceneFixtures.worktreePaletteNewBranchModel(), 480)
    try write(
      "worktree_palette_preparing.png", DesignSceneFixtures.worktreePalettePreparingModel())
    try write(
      "worktree_palette_skeleton.png", DesignSceneFixtures.worktreePaletteSkeletonModel())
    try write(
      "worktree_palette_filtered.png", DesignSceneFixtures.worktreePaletteFilteredModel())
    try write("worktree_palette_many.png", DesignSceneFixtures.worktreePaletteManyModel())
    try write(
      "worktree_palette_many_short.png", DesignSceneFixtures.worktreePaletteManyModel(), 640, 360)
    try write(
      "worktree_palette_narrow.png", DesignSceneFixtures.worktreePaletteManyModel(), 360, 520)
    try renderWorktreeCleanSnapshots(dir: dir)
  }

  /// clean と最新化の画面。
  private func renderWorktreeCleanSnapshots(dir: URL) throws {
    func write(_ n: String, _ m: WorktreePaletteModel, _ w: CGFloat = 640, _ h: CGFloat = 520)
      throws
    { try writeWorktreePalette(n, m, w, h, dir: dir) }
    // clean の 3 画面: 入口の行を選んだ list ＋ 選択（既定 / 0 件 / サブライン）/ 削除中 / 一部失敗。
    try write("worktree_clean_row.png", DesignSceneFixtures.worktreeCleanRowModel())
    try write("worktree_clean.png", DesignSceneFixtures.worktreeCleanModel())
    try write("worktree_clean_empty.png", DesignSceneFixtures.worktreeCleanEmptyModel())
    // 行ごとの準備完了の途中経過（未確定行は回転グリフ・確定した安全行だけチェックが灯る）。
    try write(
      "worktree_clean_pending.png", DesignSceneFixtures.worktreeCleanPendingModel())
    try write(
      "worktree_clean_subline.png", DesignSceneFixtures.worktreeCleanSublineModel())
    // ピルが 3 枚競合して溢れた語がサブラインへ回る行（`locked` が消えていないことの証拠）。
    try write(
      "worktree_clean_overflow.png", DesignSceneFixtures.worktreeCleanOverflowModel())
    try write(
      "worktree_clean_deleting.png", DesignSceneFixtures.worktreeCleanDeletingModel())
    try write(
      "worktree_clean_failure.png", DesignSceneFixtures.worktreeCleanFailureModel())
    // 右クラスタが 2 枚のピルで最も詰まる画面なので、狭窓の証拠を残す。
    try write("worktree_clean_narrow.png", DesignSceneFixtures.worktreeCleanModel(), 360, 520)
    // 最新化の 3 画面: 選択（既定）/ 最新化中（busy フッタ）/ 失敗（行 0 が失敗・カーソルは行 1）。
    try write(
      "worktree_palette_refresh.png", DesignSceneFixtures.worktreePaletteRefreshModel())
    try write(
      "worktree_palette_refresh_updating.png",
      DesignSceneFixtures.worktreePaletteRefreshUpdatingModel())
    try write(
      "worktree_palette_refresh_failed.png",
      DesignSceneFixtures.worktreePaletteRefreshFailedModel())
  }

  private func writeWorktreePalette(
    _ name: String, _ model: WorktreePaletteModel, _ w: CGFloat, _ h: CGFloat, dir: URL
  ) throws {
    try writePNG(
      ZStack {
        BackgroundGlow()
        WorktreePaletteOverlay(model: model)
      }.frame(width: w, height: h),
      size: NSSize(width: w, height: h), name: name, dir: dir)
  }
}
