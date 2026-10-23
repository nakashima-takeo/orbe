import Foundation

/// 面の側が知らせを受ける者（同じ worktree を見ているソース管理パネル）。
@MainActor
protocol SourceControlObserver: AnyObject {
  /// 操作の 1 段目（1 段の操作はその段）が終わった。根のサービスの完了の後なので、根のサービスの status はもう書き込み後の
  /// 姿。2 段の操作の 1 段目は index・HEAD を書く段（コミット・プル）で、2 段目の push はそれを書かない。
  func sourceControl(
    _ control: SourceControl, firstStepDidFinish operation: SourceControl.Operation,
    outcome: SourceControl.FirstStepOutcome)
  /// 種類 `kind` の操作が終わった（通った・止めた・失敗したのどれでも）。
  func sourceControl(_ control: SourceControl, operationDidFinish kind: SourceControl.Kind)
}

/// worktree のソース管理の状態——打ちかけのメッセージ・操作の列（走っている操作と止める手）・最後の失敗。根（正準形の
/// worktree ルート）ごとに 1 つで、アプリが動いている間持つ（レジストリは強参照。中身は小さい）。どれも面ではなく worktree の
/// 事実なので、同じ worktree を 2 つの窓の面で見ても、cd で離れて戻っても、面を閉じても同じものが見える——「同じ worktree の
/// ネット操作は 1 つずつ」と「push と HEAD の書き換えは並ばない」もここで成り立つ（列にある操作と重なる操作は始めずに断る）。
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

    /// HEAD を書き換える（amend・取り消し）。
    var rewritesHead: Bool { self == .amend || self == .undo }

    /// 1 段目で送る（push は index の書き込みの順番に並ばないので、列にある書き換えと並んで走る）。
    var pushesFirst: Bool { self == .push || self == .publish }
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
    /// 実際に走っている（順番待ちを抜けた）。裏の fetch に譲って待つ間も、走っている。
    fileprivate(set) var isRunning = false
    /// 走り始めて（譲る待ちを含む）から帯に出す遅れを越えた。
    fileprivate(set) var isLong = false
    /// git の進捗の最新の行（push / pull / fetch の段だけ。git の語のまま）。
    fileprivate(set) var progress: String?
    /// 走り始めた順（帯は一番新しいものを出す）。
    @ObservationIgnored fileprivate(set) var order = 0
    /// 今の段の止める手。
    @ObservationIgnored fileprivate var write: RootFiles.Write?
    /// ネットの段の前で裏の fetch に譲って待つ間の止める手（待ちを取り下げて「止めた」で終える）。
    @ObservationIgnored fileprivate var withdraw: (() -> Void)?
    @ObservationIgnored fileprivate(set) var isStopped = false
    @ObservationIgnored fileprivate var hasFinishedFirstStep = false
    /// 始めたときの根のサービス。2 段の操作は全段が終わるまで握る——2 段目のために引き直すと、誰も握っていない瞬間に
    /// 新しいサービスができ、管理下かの判定の前に「管理外」で断られうる。
    @ObservationIgnored let files: RootFiles
    /// 人のネット操作を届け出た、そのリポジトリの裏の fetch の係（始まりと終わりを 1 組で届ける）。
    @ObservationIgnored var autoFetch: ScmAutoFetch?
    @ObservationIgnored fileprivate let longDelay = EditorDelay()

    fileprivate init(kind: Kind, step: Step, files: RootFiles) {
      self.kind = kind
      self.step = step
      self.files = files
    }

    /// 今の段を止め、次の段を起こさない。裏の fetch に譲って待っていれば、その終わりを待たずに終える。
    func stop() {
      isStopped = true
      if let withdraw {
        self.withdraw = nil
        return withdraw()
      }
      write?.cancel()
    }
  }

  /// 操作の 1 段目の終わり方。
  enum FirstStepOutcome: Equatable {
    case passed
    /// 落ちた（走る前に止めた・断ったを含む）。コミットの段なら、index に何も書いていない。
    case failed
    /// コミットの段が、先にステージする行を index に書いた後で落ちた（ステージしたものは残る）。
    case failedAfterStaging

    init(_ failure: GitWriteFailure?) {
      self = failure == nil ? .passed : .failed
    }

    init(_ commit: GitCommitOutcome) {
      switch commit {
      case .committed: self = .passed
      case .failed(_, let stagedFirst): self = stagedFirst ? .failedAfterStaging : .failed
      }
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
    /// 同じ worktree でネット操作が列にあったので、HEAD を書き換えなかった（push したコミットを書き換えうる）。
    case rewriteDuringNetwork
    /// 同じ worktree で HEAD の書き換えが列にあったので、送らなかった（書き換える前のコミットを送りうる）。
    case pushDuringRewrite
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

  /// 操作を列に載せる（最後の失敗はここで消える——次の操作を始めると消える）。列にある操作と重なる操作は載せず、断った
  /// 失敗を置いて nil を返す。
  func enqueue(_ kind: Kind, _ step: Step) -> Operation? {
    if let cause = refusal(of: kind) {
      failure = Failure(kind: kind, cause: cause)
      return nil
    }
    failure = nil
    let operation = Operation(kind: kind, step: step, files: RootFiles.shared(for: root))
    operations.append(operation)
    return operation
  }

  /// 列にある操作と重なるので `kind` を始めない理由。ネット操作が列にある間のネット操作と HEAD の書き換え、書き換えが列にある
  /// 間に 1 段目で送る操作を断る。pull・同期・コミットしてプッシュは index の書き込みの順番で書き換えの後に走るので断らない。
  private func refusal(of kind: Kind) -> FailureCause? {
    if kind.isNetwork && isNetworking { return .networkBusy }
    if kind.rewritesHead && isNetworking { return .rewriteDuringNetwork }
    if kind.pushesFirst && operations.contains(where: { $0.kind.rewritesHead }) {
      return .pushDuringRewrite
    }
    return nil
  }

  /// 段の書き込みを操作に結ぶ。走り始めたら帯の遅れを数え始め、進捗の行は段ごとに消す。
  func attach(_ write: RootFiles.Write, step: Step, to operation: Operation) {
    operation.step = step
    operation.write = write
    operation.progress = nil
    write.whenStarted { [weak self, weak operation] in
      guard let self, let operation, !operation.isRunning else { return }
      begin(operation)
    }
  }

  /// 人のネット操作が、ネットの段 `step` の前で、走っている裏の fetch の終わりを待ち始めた。待つのは、人の操作を走らせる
  /// ための一部なので、その段を走っている操作として帯に出す——塞いでいる裏の fetch は見せず、人には止められない。止める手は
  /// `withdraw`。
  func beginYielding(_ operation: Operation, before step: Step, withdraw: @escaping () -> Void) {
    operation.step = step
    operation.write = nil
    operation.progress = nil
    operation.withdraw = withdraw
    if !operation.isRunning { begin(operation) }
  }

  /// 譲る待ちが明けた。段を結ぶ前に、走っている扱いを解く——段が順番待ちに入れば、帯は塞いでいる操作を出す。
  /// 帯に出す遅れはもう越えていれば、越えたままにする（走り始めたその場で帯に戻り、点滅しない）。
  func endYielding(_ operation: Operation) {
    operation.withdraw = nil
    operation.isRunning = false
    operation.longDelay.cancel()
  }

  private func begin(_ operation: Operation) {
    nextOrder += 1
    operation.order = nextOrder
    operation.isRunning = true
    operation.longDelay.run(after: Self.longAfter) { [weak operation] in
      guard let operation, operation.isRunning else { return }
      operation.isLong = true
    }
  }

  /// 進捗の行を写す（進捗を写す段のときだけ）。
  func report(_ line: String, of operation: Operation) {
    guard operation.step.reportsProgress else { return }
    operation.progress = line
  }

  /// 操作の 1 段目が終わった（2 段の操作は段の間、1 段の操作は終わりで。1 段目を待つ間に止めた操作も、終わりで知らせる）。
  /// 知らせるのは最初の 1 回だけ。
  func finishFirstStep(_ operation: Operation, _ outcome: FirstStepOutcome) {
    guard !operation.hasFinishedFirstStep else { return }
    operation.hasFinishedFirstStep = true
    for observer in observers {
      observer.value?.sourceControl(self, firstStepDidFinish: operation, outcome: outcome)
    }
  }

  /// 操作を終える（全段の終わり）。止めた・管理外は失敗にしない。人のネット操作なら、裏の fetch の係へ終わりを届ける。
  func finish(_ operation: Operation, _ outcome: GitWriteFailure?) {
    operation.isRunning = false
    operation.longDelay.cancel()
    operations.removeAll { $0 === operation }
    finishFirstStep(operation, FirstStepOutcome(outcome))
    operation.autoFetch?.humanDidFinish(operation.kind, outcome)
    operation.autoFetch = nil
    switch outcome {
    case nil, .cancelled?, .notManaged?: break
    case let failure?: self.failure = Failure(kind: operation.kind, cause: .git(failure))
    }
    for observer in observers {
      observer.value?.sourceControl(self, operationDidFinish: operation.kind)
    }
  }
}
