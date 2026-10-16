import Foundation

/// 面の側が知らせを受ける者（同じ worktree を見ているソース管理パネル）。
@MainActor
protocol SourceControlObserver: AnyObject {
  /// 操作が終わった（通った・止めた・失敗したのどれでも）。
  func sourceControlOperationDidFinish(_ control: SourceControl)
}

/// worktree のソース管理の状態——打ちかけのメッセージ・操作の列（走っている操作と止める手）・最後の失敗。根（正準形の
/// worktree ルート）ごとに 1 つで、アプリが動いている間持つ（レジストリは強参照。中身は小さい）。どれも面ではなく worktree の
/// 事実なので、同じ worktree を 2 つの窓の面で見ても、cd で離れて戻っても、面を閉じても同じものが見える——「同じ worktree の
/// ネット操作は 1 つずつ」もここで成り立つ（ネット操作が列にある間は、次のネット操作を始めずに断る）。
///
/// git の操作は全部根のサービスの口を呼ぶ（→ `SourceControl+Operations`）。前提（upstream・detached・操作の途中）の判定と
/// 失敗の分類も根のサービスが持ち、ここは結果を記録するだけ。根のサービスは持たず、走っている操作が終わるまで握る。
@MainActor @Observable
final class SourceControl {
  /// 操作の種類。2 段の操作（同期・コミットしてプッシュ）も 1 つの操作として列に載る。
  enum Kind: Equatable {
    case stage, unstage, discard
    case commit, amend, undo
    case pull, push, fetch
    /// プル → プッシュ。
    case sync
    /// upstream を付けるプッシュ（付け方は根のサービス）。
    case publish
    /// コミット → プッシュ。
    case commitAndPush

    /// ネット操作（同じ worktree で 1 つずつ）。
    var isNetwork: Bool {
      switch self {
      case .pull, .push, .fetch, .sync, .publish, .commitAndPush: true
      default: false
      }
    }
  }

  /// 2 段の操作の今の段（1 段の操作はその段だけ）。
  enum Step: Equatable {
    case stage, unstage, discard, commit, amend, undo, pull, push, fetch

    /// git の進捗の行を写す段。
    var reportsProgress: Bool { self == .pull || self == .push || self == .fetch }

    var isCommit: Bool { self == .commit || self == .amend || self == .undo }
  }

  /// 列に載った操作 1 つ。
  @MainActor @Observable
  final class Operation {
    let kind: Kind
    fileprivate(set) var step: Step
    /// 実際に走っている（順番待ちを抜けた）。
    fileprivate(set) var isRunning = false
    /// 走り始めてから帯に出す遅れを越えてもまだ走っている。
    fileprivate(set) var isLong = false
    /// git の進捗の最新の行（push / pull / fetch の段だけ。git の語のまま）。
    fileprivate(set) var progress: String?
    /// 走り始めた順（帯は一番新しいものを出す）。
    @ObservationIgnored fileprivate(set) var order = 0
    /// 今の段の止める手。
    @ObservationIgnored fileprivate var write: RootFiles.Write?
    @ObservationIgnored fileprivate(set) var isStopped = false
    /// 始めたときの根のサービス。2 段の操作は全段が終わるまで握る——2 段目のために引き直すと、誰も握っていない瞬間に
    /// 新しいサービスができ、管理下かの判定の前に「管理外」で断られうる。
    @ObservationIgnored let files: RootFiles
    @ObservationIgnored fileprivate let longDelay = EditorDelay()

    fileprivate init(kind: Kind, step: Step, files: RootFiles) {
      self.kind = kind
      self.step = step
      self.files = files
    }

    /// 今の段を止め、次の段を起こさない。
    func stop() {
      isStopped = true
      write?.cancel()
    }
  }

  /// 最後の失敗（どの操作の、なぜか）。止めた・管理外は記録しない。
  struct Failure: Equatable {
    let kind: Kind
    let cause: FailureCause
  }

