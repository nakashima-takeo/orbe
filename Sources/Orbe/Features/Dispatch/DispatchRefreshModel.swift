import Foundation

/// 遅れたブランチの worktree の作り方。選択画面の 2 行と 1:1（0 = 最新化して作成・1 = そのまま作成）。
enum DispatchStaleChoice: Equatable {
  case refreshed, asIs
}

/// 最新化画面の相。選択・最新化中・作成中・失敗は**同じ 2 行の別の時点**で、View は保存フラグを持たない。
enum DispatchRefreshPhase: Equatable {
  case choosing
  /// fetch → fast-forward の途中。
  case updating
  /// worktree の作成中（そのまま作成／最新化の後）。
  case creating
  /// 最新化が落ちた。事実だけを持ち、文言は View が言語別に導く。
  case failed(GitRefreshFailure)
}

/// 最新化画面（Dispatch の第 3 のモード）の状態と操作の意味。**キーの意味を名前付きメソッドで持ち**、
/// 各メソッドが `phase` を見て自分で畳む（clean と同じ規約。テストはモデルを直接叩く）。
///
/// 一覧モードの旗 `isPreparing` とは別に busy を持つ——「最新化中」と「作成中」を一覧の旗に割ると、
/// 「そのまま作成」の作成中に選択画面のキーが効いてしまう。
@Observable final class DispatchRefreshModel {
  /// 入った行（「そのまま作成」の説明に `detail` を使う）。
  let item: DispatchItem
  /// 遅れの事実（表示は `upstream.short`、実行は `upstream` の remote / ref）。
  let sync: DispatchBranchSync
  private(set) var choice: DispatchStaleChoice = .refreshed
  private(set) var phase: DispatchRefreshPhase = .choosing

  init(item: DispatchItem, sync: DispatchBranchSync) {
    self.item = item
    self.sync = sync
  }

  /// 入力を受け付けない相（fetch は中断できないので、中断できる顔をしない）。
  var isBusy: Bool { phase == .updating || phase == .creating }

  var failure: GitRefreshFailure? {
    if case .failed(let failure) = phase { return failure }
    return nil
  }

  /// 2 行のトグル。busy では動かさない。
  func move(_ direction: Int) {
    guard !isBusy else { return }
    choice = choice == .refreshed ? .asIs : .refreshed
  }

  /// 行タップで選ぶ（決定はしない）。
  func choose(_ choice: DispatchStaleChoice) {
    guard !isBusy else { return }
    self.choice = choice
  }

  /// 選択・失敗 → 最新化中。カーソルは行 0 へ戻す（失敗画面の `r` からも同じ形で入る）。
  func beginUpdating() {
    choice = .refreshed
    phase = .updating
  }

  func beginCreating() {
    phase = .creating
  }

  /// 最新化が落ちた。行 0 が失敗を名乗り、カーソルは「そのまま作成」へ落ちる（⏎ 一つで前へ進める）。
  func fail(_ failure: GitRefreshFailure) {
    phase = .failed(failure)
    choice = .asIs
  }
}
