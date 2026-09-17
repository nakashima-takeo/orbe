import Foundation

/// 最新化画面で意味の変わるキーの畳み方（モードの出入りそのものは `DispatchPalette.swift`）。
/// clean と同じく、画面ごとの分岐は View に置かず名前付きメソッドが `refresh.phase` を見て自分で畳む。
extension DispatchPaletteModel {

  /// 最新化画面の ⏎。カーソルの行を実行する。busy は無反応。
  func confirmRefresh() {
    guard let refresh, !refresh.isBusy else { return }
    switch refresh.choice {
    case .refreshed:
      startRefresh()
    case .asIs:
      refresh.beginCreating()
      onSettleStale(.asIs, refresh.sync)
    }
  }

  /// 最新化画面の行タップ＝決定。一覧の行タップと同じく、選択移動と実行が一体で走る。busy は無反応。
  func confirmRefresh(_ choice: DispatchStaleChoice) {
    guard let refresh, !refresh.isBusy else { return }
    refresh.choose(choice)
    confirmRefresh()
  }

  /// 「最新化して作成」を撃つ唯一の funnel（⏎・行 0 のタップ・`r` が共に通る）。busy は無反応。
  func startRefresh() {
    guard let refresh, !refresh.isBusy else { return }
    refresh.beginUpdating()
    onSettleStale(.refreshed, refresh.sync)
  }

  /// 最新化画面の `r`。失敗画面でだけ効く。
  func retryRefresh() {
    guard refresh?.failure != nil else { return }
    startRefresh()
  }
}
