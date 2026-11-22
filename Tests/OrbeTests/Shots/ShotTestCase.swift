import Foundation

/// 撮影道具（gallery と flow）の基底。撮る前に、SwiftUI の描画の確定へ 0.2 秒の猶予を与える（flow の画には、この長さを
/// 前提にしたものが在る）。
@MainActor
class ShotTestCase: SnapshotTestCase {
  override func settleBeforeCapture() {
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
  }
}
