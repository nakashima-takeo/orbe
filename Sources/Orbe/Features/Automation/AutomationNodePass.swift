import Foundation
import OrbeSessionLog

/// ノードの 1 回。ノードと、その役割の入力を受けて手段を起こし、役割ごとに結果を受けて返す。読み・保存・予定は持たない——何を
/// 取ったか・出した行をどう残すか・回の記録をどう確定するかは呼び手が決める。
///
/// agent のノードは、回の入力を Orbe の MCP の道具で読み、結果も道具で出す（`AutomationRunSession`）。道具が呼ばれるたびに
/// 確かめ、外れていればその場で理由を返すので、agent は同じ会話の中で直す。コマンドのノードは入力を標準入力で受け、結果を
/// 標準出力で出す——同じ決まり（`AutomationOutputs`）で確かめ、1 件でも外れていればその回は失敗にする（走らせ直しても同じ
/// 出力になるため）。上限は経過時間（`timeoutMinutes`）だけで、無出力では打ち切らない。
struct AutomationNodePass {
  let run: BackgroundScheduler.Run
  /// 依頼文に載せる今の時刻とタイムゾーンの読み口。起こすときに読む。
  let now: () -> Date
  let calendar: () -> Calendar
  /// agent の回の相手を Orbe の MCP へ渡す帳面。
  let runSessions: AutomationRunSessions
  /// 今の workspace の写しの読み口。コマンドを起こす直前に 1 度だけ読み、走る workspace を今の root に解く。
  let workspaces: () -> AutomationWorkspaces

  /// ノードの役割の入力。ケースが役割と 1 対 1 に対応し、役割と食い違う入力は呼び手の誤り。取得と仕事のケースは行の席を
  /// 持たない——外から届いた文面を、ツールを持ちうる agent の依頼文へ型の上で運ばないため。
  enum Input {
    /// `since` は前回成功した回の開始時刻（新着の流れの取得にだけ渡す）。`reachesJudge` は、出した行が途中で取得のノードを
    /// 通らずに判定のノードへ届くか（`AutomationGraph.reachesTaskCandidates`）。届くなら、依頼文で候補にしたい行に link を
    /// 書かせる。
    case fetch(since: Date?, reachesJudge: Bool)
    case process([AutomationNodeRow], reachesJudge: Bool)
    /// `choices` は判断待ちの候補と付け先にできる workspace。
    case judge([AutomationNodeRow], choices: AutomationJudgeChoices)
    /// 入力の無い報告は空。
    case report([AutomationNodeRow])
    case work
    /// `runId` はコマンドに `ORBE_RUN_ID` で渡す。
    case sideEffect([AutomationNodeRow], runId: String)
  }

  /// 手段の実行の記録。`count` は受けた数——取得は項目、処理・判定は行、報告・仕事は文があれば 1、副作用は標準入力に渡した行。
  struct Execution: Equatable, Codable {
    let commandLine: String
    let ending: AutomationEnding
    let count: Int
  }

  /// `breach` は結果を断った回だけにある（agent は断った呼び出しの外れた件、コマンドは外れた行）。
  enum Outcome: Equatable {
    case succeeded(Output, Execution, breach: AutomationRejections?)
    /// 手段が終わった後に分かった失敗（終わり方・UTF-8 でない・申告されたエラー・決まりを外した・入力を読み切らない・結果が
    /// 無い）。何も渡さない。
    case failed(AutomationFailure, Execution, breach: AutomationRejections?)

    var execution: Execution {
      switch self {
      case .succeeded(_, let execution, _), .failed(_, let execution, _): execution
      }
    }

    var breach: AutomationRejections? {
      switch self {
      case .succeeded(_, _, let breach), .failed(_, _, let breach): breach
      }
    }
  }

  /// 役割ごとの成功の出力。
  enum Output: Equatable {
    /// 取れた全項目（書かれた id と書かれたままの 1 行）。何が新しいかは出す側の確定が決める。
    case fetch([AutomationNodeRow])
    /// どの行も `id` を持ち、`id` は重ならない。入力の行と `id` で照らせた行だけが、その入力を引き継ぐ。
    case process([AutomationNodeRow])
    /// `resolved` は対応済みにする判断待ちの候補のリンク。
    case judge(proposals: [Proposal], resolved: [String])
    /// 報告の文。言うことが無かった回は nil。
    case report(String?)
    case work(Work)
    case sideEffect
  }

