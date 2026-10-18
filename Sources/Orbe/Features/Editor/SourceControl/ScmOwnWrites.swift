import Foundation

/// パネルで利用者が押した書き込み（ステージ・解除・破棄・コミット・amend・取り消し・プル）を、その結果が行に出るまで覚えて
/// おく。コミット・amend・取り消しが照らす「見えていたもの」は、見えている行にこれを押した順に重ねたもの——自分の操作は、
/// 走っている・順番を待つ・終わって行に出るまでのどの間でも、押した時点に見えていたものに数える（押す時刻で結果が変わらない）。
/// 数えないのは自分が押していない変化だけで、それは根のサービスが書き込みの直前に照らして断る。
@MainActor
struct ScmOwnWrites {
  enum Kind {
    case stage([GitStatus.Row])
    case unstage([GitStatus.Row])
    case discard([GitStatus.Row])
    /// コミット・amend・コミットしてプッシュ（`stagingFirst` は先にステージする行）。
    case commit(stagingFirst: [GitStatus.Row])
    case undo
    /// プル・同期。HEAD を動かし、ステージ済みは新しい HEAD との差のまま残る（残らない取り込みは git が止める）。
    case pull
  }

  private struct Entry {
    let kind: Kind
    let operation: SourceControl.Operation
    var finish: Finish?
  }

  /// 書き込み（操作の 1 段目）の終わり。
  private struct Finish {
    /// 終わった時点に届いていた status の番号。この番号以降の status から組んだ行には結果が出ている。
    let statusNumber: Int
    let failed: Bool
    /// 書き込み後の HEAD。
    let head: GitSeenHead
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

  /// 操作の 1 段目が終わった。`status` は根のサービスの書き込み後の status。書き込みの終わりは取り直した status を届けた
  /// 後に来るので、今の番号の status に結果が出ている。
  mutating func firstStepDidFinish(
    _ operation: SourceControl.Operation, failed: Bool, status: GitStatus?
  ) {
    guard let index = entries.firstIndex(where: { $0.operation === operation }) else { return }
    entries[index].finish = Finish(
      statusNumber: statusNumber, failed: failed,
      head: status?.branch.map { .at($0.commit, undone: 0) } ?? .movedByOwnWrite)
    forgetShown()
  }

  private mutating func forgetShown() {
    entries.removeAll { $0.finish.map { $0.statusNumber <= rowsNumber } ?? false }
  }

  /// 取り消しが照らす HEAD——見えている行の HEAD に、覚えている書き込みを重ねたもの。
  func head(_ changes: ScmChanges) -> GitSeenHead {
    seen(changes).head
  }

  /// コミット・amend の中身——ステージ済みがあればそれだけ、無ければ「変更」の入る行を先にステージ。自分のステージが入れる
  /// 版は押した時点には分からないので問わない。
  func content(_ changes: ScmChanges) -> GitCommitContent {
    let seen = seen(changes)
    return GitCommitContent(
      head: seen.head, staged: seen.staged, unknown: seen.unknown,
      stagingFirst: seen.hasStaged ? [] : Array(seen.committable.values))
  }

  private func seen(_ changes: ScmChanges) -> Seen {
    var seen = Seen(changes)
    for entry in entries { seen.apply(entry.kind, entry.finish) }
    return seen
  }

  /// 見えているもの（行に、覚えている書き込みを重ねた姿）。
  private struct Seen {
    var head: GitSeenHead
    /// HEAD の基準と違う index のパスとその版（→ `GitCommitContent`）。
    var staged: [String: GitStatus.IndexVersion]
    var unknown = Set<String>()
    var committable: [String: GitStatus.Row]

    init(_ changes: ScmChanges) {
      head = .at(changes.head, undone: 0)
      staged = changes.stagedVersions
      committable = Dictionary(
        changes.committable.map { ($0.path, $0.row) }, uniquingKeysWith: { $1 })
    }

    /// 取り消したコミットの中身がステージ済みに戻っている。
    private var hasUndone: Bool {
      if case .at(_, let undone) = head { return undone > 0 }
      return false
    }

    var hasStaged: Bool { !staged.isEmpty || !unknown.isEmpty || hasUndone }

    /// 書き込み 1 つを重ねる。まだ終わっていなければ（`finish` が nil）通ったとし、動かした HEAD は分からないとする。
    /// 落ちた書き込みは HEAD を動かしていない。触れたパスの index は分からないとする。
    mutating func apply(_ kind: Kind, _ finish: Finish?) {
      let failed = finish?.failed ?? false
      switch kind {
      case .stage(let rows):
        stage(rows)
      case .unstage(let rows):
        for row in rows {
          for path in row.paths {
            staged[path] = nil
            // 解除は index を今の HEAD の版へ戻す。取り消しの後は、基準（取り消す前の HEAD）と違いうる。
            if failed || hasUndone { unknown.insert(path) } else { unknown.remove(path) }
          }
          committable[row.path] = row
        }
      case .discard(let rows):
        guard !failed else { return }
        for row in rows { committable[row.path] = nil }
      case .commit(let first):
        guard !failed else { return stage(first) }
        staged = [:]
        unknown = []
        for row in first { committable[row.path] = nil }
        head = finish?.head ?? .movedByOwnWrite
      case .undo:
        guard !failed, case .at(let base, let undone) = head else { return }
        head = .at(base, undone: undone + 1)
      case .pull:
        guard !failed else { return }
        head = finish?.head ?? .movedByOwnWrite
      }
    }

    private mutating func stage(_ rows: [GitStatus.Row]) {
      for row in rows {
        for path in row.paths {
          staged[path] = nil
          unknown.insert(path)
        }
        committable[row.path] = nil
      }
    }
  }
}
