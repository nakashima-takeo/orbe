import Foundation

@testable import Orbe

/// 実行の係の代役。呼ばれた順に番号を振り、止める手と終わらせる口を持つ。
final class FakeJobs {
  private(set) var calls: [(job: BackgroundJob, completion: (BackgroundRunResult) -> Void)] = []
  private(set) var stopped: [Int] = []

  func run(_ job: BackgroundJob, completion: @escaping (BackgroundRunResult) -> Void)
    -> BackgroundRunHandle
  {
    let index = calls.count
    calls.append((job, completion))
    return BackgroundRunHandle { [unowned self] in stopped.append(index) }
  }

  func finish(_ index: Int, _ result: BackgroundRunResult) {
    calls[index].completion(result)
  }
}