  /// 判定が出した候補の案。リンク・本文・時刻は案が指した行から取る。
  struct Proposal: Equatable {
    /// 案が指した行の、下流へ渡す id。
    let id: String
    /// 案が指した行（項目は版）。
    let row: AutomationRowRef
    let fields: AutomationRowFields
    let title: String
    let due: TaskItem.DueDate?
    /// 付け先の `Workspace.id`。
    let workspace: UUID?
    /// 候補にした理由（判定が書いたときだけ）。
    let reason: String?
  }

  enum Work: Equatable {
    /// 報告の文。
    case done(String)
    /// 何もしなかった理由。
    case nothing(String)
  }

  /// 手段を起こす。結果は main で 1 度だけ返る（起こさずに失敗した回も、この呼び出しの中では返さず main の次の巡りで返す）。
  /// 返る手で止めると、走っている呼び出しを止め、結果は返らない。
  func start(
    _ node: AutomationGraph.Node, _ input: Input, completion: @escaping (Outcome) -> Void
  ) -> BackgroundRunHandle {
    precondition(input.fits(node.role), "the input must match the role of the node")
    let elapsed = TimeInterval(node.timeoutMinutes * 60)
    var stopped = false
    let handle: BackgroundRunHandle
    switch node.action.method {
    case .command(let command):
      guard let resolved = Self.resolved(command, in: node.workspace, workspaces) else {
        DispatchQueue.main.async {
          guard !stopped else { return }
          completion(
            .failed(
              .ended(detail: ""),
              Execution(commandLine: command.script, ending: .workspaceMissing, count: 0),
              breach: nil))
        }
        return BackgroundRunHandle { stopped = true }
      }
      let job = BackgroundJob(
        work: .command(resolved, Self.commandInput(node, input)),
        limits: BackgroundLimits(
          elapsed: elapsed, idle: nil, output: BackgroundLimits.command.output,
          stderr: BackgroundLimits.command.stderr))
      handle = run(job) { result in
        guard !stopped else { return }
        completion(Self.commandEnded(result, input, writer: node.id))
      }
      return BackgroundRunHandle {
        stopped = true
        handle.stop()
      }
    case .agent(let agent):
      let session = AutomationRunSession(input, writer: node.id)
      let runSessions = self.runSessions
      let token = runSessions.open(session)
      let job = BackgroundJob(
        work: .agent(
          BackgroundAgentCall(
            cli: agent.cli, model: agent.model, tools: Self.tools(agent, input),
            prompt: Self.prompt(
              node, agent.instruction, input, now: now(), timeZone: calendar().timeZone),
            orbe: BackgroundOrbeAccess(token: token, tools: session.tools.map(\.rawValue)))),
        limits: BackgroundLimits(
          elapsed: elapsed, idle: nil, output: BackgroundLimits.agent.output,
          stderr: BackgroundLimits.agent.stderr))
      handle = run(job) { result in
        runSessions.close(token)
        guard !stopped else { return }
        completion(Self.agentEnded(result, session))
      }
      return BackgroundRunHandle {
        stopped = true
        runSessions.close(token)
        handle.stop()
      }
    }
  }

  /// 走る workspace を今の root に解いたコマンド（作業ディレクトリは root からの相対パスをつないだ絶対パス）。workspace が効かない
  /// コマンドは書いたまま。workspace が今無ければ nil。
  private static func resolved(
    _ command: AutomationNodeCommand, in workspace: UUID?,
    _ workspaces: () -> AutomationWorkspaces
  ) -> BackgroundCommand? {
    guard let workspace else {
      return BackgroundCommand(script: command.script, directory: command.directory)
    }
    guard let relative = command.directory else {
      preconditionFailure("a node that runs in a workspace has a directory")
    }
    guard let root = workspaces().workspace(workspace)?.root else { return nil }
    let directory = URL(fileURLWithPath: root, isDirectory: true)
      .appendingPathComponent(relative).standardized.path
    return BackgroundCommand(script: command.script, directory: directory)
  }

  static func execution(_ result: BackgroundRunResult, count: Int = 0) -> Execution {
    Execution(
      commandLine: result.commandLine, ending: AutomationEnding(result.ending), count: count)
  }

  /// agent の回の結果: CLI の終わり方が先、次に申告された失敗。最後の結果の呼び出しを断ったまま終えていれば出力の形式エラー
  /// （断られた中身を黙って落とさない）。結果があれば成功、無ければ入力を渡し切っていなければ読み残し、渡し切っていれば
  /// 結果なしの失敗。
  private static func agentEnded(_ result: BackgroundRunResult, _ session: AutomationRunSession)
    -> Outcome
  {
    let execution = execution(result, count: session.outputs.count)
    let breach = session.rejections
    if let failure = AutomationRunOutput.agentFailure(result) {
      return .failed(failure, execution, breach: breach)
    }
    if let error = session.error { return .failed(.reported(error), execution, breach: breach) }
    if session.refusedLast { return .failed(.brokeRules, execution, breach: breach) }
    guard session.answered else {
      let unread = session.unread.count
      return .failed(unread > 0 ? .unreadInput(unread) : .noResult, execution, breach: breach)
    }
    return .succeeded(session.outputs.output(nothing: session.nothing), execution, breach: breach)
  }

