import Foundation

/// パネルで利用者が押した index の書き込み（ステージ・解除・破棄）を、その結果が行に出るまで覚えておく。コミットの範囲は、
/// 見えている行にこれを押した順に重ねたもの——自分の操作は、走っている・順番を待つ・終わって行に出るまでのどの間でも、押した
/// 時点に見えていたものに数える（押す時刻で結果が変わらない）。数えないのは自分が押していない変化だけで、それは根のサービスが
/// コミットの直前に照らして断る。
@MainActor
struct ScmOwnWrites {
  enum Kind {
    case stage([GitStatus.Row])
    case unstage([GitStatus.Row])
    case discard([GitStatus.Row])
  }

  private struct Entry {
    let kind: Kind
    let operation: SourceControl.Operation
    /// 終わった時点に届いていた status の番号（nil = まだ列にある）。書き込みの終わりは取り直した status を届けた後に
    /// 来るので、この番号以降の status から組んだ行には結果が出ている。
    var finishedAt: Int?
  }

  private var entries: [Entry] = []
  /// 届いた status の番号。
  private(set) var statusNumber = 0
  /// 今の行を組んだ status の番号。
  private(set) var rowsNumber = 0

  mutating func record(_ kind: Kind, _ operation: SourceControl.Operation?) {
    guard let operation else { return }
    entries.append(Entry(kind: kind, operation: operation))
  }

  mutating func statusDidArrive() {
    statusNumber += 1
  }

  /// `number` の status から組んだ行を当てた。
  mutating func rowsDidApply(builtFrom number: Int) {
    rowsNumber = number
    forgetShown()
  }

  /// 列から抜けた操作を終わったとする。
  mutating func operationsDidFinish(remaining: [SourceControl.Operation]) {
    for index in entries.indices where entries[index].finishedAt == nil {
      if !remaining.contains(where: { $0 === entries[index].operation }) {
        entries[index].finishedAt = statusNumber
      }
    }
    forgetShown()
  }

  private mutating func forgetShown() {
    entries.removeAll { $0.finishedAt.map { $0 <= rowsNumber } ?? false }
  }

  /// 見えている行に覚えている書き込みを重ねた範囲——ステージ済みがあればそれだけ、無ければ「変更」の入る行を先にステージ。
  /// 自分のステージが入れる版は、押した時点には分からないので問わない。
  func content(_ changes: ScmChanges) -> GitCommitContent {
    var staged = changes.stagedVersions
    var unknown = Set<String>()
    var committable = Dictionary(
      changes.committable.map { ($0.path, $0.row) }, uniquingKeysWith: { $1 })
    for entry in entries {
      switch entry.kind {
      case .stage(let rows):
        for row in rows {
          for path in row.paths {
            staged[path] = nil
            unknown.insert(path)
          }
          committable[row.path] = nil
        }
      case .unstage(let rows):
        for row in rows {
          for path in row.paths {
            staged[path] = nil
            unknown.remove(path)
          }
          committable[row.path] = row
        }
      case .discard(let rows):
        for row in rows { committable[row.path] = nil }
      }
    }
    let hasStaged = !staged.isEmpty || !unknown.isEmpty
    return GitCommitContent(
      staged: staged, unknown: unknown, stagingFirst: hasStaged ? [] : Array(committable.values))
  }
}
