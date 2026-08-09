import Foundation

/// 行ごとの選択状態。safe 行は `.none` / `.worktreeOnly` の 2 値だけを取り、ブランチを消すかは
/// フッタのトグルが決める。caution 行だけ 3 値すべてを巡回する。
enum CleanSelection: Equatable {
  case none, worktreeOnly, worktreeAndBranch
}

/// 削除 1 件の依頼。ブランチを消すかの**判断**は `DispatchCleanModel.deletesBranch(_:)` だけが持ち、
/// 実行側は渡されたとおりに実行する（判断と実行を分ける）。
struct CleanDeleteRequest: Equatable {
  let path: String
  let branch: String?
  let deleteBranch: Bool
}

/// clean 画面の状態と操作の意味。**キーの意味を名前付きメソッドで持ち**、View の `.onKeyPress` は
/// 1 行のアダプタにする（このコードベースの規約。テストはモデルを直接叩く）。
///
/// 行の一覧は `enter(rows:)` で凍結する。破壊的な複数選択 UI で、カーソルの下のリストが後から届いた
/// データで組み替わることを構造で禁じるため、裏の分類更新はこの画面に届かない。
@Observable final class DispatchCleanModel {
  /// 群順（safe → caution → inUse）に並んだ凍結スナップショット。
  private(set) var rows: [CleanRow] = []
  /// `selectableRows` を数えたカーソル。
  private(set) var cursor = 0
  /// 行 id → 選択状態（`.none` は持たない）。
  private(set) var selection: [String: CleanSelection] = [:]
  /// フッタのトグル。**safe 行にだけ効く**（caution 行は行ごとの状態が決める）。
  var deleteBranch = true
  /// 削除実行中（キー入力を一切受け付けない）。
  var isDeleting = false
  /// 集約した失敗理由（フッタに赤で出す）。
  var errorMessage: String?

  /// カーソル巡回・選択の対象（inUse 行は飛ばす）。
  var selectableRows: [CleanRow] { rows.filter { $0.group != .inUse } }

  /// 分類スナップショットで画面を開く。safe 群を全チェック・caution 行は未選択・カーソルは先頭。
  func enter(rows: [CleanRow]) {
    self.rows = rows
    cursor = 0
    selection = [:]
    deleteBranch = true
    isDeleting = false
    errorMessage = nil
    for row in rows where row.group == .safe { selection[row.id] = .worktreeOnly }
  }

  /// 行の選択状態（未選択は `.none`）。
  func state(of row: CleanRow) -> CleanSelection { selection[row.id] ?? .none }

  /// カーソル行（範囲外なら nil）。
  var cursorRow: CleanRow? {
    let rows = selectableRows
    return rows.indices.contains(cursor) ? rows[cursor] : nil
  }

  /// 選択可能行を wrap 巡回する。削除実行中は受け付けない（以下の操作すべてに同じ関門が掛かる）。
  func move(_ direction: Int) {
    guard !isDeleting else { return }
    let count = selectableRows.count
    guard count > 0 else { return }
    cursor = (cursor + direction + count) % count
  }

  /// カーソル行の状態を 1 つ進める。
  func advance() {
    guard !isDeleting, let row = cursorRow else { return }
    apply(next(after: state(of: row), in: row.group), to: row.id)
  }

  /// 指定行の状態を 1 つ進め、**カーソルもその行へ移す**
  /// （ハイライト＝カーソル＝次に space/⏎ が効く行、を崩さない）。
  func advance(at rowID: String) {
    let rows = selectableRows
    guard !isDeleting, let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
    cursor = index
    apply(next(after: state(of: rows[index]), in: rows[index].group), to: rowID)
  }

  /// safe 群を全選択する（**トグルではない・追加のみ**。既に付いている状態を落とさない）。
  func selectAllSafe() {
    guard !isDeleting else { return }
    for row in rows where row.group == .safe && state(of: row) == .none {
      selection[row.id] = .worktreeOnly
    }
  }

  /// 選択件数。`.worktreeOnly` も `.worktreeAndBranch` も 1 件として数える。
  var selectedCount: Int { selection.values.filter { $0 != .none }.count }

  var canExecute: Bool { selectedCount > 0 && !isDeleting }

  /// この行でローカルブランチも消すか。safe 行はフッタのトグル、caution 行は行ごとの状態が決める。
  /// **caution 行の `.worktreeAndBranch` は、取り込まれていない独自コミットごとブランチを消す。**
  /// フッタのトグル 1 つでそれが起きることは無く、その行で 2 回選択して行末に警告色の
  /// `worktree + ブランチ` が出ている状態を見たうえでしか到達できない——**この状態を選ぶ行為そのものが
  /// 安全確認の上書きである**（判断はユーザーに残しつつ、勢いでは消えない）。
  func deletesBranch(_ row: CleanRow) -> Bool {
    switch row.group {
    case .safe: return deleteBranch
    case .caution: return state(of: row) == .worktreeAndBranch
    case .inUse: return false
    }
  }

  /// 実行の依頼一覧（選択された行だけ・スナップショットの並び順）。
  func requests() -> [CleanDeleteRequest] {
    rows.filter { state(of: $0) != .none }.map {
      CleanDeleteRequest(path: $0.id, branch: $0.branch, deleteBranch: deletesBranch($0))
    }
  }

  /// 一部が失敗した後の据わり直し。成功した行をスナップショットから取り除き、選択は全解除、
  /// カーソルは範囲内へクランプする。**分類の再計算はしない**——残った行の状況は変わっておらず、
  /// カーソルの下でリストを組み替えないため。
  func applyPartialFailure(succeededPaths: [String], message: String) {
    let succeeded = Set(succeededPaths)
    rows.removeAll { succeeded.contains($0.id) }
    selection = [:]
    cursor = min(cursor, max(0, selectableRows.count - 1))
    isDeleting = false
    errorMessage = message
  }

  private func apply(_ selection: CleanSelection, to rowID: String) {
    if selection == .none {
      self.selection.removeValue(forKey: rowID)
    } else {
      self.selection[rowID] = selection
    }
  }

  /// safe 行は `.none ⇄ .worktreeOnly`、caution 行は `.none → .worktreeOnly → .worktreeAndBranch → .none`。
  private func next(after current: CleanSelection, in group: CleanGroup) -> CleanSelection {
    switch (group, current) {
    case (.safe, .none): return .worktreeOnly
    case (.safe, _): return .none
    case (.caution, .none): return .worktreeOnly
    case (.caution, .worktreeOnly): return .worktreeAndBranch
    case (.caution, .worktreeAndBranch): return .none
    case (.inUse, _): return .none
    }
  }
}