  private static func commandInput(_ node: AutomationGraph.Node, _ input: Input)
    -> BackgroundInput
  {
    switch input {
    case .fetch(let since, _):
      guard let since = mark(node, since) else { return BackgroundInput() }
      return BackgroundInput(environment: ["ORBE_SINCE": SessionEvent.iso8601(since)])
    case .process(let rows, _), .judge(let rows, _), .report(let rows):
      return BackgroundInput(stdin: stdin(rows.map(\.text)))
    case .sideEffect(let rows, let runId):
      return BackgroundInput(
        stdin: stdin(rows.map(\.text)), environment: ["ORBE_RUN_ID": runId])
    case .work:
      preconditionFailure("a work node is an agent")
    }
  }

  /// ツールは取得と仕事の agent にだけ渡す。
  private static func tools(_ agent: AutomationNodeAgent, _ input: Input) -> [String] {
    switch input {
    case .fetch, .work: agent.tools
    case .process, .judge, .report, .sideEffect: []
    }
  }

  private static func prompt(
    _ node: AutomationGraph.Node, _ instruction: String, _ input: Input, now: Date,
    timeZone: TimeZone
  ) -> String {
    switch input {
    case .fetch(let since, let reachesJudge):
      return AutomationPrompts.fetch(
        instruction: instruction, since: mark(node, since), reachesJudge: reachesJudge)
    case .process(let rows, let reachesJudge):
      return AutomationPrompts.process(
        instruction: instruction, count: rows.count, now: now, timeZone: timeZone,
        reachesJudge: reachesJudge)
    case .judge(let rows, _):
      return AutomationPrompts.judge(
        instruction: instruction, count: rows.count, now: now, timeZone: timeZone)
    case .report(let rows):
      return AutomationPrompts.report(
        instruction: instruction, count: rows.count, now: now, timeZone: timeZone)
    case .work:
      return AutomationPrompts.work(instruction: instruction, now: now, timeZone: timeZone)
    case .sideEffect:
      preconditionFailure("a side effect node is a command")
    }
  }

  /// 目印は新着の流れの取得にだけ渡す。
  private static func mark(_ node: AutomationGraph.Node, _ since: Date?) -> Date? {
    node.coverage == .newArrivals ? since : nil
  }

  /// 1 行 1 オブジェクト。行が無ければ標準入力は空。
  private static func stdin(_ lines: [String]) -> Data? {
    lines.isEmpty ? nil : Data(lines.map { $0 + "\n" }.joined().utf8)
  }
}

extension AutomationNodePass.Input {
  /// ノードの 1 回が受ける行の 1 行ずつ（取得と仕事は持たない）。
  var rowTexts: [String] {
    switch self {
    case .process(let rows, _), .judge(let rows, _), .report(let rows), .sideEffect(let rows, _):
      rows.map(\.text)
    case .fetch, .work: []
    }
  }

  fileprivate func fits(_ role: AutomationNodeRole) -> Bool {
    switch (self, role) {
    case (.fetch, .fetch), (.process, .process), (.judge, .judge), (.report, .report),
      (.work, .work), (.sideEffect, .sideEffect):
      true
    default: false
    }
  }
}

/// ノードの 1 回が受ける行（読んだ行）か、出した行。受ける行の `id` は下流へ渡す id、出した行の `id` は書かれた id。
struct AutomationNodeRow: Equatable {
  let id: String
  /// 行の JSON の 1 行（受ける行は下流へ渡す 1 行、出した行は書かれたまま）。
  let text: String
  /// 受ける行は回の履歴が指す行（項目は版）。出した行は持たない。
  let ref: AutomationRowRef?
  /// 受ける行は出す側の行（下流が引き継ぐ参照）、出した行は引き継いだ入力。
  let source: AutomationSourceRef?
}

/// 保存の形は終わり方を種類で持つ（`end`）。外の形の英文の `ending` は `AutomationRunWire` が足す。
extension AutomationNodePass.Execution {
  private enum CodingKeys: String, CodingKey {
    case commandLine
    case ending = "end"
    case count
  }
}
