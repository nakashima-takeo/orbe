import Foundation

/// 預かった ↵ の決め方。
enum WorktreePalettePendingActivation: Equatable {
  /// 行が決まった時点の選択で実行する（初回の一覧・先頭の欄の待ち）。
  case selection
  /// 打った名前を作る意図。作成行を出すかが決まったら、作成行が残っていれば作り、消えて同じ名前のリモート
  /// ブランチの行が現れていればそれを開き、どちらも無ければ何もしない——決まった後の一覧で選択を組み直すと、
  /// 名前の一部が一致するだけの別の行を開いてしまう。
  case create(name: String)
}

/// ↵ の決定と預かり。
extension WorktreePaletteModel {
  /// ↵ による決定。行がまだ決まらない間（`isSettled` が偽）は ↵ を預かり、決まった時点で実行する
  /// （`settlePendingActivation`）——開いた直後や名前を打った直後の ↵ を空振りさせない。
  func activate() {
    guard mode == .list, !isLocked else { return }
    guard isSettled else {
      pendingActivation = .selection
      return settlePendingActivation()
    }
    activate(at: selected)
  }

  /// 行が決まっているか。決まっていないのは、初回の一覧が届く前と、先頭の欄がまだ決まらない間と、作成行を
  /// 出すかが決まらないまま作成行（または行が 1 つも無い状態）を選んでいるとき。
  var isSettled: Bool {
    guard hasLoadedOnce, !taskTargetPending else { return false }
    guard isCreateRowUndecided else { return true }
    switch selectedItem?.action {
    case .createBranch, nil: return false
    case .open, .clean: return true
    }
  }

  /// 預かりが今の入力のリモートブランチを待っている（提示時の fetch の着地待ち）。
  var isAwaitingRemoteBranches: Bool {
    guard case .create = pendingActivation else { return false }
    return newBranchRules?.remoteBranchesLanded == false
  }

  /// 預かった ↵ を、決まっていれば実行する。データの到着と有効性の答えの後に呼ぶ。選択で預かった ↵ は、残る
  /// 待ちが作成行を出すかだけになった時点で、打った名前を作る意図に置き換える（作成行か何も無い行を選んで
  /// いる）。
  func settlePendingActivation() {
    switch pendingActivation {
    case nil:
      return
    case .selection:
      guard hasLoadedOnce, !taskTargetPending else { return }
      guard isSettled else { return pendingActivation = .create(name: query) }
      pendingActivation = nil
      guard !items.isEmpty else { return }
      activate(at: selected)
    case .create(let name):
      guard !isCreateRowUndecided else { return }
      pendingActivation = nil
      let index =
        items.firstIndex { $0.action == .createBranch(name: name) }
        ?? items.firstIndex { item in
          guard case .open(.remoteBranch(let remote, _)) = item.action else { return false }
          return GitBranch.localName(fromRemote: remote) == name
        }
      if let index { activate(at: index) }
    }
  }
}
