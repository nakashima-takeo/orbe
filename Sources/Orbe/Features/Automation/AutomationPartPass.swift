import Foundation
import OrbeSessionLog

/// 部品の 1 回。部品と、その役割の入力を受けて手段を起こし、役割ごとに出力を読んで結果を返す。溜まり・保存・予定は
/// 持たない——何を取ったか・何を積むか・回の記録をどう確定するかは呼び手が決める。
///
/// 行を出す部品（取得・処理・判定）の出力に受け付けない行が 1 行でもあれば、決まりを外したものとする。agent の部品は同じ回の
/// 中で 1 回だけ出し直させ、コマンドの部品は直ちに失敗にする。上限は経過時間（`timeoutMinutes`）だけで、出し直しと分け合う。
/// 無出力では打ち切らない。
struct AutomationPartPass {
  let run: BackgroundScheduler.Run
  /// 依頼文に載せる今の時刻とタイムゾーンの読み口。起こすときに読む。
  let now: () -> Date
  let calendar: () -> Calendar

  /// 部品の役割の入力。ケースが役割と 1 対 1 に対応し、役割と食い違う入力は呼び手の誤り。取得と仕事のケースは行の席を
  /// 持たない——外から届いた文面を、ツールを持ちうる agent の依頼文へ型の上で運ばないため。
  enum Input {
    /// `since` は前回成功した回の開始時刻（新着の流れの取得にだけ渡す）。`lastOutput` は前回の出力の項目の id
    /// （接頭の無い元の id。空なら全件が新しい）。
    case fetch(since: Date?, lastOutput: Set<String>)
    /// `reachesJudge` は、出した行が途中で取得の部品を通らずに判定の部品へ届くか（`AutomationGraph.reachesTaskCandidates`）。
    /// 届くなら、入力の行と `id` で照らせない出力の行も決まりを外した行になる——判定の溜まりには出どころのある行しか積めず、
    /// 届いた先で黙って消えるため。処理が続くなら、照らせない行を初めに出した処理が外したことになる。
    case process([AutomationPartRow], reachesJudge: Bool)
    /// 行はどれも出どころを持つ。`choices` は判断待ちの候補と付け先にできる workspace。
    case judge([AutomationSourcedRow], choices: AutomationJudgeChoices)
    /// 入力の無い報告は空。
    case report([AutomationPartRow])
    case work
    /// `runId` はコマンドに `ORBE_RUN_ID` で渡す。
    case sideEffect([AutomationPartRow], runId: String)
  }

  /// 手段の実行の記録。`count` は読めた数——取得は項目、処理・判定は JSON の行、報告・仕事は文があれば 1、副作用は標準入力に
  /// 渡した行。
  struct Execution: Equatable {
    let commandLine: String
    let ending: String
    let count: Int
  }

  /// `Execution` は 1 回目の呼び出しの記録。出し直したなら、その記録は `breach` が持ち、成功の出力は出し直しの出力から読んだ
  /// もの。`breach` は決まりを外した回だけにある。
  enum Outcome: Equatable {
    case succeeded(Output, Execution, breach: Breach?)
    /// 手段が終わった後に分かった失敗（終わり方・UTF-8 でない・申告されたエラー・決まりを外したまま）。何も渡さない。
    case failed(String, Execution, breach: Breach?)

    var execution: Execution {
      switch self {
      case .succeeded(_, let execution, _), .failed(_, let execution, _): execution
      }
    }

    var breach: Breach? {
      switch self {
      case .succeeded(_, _, let breach), .failed(_, _, let breach): breach
      }
    }
  }

  /// 行を出す部品の出力が決まりを外したこと。`lines` は 1 回目の出力の外れた行すべて。`redo` は出し直したときだけある。
  struct Breach: Equatable {
    let lines: [AutomationBrokenLine]
    let redo: Redo?
  }

  /// 出し直しの呼び出し。`lines` は出し直しの出力でまだ外れていた行（通った、または読む前に失敗したなら空）。
  struct Redo: Equatable {
    let execution: Execution
    let lines: [AutomationBrokenLine]
  }

  /// 役割ごとの成功の出力。
  enum Output: Equatable {
    /// `rows` は前回の出力に無かった項目（毎回全件なら全部）で、`id` は `<部品の鍵>:<元の id>`。`lastOutput` は今回取れた
    /// 全項目で、次の回の前回の出力になる。
    case fetch(rows: [AutomationPartRow], lastOutput: [AutomationSeen])
    /// どの行も `id` を持ち、`id` は重ならない。入力の行と `id` で照らせた行だけが出どころを持つ。
    case process([AutomationPartRow])
    /// `resolved` は対応済みにする判断待ちの候補のリンク。
    case judge(proposals: [Proposal], resolved: [String])
    /// 報告の文。言うことが無かった回は nil。
    case report(String?)
    case work(Work)
    case sideEffect
  }

  /// 判定が出した候補の案。リンクと本文は出どころの項目から取る。
  struct Proposal: Equatable {
    let origin: AutomationOrigin
    let title: String
    let due: TaskItem.DueDate?
    /// 付け先の `Workspace.persistentId`。
    let workspace: UUID?
  }

  enum Work: Equatable {
    /// 報告の文。空の応答なら nil。
    case done(String?)
    /// 何もしなかった理由。
    case nothing(String)
  }

