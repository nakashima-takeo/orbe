import Foundation

/// 試走の係。自動化ごとに高々 1 つの試走を、Orbe が終わるまでメモリに持つ。main で使う。
final class AutomationTrials {
  private let runner: AutomationRunner
  private var trials: [Int: AutomationTrial] = [:]
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

  /// 試走を始める（すぐ返り、写しは後で進む）。同じ自動化の前の試走は止めて置き換える。
  func start(_ id: Int, _ request: AutomationTrial.Request) throws(AutomationError)
    -> AutomationTrial
  {
    guard runner.store.available else { throw runner.store.unavailableError }
    let automation = runner.store.automations[try runner.store.index(id)]
    if let limit = request.limit, limit < 1 { throw .invalid("limit must be a positive integer") }
    let range = try AutomationTrial.range(of: automation, request)
    if let rows = request.rows {
      _ = try AutomationTrial.given(rows, in: range, of: automation.graph)
    }
    trials.removeValue(forKey: id)?.stop()
    let onEnd: () -> Void = { [weak self] in self?.ended(id) }
    let trial = AutomationTrial(
      automationId: id, request: request, range: range, production: runner, onEnd: onEnd)
    try trial.begin()
    trials[id] = trial
    return trial
  }

  func trial(_ id: Int) throws(AutomationError) -> AutomationTrial {
    guard let trial = trials[id] else {
      throw runner.store.automation(id) == nil ? .automationNotFound(id) : .trialNotFound(id)
    }
    return trial
  }

  /// 試走の終わりまで待って返す。`timeout` が過ぎたら、その時点の試走を時間切れ（true）で返す。待つ間に置き換わったら新しい
  /// 試走の終わりを待ち、自動化が消えたら `automationNotFound` を返す。
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

  /// 自動化を消した。試走を止めて忘れる。
  func discard(_ id: Int) {
    trials.removeValue(forKey: id)?.stop()
    for waiter in waiters.removeValue(forKey: id) ?? [] {
      waiter.reply(.failure(.automationNotFound(id)), false)
    }
  }

  private func ended(_ id: Int) {
    guard let trial = trials[id] else { return }
    for waiter in waiters.removeValue(forKey: id) ?? [] { waiter.reply(.success(trial), false) }
  }
}
