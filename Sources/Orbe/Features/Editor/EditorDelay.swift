import Foundation

/// 遅らせて 1 回だけ走らせる予約。置き直すと前の予約は捨てる。時計は `schedule` で差し替えられる（既定は main queue。
/// テストは手動で進める——`SettingsPaletteModel.schedulePreviewEnd` と同じ流儀）。
@MainActor
final class EditorDelay {
  var schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, fire in
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(fire) }
  }
  private var generation = 0

  /// 予約があるか。
  private(set) var isPending = false

  func run(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) {
    generation += 1
    let current = generation
    isPending = true
    schedule(delay) { [weak self] in
      guard let self, generation == current else { return }
      isPending = false
      action()
    }
  }

  func cancel() {
    generation += 1
    isPending = false
  }
}
