import Foundation

/// clean の 3 画面で意味の変わるキーの畳み方（モードの出入りそのものは `DispatchPalette.swift`）。
/// **画面ごとの分岐は View に置かない**——キーの意味は名前付きメソッドが持ち、各メソッドが
/// `clean.phase` を見て自分で畳む（View の `.onKeyPress` は 1 行のアダプタに保つ）。
extension DispatchPaletteModel {

  /// clean の ⌘⏎ の唯一の funnel（キーと実行ボタンが共に通る）。0 件・実行中は無反応。
  func executeClean() {
    guard clean.canExecute else { return }
    let requests = clean.requests()
    onCleanExecute(requests, clean.beginRun(requests))
  }

  /// clean の ⏎。選択画面ではチェックの切替、一部失敗画面では失敗分の再試行、削除中は無反応。
  func confirmClean() {
    switch clean.phase {
    case .selecting:
      clean.toggleAtCursor()
    case .deleting:
      break
    case .failed:
      let requests = clean.retryRequests()
      guard !requests.isEmpty, let token = clean.runToken else { return }
      onCleanExecute(requests, token)
    }
  }

  /// clean の esc。選択画面では一覧へ戻り、削除中は中断し、一部失敗画面ではパレットを閉じる。
  func exitOrCancelClean() {
    switch clean.phase {
    case .selecting: exitClean()
    case .deleting: clean.cancelRun()
    case .failed: onDismiss()
    }
  }

  /// clean の `o`。一部失敗画面のカーソルが指す失敗行の worktree をタブで開く。
  func openCleanFailure() {
    guard clean.phase == .failed, let path = clean.failureTargetPath else { return }
    onOpenWorktree(path)
  }

  /// 削除の駆動が終わった（中断も同じ終端を通る）。**失敗が 1 件も無ければ clean を抜けて一覧へ戻る**——
  /// 削除の結果は Worktrees セクションと `候補 N 件` バッジの形で一覧に出る。失敗があれば
  /// 一部失敗画面に留まり、成功行を消さないまま再試行と対処を出す。
  func settleCleanRun() {
    guard clean.failedCount == 0 else { return }
    clean.endRun()
    exitClean()
  }
}
