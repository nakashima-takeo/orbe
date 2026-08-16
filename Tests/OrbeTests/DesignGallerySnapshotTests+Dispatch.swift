import SwiftUI
import XCTest

@testable import Orbe

/// Dispatch パレットの gallery（list の各状態と clean の 3 画面。ファイル分割の拡張）。
extension DesignGallerySnapshotTests {
  /// Dispatch パレット（実データ形の決定的サンプル・overlay ごと・突合用）。
  /// 多件数は通常/低い窓（360）で cap＋内部スクロール、狭幅（360）で truncate を検証する。
  func renderDispatchSnapshots(dir: URL) throws {
    func write(_ name: String, _ model: DispatchPaletteModel, _ w: CGFloat, _ h: CGFloat) throws {
      try writePNG(
        ZStack {
          BackgroundGlow()
          DispatchOverlay(model: model)
        }.frame(width: w, height: h),
        size: NSSize(width: w, height: h), name: name, dir: dir)
    }
    try write("dispatch_design.png", DesignSceneFixtures.dispatchModel(), 640, 520)
    try write("dispatch_preparing.png", DesignSceneFixtures.dispatchPreparingModel(), 640, 520)
    try write("dispatch_skeleton.png", DesignSceneFixtures.dispatchSkeletonModel(), 640, 520)
    try write("dispatch_loading.png", DesignSceneFixtures.dispatchLoadingModel(), 640, 520)
    try write("dispatch_gh_missing.png", DesignSceneFixtures.dispatchGhMissingModel(), 640, 520)
    try write("dispatch_filtered.png", DesignSceneFixtures.dispatchFilteredModel(), 640, 520)
    try write("dispatch_many.png", DesignSceneFixtures.dispatchManyModel(), 640, 520)
    try write("dispatch_many_short.png", DesignSceneFixtures.dispatchManyModel(), 640, 360)
    try write("dispatch_narrow.png", DesignSceneFixtures.dispatchManyModel(), 360, 520)
    // clean の 3 画面: 入口の行を選んだ list ＋ 選択（既定 / 0 件 / サブライン）/ 削除中 / 一部失敗。
    try write("dispatch_clean_row.png", DesignSceneFixtures.dispatchCleanRowModel(), 640, 520)
    try write("dispatch_clean.png", DesignSceneFixtures.dispatchCleanModel(), 640, 520)
    try write("dispatch_clean_empty.png", DesignSceneFixtures.dispatchCleanEmptyModel(), 640, 520)
    // 行ごとの準備完了の途中経過（未確定行は回転グリフ・確定した安全行だけチェックが灯る）。
    try write(
      "dispatch_clean_pending.png", DesignSceneFixtures.dispatchCleanPendingModel(), 640, 520)
    try write(
      "dispatch_clean_subline.png", DesignSceneFixtures.dispatchCleanSublineModel(), 640, 520)
    // ピルが 3 枚競合して溢れた語がサブラインへ回る行（`locked` が消えていないことの証拠）。
    try write(
      "dispatch_clean_overflow.png", DesignSceneFixtures.dispatchCleanOverflowModel(), 640, 520)
    try write(
      "dispatch_clean_deleting.png", DesignSceneFixtures.dispatchCleanDeletingModel(), 640, 520)
    try write(
      "dispatch_clean_failure.png", DesignSceneFixtures.dispatchCleanFailureModel(), 640, 520)
    // 右クラスタが 2 枚のピルで最も詰まる画面なので、狭窓の証拠を残す。
    try write("dispatch_clean_narrow.png", DesignSceneFixtures.dispatchCleanModel(), 360, 520)
  }
}
