import Foundation

@testable import Orbe

/// 最新化シーン（design 正典 worktree パレットの「遅れ 選択 / 最新化中 / 最新化 失敗」）の fixture。
/// staleSample の `main`（`origin/main` より 12 遅れ）の行から本物の `enterRefresh` で入る。
extension DesignSceneFixtures {

  /// 最新化画面 1（選択）。カーソルは既定の「最新化して作成」。
  static func worktreePaletteRefreshModel() -> WorktreePaletteModel {
    let model = worktreePaletteModel(from: .staleSample)
    enterStaleMain(model)
    return model
  }

  /// 最新化画面 2（最新化中）。フッタが busy 表示に変わり、行は選択のまま。
  static func worktreePaletteRefreshUpdatingModel() -> WorktreePaletteModel {
    let model = worktreePaletteRefreshModel()
    model.refresh?.beginUpdating()
    return model
  }

  /// 最新化画面 3（失敗）。fetch で落ち、行 0 が失敗を名乗り、カーソルは「そのまま作成」へ落ちる。
  static func worktreePaletteRefreshFailedModel() -> WorktreePaletteModel {
    let model = worktreePaletteRefreshModel()
    model.refresh?.beginUpdating()
    model.refresh?.fail(.fetch(.reason("fatal: unable to access 'origin': Could not resolve host")))
    return model
  }

  /// staleSample の遅れた `main` 行を選んで最新化画面へ入る（判定は provider の仕事なので、
  /// fixture は行の同期と相対日時をそのまま渡す）。
  static func enterStaleMain(_ model: WorktreePaletteModel) {
    guard let index = model.items.firstIndex(where: { $0.sync?.isFastForwardable == true }),
      let sync = model.items[index].sync
    else { return }
    model.selected = index
    model.enterRefresh(sync: sync, relativeDate: model.items[index].detail ?? "")
  }
}
