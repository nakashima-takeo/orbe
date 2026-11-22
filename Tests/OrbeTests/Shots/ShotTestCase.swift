import Foundation

/// 撮影道具（gallery と flow）の基底。撮る前に、ランループを 0.2 秒回して時間を進める（flow の手順には、この 0.2 秒の経過を
/// 前提にしたものが在る）。
@MainActor
class ShotTestCase: SnapshotTestCase {
  override func settleBeforeCapture() {
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
  }
}
