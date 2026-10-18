import Foundation

/// パネルで利用者が押した index の書き込み（ステージ・解除・破棄）を、その結果が行に出るまで覚えておく。コミットの範囲は、
/// 見えている行にこれを押した順に重ねたもの——自分の操作は、走っている・順番を待つ・終わって行に出るまでのどの間でも、押した
/// 時点に見えていたものに数える（押す時刻で結果が変わらない）。数えないのは自分が押していない変化だけで、それは根のサービスが
/// コミットの直前に照らして断る。
@MainActor
struct ScmOwnWrites {
  enum Kind {
    case stage, unstage, discard
  }

  private struct Entry {
    let kind: Kind
    let rows: [GitStatus.Row]
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

  mutating func record(_ kind: Kind, _ rows: [GitStatus.Row], _ operation: SourceControl.Operation?)
  {
    guard let operation else { return }
    entries.append(Entry(kind: kind, rows: rows, operation: operation))
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
  func content(staged: [GitStatus.Row], committable: [GitStatus.Row]) -> GitCommitContent {
    guard !entries.isEmpty else {
      return staged.isEmpty ? .staging(committable) : .staged(staged)
    }
    let byPath = { (rows: [GitStatus.Row]) in
      Dictionary(rows.map { ($0.path, $0) }, uniquingKeysWith: { $1 })
    }
    var staged = byPath(staged)
    var committable = byPath(committable)
    for entry in entries {
      for row in entry.rows {
        switch entry.kind {
        case .stage:
          staged[row.path] = row
          committable[row.path] = nil
        case .unstage:
          staged[row.path] = nil
          committable[row.path] = row
        case .discard:
          committable[row.path] = nil
        }
      }
    }
    return staged.isEmpty ? .staging(Array(committable.values)) : .staged(Array(staged.values))
  }
}
