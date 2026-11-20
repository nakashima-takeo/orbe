import Foundation

/// 試走の係。試走に起動中だけの ID を振り、Orbe が終わるまでメモリに持つ。自動化を持ち主とする試走（保存した定義と直す定義）は
/// 自動化ごとに 1 つ、新しい定義の試走は新しい方から `newDefinitionTrials` 個まで覚える。main で使う。
final class AutomationTrials {
  /// 覚えておく新しい定義の試走の数。
  static let newDefinitionTrials = 10

  private let runner: AutomationRunner
  private var trials: [Int: AutomationTrial] = [:]
  private var lastId = 0
  private var waiters: [Int: [Waiter]] = [:]
  private var nextWaiter = 0

  private struct Waiter {
    let token: Int
    let reply: (Result<AutomationTrial, AutomationError>, _ timedOut: Bool) -> Void
  }

  /// `runner` は本番の走らせ役。
  init(runner: AutomationRunner) {
    self.runner = runner
  }

  /// 試走を始める（すぐ返り、写しは後で進む）。範囲と与えた行を始めるときの定義で確かめ、写し始めてから、同じ持ち主の前の試走を
  /// 止めて置き換える（新しい定義の試走は、覚える数を超えた古いものを止めて忘れる）——断った依頼で前の試走が消えないように。
  func start(_ target: AutomationTrial.Target, _ request: AutomationTrial.Request)
    throws(AutomationError) -> AutomationTrial
  {
    guard runner.store.available else { throw runner.store.unavailableError }
    let shape = try target.shape(in: runner.store)
    if let limit = request.limit, limit < 1 { throw .invalid("limit must be a positive integer") }
    let span = try AutomationTrial.span(of: shape, request)
    if let rows = request.rows { _ = try AutomationTrial.given(rows, in: span, of: shape) }
    lastId += 1
    let id = lastId
    let trial = AutomationTrial(
      id: id, target: target, request: request, keys: AutomationTrial.Keys(span, of: shape),
      production: runner, onEnd: { [weak self] in self?.ended(id) })
    try trial.begin()
    if let owner = target.owner {
      trials.values.filter { $0.target.owner == owner }.map(\.id).forEach(forget)
    } else {
      let ownerless = trials.values.filter { $0.target.owner == nil }.map(\.id).sorted()
      ownerless.dropLast(Self.newDefinitionTrials - 1).forEach(forget)
    }
    trials[id] = trial
    return trial
  }

  func trial(_ id: Int) throws(AutomationError) -> AutomationTrial {
    guard let trial = trials[id] else { throw .trialNotFound(id) }
    return trial
  }

  /// 試走の終わりまで待って返す。`timeout` が過ぎたら、その時点の試走を時間切れ（true）で返す。待つ間にその試走が止まって忘れられ
  /// たら（置き換え・押し出し・自動化の削除）、知らない試走として返す。
  func wait(
    _ id: Int, timeout: DispatchTimeInterval,
    _ reply: @escaping (Result<AutomationTrial, AutomationError>, _ timedOut: Bool) -> Void
  ) {
    do throws(AutomationError) {
      let trial = try trial(id)
      guard trial.running else { return reply(.success(trial), false) }
    } catch {
      return reply(.failure(error), false)
    }
    nextWaiter += 1
    let token = nextWaiter
    waiters[id, default: []].append(Waiter(token: token, reply: reply))
    DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
      guard let self, let index = waiters[id]?.firstIndex(where: { $0.token == token }) else {
        return
      }
      let waiter = waiters[id]?.remove(at: index)
      waiter?.reply(trials[id].map { .success($0) } ?? .failure(.trialNotFound(id)), true)
    }
  }

  /// 自動化を消した。その自動化を持ち主とする試走を止めて忘れる。
  func discard(_ automationId: Int) {
    trials.values.filter { $0.target.owner == automationId }.map(\.id).forEach(forget)
  }

  /// 試走を止めて忘れ、待っている読み手には知らない試走として返す。
  private func forget(_ id: Int) {
    trials.removeValue(forKey: id)?.stop()
    for waiter in waiters.removeValue(forKey: id) ?? [] {
      waiter.reply(.failure(.trialNotFound(id)), false)
    }
  }

  private func ended(_ id: Int) {
    guard let trial = trials[id] else { return }
    for waiter in waiters.removeValue(forKey: id) ?? [] { waiter.reply(.success(trial), false) }
  }
}
