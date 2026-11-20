import Foundation

/// 見ているリモート追跡 ref の値を覚え、動いたかを比べる。根のサービスの「リモート追跡の ref が動いたかもしれない」という
/// 知らせは、どの ref が動いたかを名前で区別しない——見ている ref の今の値を手元で読み、覚えた値と比べて、変わったときだけ
/// 知らせる（無関係なブランチが fetch で動くたびに GitHub へ問い合わせない）。値を比べるのは、前と今の両方で見ている ref
/// だけ（見る ref が増えたら、使い手が `lacks` を見て覚え直す）。
@MainActor
final class TrackingRefs {
  /// 見る ref の名前と、それを読むリポジトリを求める（求められなければ nil）。
  typealias Names = (@escaping ((repo: GitRepo, refs: [String])?) -> Void) -> Void

  private struct Read: Equatable {
    let refs: [String]
    let values: [String: String]
  }

  private let names: Names
  private var recorded: Read?

  init(names: @escaping Names) {
    self.names = names
  }

  /// 今の値を覚え（次に動いたかを比べる相手）、`completion` を呼ぶ。
  func record(_ completion: @escaping () -> Void = {}) {
    read { [weak self] read in
      self?.recorded = read
      completion()
    }
  }

  /// 覚えた組があり、その名前に `ref` が入っていない（見る ref が増えた後、まだ覚え直していない）。
  func lacks(_ ref: String) -> Bool {
    recorded.map { !$0.refs.contains(ref) } ?? false
  }

  /// リモート追跡の ref が動いたかもしれない。覚えた値があれば今の値を読んで覚え直し、前と今の両方で見ている ref の値が
  /// 変わっていれば `moved` を呼ぶ（見る ref の組が変わった直後でも、残った ref の動きを取りこぼさない）。
  func check(_ moved: @escaping () -> Void) {
    guard let previous = recorded else { return }
    read { [weak self] read in
      guard let self, let read else { return }
      recorded = read
      guard
        previous.refs.filter(read.refs.contains).contains(where: {
          previous.values[$0] != read.values[$0]
        })
      else { return }
      moved()
    }
  }

  private func read(_ completion: @escaping (Read?) -> Void) {
    names { found in
      guard let found else { return completion(nil) }
      found.repo.refValues(found.refs) { values in
        completion(values.map { Read(refs: found.refs, values: $0) })
      }
    }
  }
}
