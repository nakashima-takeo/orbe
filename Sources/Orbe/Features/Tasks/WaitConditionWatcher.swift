import Foundation
import Observation

/// 待ちの条件の係（窓に 1 つ）。ストアを観測して、条件を持って待っているタスクを番人に登録し、確認のコマンドを回して、
/// 結果をストアの変異として書き戻す。登録し直すのは条件の同一性が変わったときだけで、まだ 1 回も確かめていない条件は
/// 登録の直後に今すぐ確かめる。
///
/// 番人の結果は、タスク ID と条件の同一性を添えてストアへ渡す。付け直し・解除と結果の到着が競っても、ストアが同一性の
/// 合わない結果を捨てる（係の登録し直しは次の main の回へ送られるので、その間に届く古い結果はストアでしか止められない）。
/// 観測の発火の中ではストアを書かない（結果の書き戻しは次の main の回へ送る）。
///
/// 待ちが解けたら `onResolved` で知らせる。初期化で受けるので、起動直後に期限で解けるものも取りこぼさない。
final class WaitConditionWatcher {
  private let store: TaskStore
  private let scheduler: BackgroundScheduler
  private let onResolved: (_ task: Int, WaitResolution) -> Void
  /// 番人に登録している条件（タスク ID → 条件の同一性）。
  private var registered: [Int: UUID] = [:]

  init(
    store: TaskStore, scheduler: BackgroundScheduler = BackgroundScheduler(),
    onResolved: @escaping (_ task: Int, WaitResolution) -> Void
  ) {
    self.store = store
    self.scheduler = scheduler
    self.onResolved = onResolved
  }

  /// 観測を始める（以後、一覧が変わるたびに番人の予定と突き合わせる）。観測するのは一覧だけで、番人への登録は観測の
  /// 外で行う——中で行うと番人の状態まで観測に入り、確認が始まる・終わるたびに突き合わせが空回りする。
  func start() {
    let desired = withObservationTracking {
      Self.desired(store.tasks)
    } onChange: { [weak self] in
      DispatchQueue.main.async { self?.start() }
    }
    reconcile(desired)
  }

  /// 条件を持って待っているタスク（タスク ID → 条件）。
  private static func desired(_ tasks: [TaskItem]) -> [Int: WaitCondition] {
    var desired: [Int: WaitCondition] = [:]
    for task in tasks {
      if let condition = task.waiting?.condition { desired[task.id] = condition }
    }
    return desired
  }

  private func reconcile(_ desired: [Int: WaitCondition]) {
    for id in registered.keys where desired[id] == nil {
      registered[id] = nil
      scheduler.remove(id: Self.key(id))
    }
    for (id, condition) in desired.sorted(by: { $0.key < $1.key })
    where registered[id] != condition.id {
      registered[id] = condition.id
      let conditionId = condition.id
      do {
        try scheduler.register(
          id: Self.key(id), schedule: condition.schedule, anchor: condition.anchor
        ) { [weak self] event in
          DispatchQueue.main.async { self?.handle(event, task: id, condition: conditionId) }
        }
      } catch {
        continue
      }
      if condition.checks == 0 { scheduler.runNow(id: Self.key(id)) }
    }
  }

  /// 番人の結果を書き戻す。待ちが解ける処理はすべてここを通る（ストアが起きたことを返す）。
  private func handle(_ event: BackgroundScheduler.Event, task: Int, condition: UUID) {
    let resolution =
      switch event {
      case .ran(let result): store.recordCheck(task, condition: condition, result)
      case .expired: store.expire(task, condition: condition)
      }
    if let resolution { onResolved(task, resolution) }
  }

  private static func key(_ task: Int) -> String { "wait:\(task)" }
}