  /// 手段を起こす。結果は main で 1 度だけ返る。返る手で止めると、走っている呼び出し（1 回目か出し直し）を止め、結果は返らない。
  func start(
    _ node: AutomationGraph.Node, _ input: Input, completion: @escaping (Outcome) -> Void
  ) -> BackgroundRunHandle {
    precondition(input.fits(node.role), "the input must match the role of the part")
    let job = Self.job(node, input, now: now(), timeZone: calendar().timeZone)
    let calls = Calls()
    calls.current = run(job) { result in
      guard !calls.stopped else { return }
      switch Self.read(result, node, input) {
      case .failed(let reason):
        completion(.failed(reason, Self.execution(result), breach: nil))
      case .read(let output, let count, let lines) where lines.isEmpty:
        completion(.succeeded(output, Self.execution(result, count: count), breach: nil))
      case .read(_, let count, let lines):
        let first = Self.execution(result, count: count)
        guard let redo = Self.redoJob(job, node, result, lines) else {
          completion(
            .failed(Self.broke(node, lines), first, breach: Breach(lines: lines, redo: nil)))
          return
        }
        calls.current = run(redo) { result in
          guard !calls.stopped else { return }
          completion(Self.redone(result, node, input, first: first, lines: lines))
        }
      }
    }
    return BackgroundRunHandle {
      calls.stopped = true
      calls.current?.stop()
    }
  }

  /// 走っている呼び出しと、止められたか。
  private final class Calls {
    var current: BackgroundRunHandle?
    var stopped = false
  }

  static func execution(_ result: BackgroundRunResult, count: Int = 0) -> Execution {
    Execution(commandLine: result.commandLine, ending: result.ending.text, count: count)
  }

  private static func job(
    _ node: AutomationGraph.Node, _ input: Input, now: Date, timeZone: TimeZone
  )
    -> BackgroundJob
  {
    let elapsed = TimeInterval(node.timeoutMinutes * 60)
    switch node.part.method {
    case .command(let command):
      return BackgroundJob(
        work: .command(command, commandInput(node, input)),
        limits: BackgroundLimits(
          elapsed: elapsed, idle: nil, output: BackgroundLimits.command.output,
          stderr: BackgroundLimits.command.stderr))
    case .agent(let agent):
      guard let model = node.model else { preconditionFailure("an agent part has a model") }
      return BackgroundJob(
        work: .agent(
          BackgroundAgentCall(
            cli: agent.cli, model: model, tools: tools(agent, input),
            prompt: prompt(node, agent.instruction, input, now: now, timeZone: timeZone))),
        limits: BackgroundLimits(
          elapsed: elapsed, idle: nil, output: BackgroundLimits.agent.output,
          stderr: BackgroundLimits.agent.stderr))
    }
  }

  private static func commandInput(_ node: AutomationGraph.Node, _ input: Input)
    -> BackgroundInput
  {
    switch input {
    case .fetch(let since, _):
      guard let since = mark(node, since) else { return BackgroundInput() }
      return BackgroundInput(environment: ["ORBE_SINCE": SessionEvent.iso8601(since)])
    case .process(let rows, _), .report(let rows):
      return BackgroundInput(stdin: stdin(rows.map(\.text)))
    case .judge(let rows, _):
      return BackgroundInput(stdin: stdin(rows.map(\.text)))
    case .sideEffect(let rows, let runId):
      return BackgroundInput(stdin: stdin(rows.map(\.text)), environment: ["ORBE_RUN_ID": runId])
    case .work:
      preconditionFailure("a work part is an agent")
    }
  }

  /// ツールは取得と仕事の agent にだけ渡す。
  private static func tools(_ agent: AutomationPartAgent, _ input: Input) -> [String] {
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
    case .fetch(let since, _):
      return AutomationPrompts.partFetch(request: instruction, since: mark(node, since))
    case .process(let rows, let reachesJudge):
      return AutomationPrompts.partStep(
        instruction: instruction, rows: rows.map(\.text), now: now, timeZone: timeZone,
        reachesJudge: reachesJudge)
    case .judge(let rows, let choices):
      return AutomationPrompts.partJudge(
        instruction: instruction, rows: rows.map(\.text), choices: choices, now: now,
        timeZone: timeZone)
    case .report(let rows):
      return AutomationPrompts.report(
        instruction: instruction, rows: rows.map(\.text), now: now, timeZone: timeZone)
    case .work:
      return AutomationPrompts.sinkAgent(request: instruction, now: now, timeZone: timeZone)
    case .sideEffect:
      preconditionFailure("a side effect part is a command")
    }
  }

  /// 目印は新着の流れの取得にだけ渡す。
  private static func mark(_ node: AutomationGraph.Node, _ since: Date?) -> Date? {
    node.role == .fetch(.newArrivals) ? since : nil
  }

  /// 1 行 1 オブジェクト。行が無ければ標準入力は空。
  private static func stdin(_ lines: [String]) -> Data? {
    lines.isEmpty ? nil : Data(lines.map { $0 + "\n" }.joined().utf8)
  }
}

extension AutomationPartPass.Input {
  fileprivate func fits(_ role: AutomationPartRole) -> Bool {
    switch (self, role) {
    case (.fetch, .fetch), (.process, .process), (.judge, .judge), (.report, .report),
      (.work, .work), (.sideEffect, .sideEffect):
      true
    default: false
    }
  }
}

/// 溜まりの 1 行の本文（取った行）か、下流へ渡す行。
struct AutomationPartRow: Equatable {
  let id: String
  /// 行の JSON の 1 行。
  let text: String
  let origin: AutomationOrigin?
}

/// 出どころを必ず持つ行。判定の溜まりには出どころのある行だけが積まれる。
struct AutomationSourcedRow: Equatable {
  let id: String
  let text: String
  let origin: AutomationOrigin
}

/// 行の元になった取得の部品と、その部品が出したままの項目。項目の `id` は接頭の無い元の id で、前回の出力と照らす
/// （行の `id` は `<部品の鍵>:<元の id>`）。候補のリンクと本文はいつもここから取る。
struct AutomationOrigin: Equatable {
  /// 取得の部品の鍵。
  let part: String
  let item: AutomationItem
}
