import Foundation

@testable import Orbe

extension WorktreePaletteSectionBuilder.Input {
  /// design 正典の一覧（`designSample`）に、origin を追跡する遅れたローカルブランチ 2 本を足した
  /// サンプル。`main` は ff できる遅れ（12）、`topic/diverged` は分岐（↑2 ↓5）。最新化の題材。
  static var staleSample: WorktreePaletteSectionBuilder.Input {
    var input = designSample
    input.localBranches += [
      GitBranch(
        name: "main", relativeDate: "1d ago", upstream: upstream("main", ahead: 0, behind: 12)),
      GitBranch(
        name: "topic/diverged", relativeDate: "5d ago",
        upstream: upstream("topic/diverged", ahead: 2, behind: 5)),
    ]
    return input
  }
}