  enum FailureCause: Equatable {
    /// 根のサービスの書き込みの失敗。
    case git(GitWriteFailure)
    /// 同じ worktree で別のネット操作が列にあったので、始めなかった。
    case networkBusy
  }

  /// 走り始めてから帯に出すまでの遅れ（短い操作で帯が点滅しない）。
  static let longAfter: TimeInterval = 0.3

  let root: String
  /// 打ちかけのコミットメッセージ（永続しない）。
  var message = ""
  private(set) var operations: [Operation] = []
  private(set) var failure: Failure?
  @ObservationIgnored private var observers: [WeakObserver] = []
  @ObservationIgnored private var nextOrder = 0

  private struct WeakObserver {
    weak var value: SourceControlObserver?
  }

  private static var registry: [String: SourceControl] = [:]

  /// 根（正準形）の状態。無ければ作る。
  static func shared(for root: String) -> SourceControl {
    if let live = registry[root] { return live }
    let control = SourceControl(root: root)
    registry[root] = control
    return control
  }

  private init(root: String) {
    self.root = root
  }

  /// ネット操作（プル・プッシュ・フェッチ・同期・公開・コミットしてプッシュ）が列にある。
  var isNetworking: Bool { operations.contains { $0.kind.isNetwork } }

  /// コミットの段（コミット・amend・取り消し・コミットしてプッシュのコミットの段）が列にある。
  var isCommitting: Bool { operations.contains { $0.step.isCommit } }

  /// 帯に出す操作——遅れを越えて実際に走っている操作のうち、一番新しく走り始めたもの。順番待ちの操作は出さない。
  var bandOperation: Operation? {
    operations.filter { $0.isRunning && $0.isLong }.max { $0.order < $1.order }
  }

  func addObserver(_ observer: SourceControlObserver) {
    observers.removeAll { $0.value == nil || $0.value === observer }
    observers.append(WeakObserver(value: observer))
  }

  // MARK: - 列（`SourceControl+Operations` が使う）

  /// 操作を列に載せる（最後の失敗はここで消える——次の操作を始めると消える）。ネット操作が列にある間のネット操作は載せず、
  /// 断った失敗を置いて nil を返す。
  func enqueue(_ kind: Kind, _ step: Step) -> Operation? {
    if kind.isNetwork && isNetworking {
      failure = Failure(kind: kind, cause: .networkBusy)
      return nil
    }
    failure = nil
    let operation = Operation(kind: kind, step: step, files: RootFiles.shared(for: root))
    operations.append(operation)
    return operation
  }

  /// 段の書き込みを操作に結ぶ。走り始めたら帯の遅れを数え始め、進捗の行は段ごとに消す。
  func attach(_ write: RootFiles.Write, step: Step, to operation: Operation) {
    operation.step = step
    operation.write = write
    operation.progress = nil
    write.whenStarted { [weak self, weak operation] in
      guard let self, let operation, !operation.isRunning else { return }
      nextOrder += 1
      operation.order = nextOrder
      operation.isRunning = true
      operation.longDelay.run(after: Self.longAfter) { [weak operation] in
        guard let operation, operation.isRunning else { return }
        operation.isLong = true
      }
    }
  }

  /// 進捗の行を写す（進捗を写す段のときだけ）。
  func report(_ line: String, of operation: Operation) {
    guard operation.step.reportsProgress else { return }
    operation.progress = line
  }

  /// 操作を終える。止めた・管理外は失敗にしない。
  func finish(_ operation: Operation, _ outcome: GitWriteFailure?) {
    operation.isRunning = false
    operation.longDelay.cancel()
    operations.removeAll { $0 === operation }
    switch outcome {
    case nil, .cancelled?, .notManaged?: break
    case let failure?: self.failure = Failure(kind: operation.kind, cause: .git(failure))
    }
    for observer in observers { observer.value?.sourceControlOperationDidFinish(self) }
  }
}
