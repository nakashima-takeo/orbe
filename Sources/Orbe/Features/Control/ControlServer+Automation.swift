import Foundation

/// 自動化の 9 動詞と、裏の agent の回の道具（run_tool）の domain 操作（`ControlTarget` の一部。main スレッドでのみ呼ぶ）。
protocol ControlAutomationTarget: AnyObject {
  /// 自動化を ID 順に列挙する（list_automations）。使えないセッションでは -32000 と理由。
  func controlListAutomations() -> Result<Any, ControlError>
  /// 自動化を作るか書き換える（set_automation）。automationId が nil なら作る（version は受けない）。書き換えは version が要り、
  /// 違えば -32000。未知の automationId は -32004。定義は外の形の JSON のまま渡す。読めない定義と、今の workspace に無い席は -32602（場所付き）。
  func controlSetAutomation(
    automationId: Int?, version: Int?, _ definition: [String: Any]
  ) -> Result<Any, ControlError>
  /// 回の記録を新しい順に 1 ページ読む（list_automation_runs）。
  func controlListAutomationRuns(automationId: Int, nodeKey: String?, before: Int?, limit: Int?)
    -> Result<Any, ControlError>
  /// ノードまで流す（run_automation）。nodeKey が nil なら終わりのノードすべてまで。知らないノードは -32004、道の重なる流しがあれば -32000。
  func controlRunAutomation(automationId: Int, nodeKey: String?) -> Result<Any, ControlError>
  /// 止める・再開する（pause_automation）。nodeKey があればそのノードだけ。知らないノードは -32004。
  func controlPauseAutomation(automationId: Int, nodeKey: String?, paused: Bool) -> Result<
    Any, ControlError
  >
  /// 消す（delete_automation）。
  func controlDeleteAutomation(automationId: Int) -> Result<Any, ControlError>
  /// 覚えている提案を列挙する（list_automation_proposals）。automationId 指定はその自動化の棚の分。
  func controlListAutomationProposals(automationId: Int?) -> Result<Any, ControlError>
  /// 試走を始める（try_automation）。すぐ返る。definition が無ければ保存した定義、あれば書く前の定義（automationId があれば
  /// version を添えて直す定義、無ければ新しい定義）を試す。書く前の定義は set_automation と同じ断りで確かめる。知らない自動化・
  /// ノードは -32004、範囲・行・limit の誤りと組めない組み合わせは -32602。
  func controlTryAutomation(
    automationId: Int?, version: Int?, definition: [String: Any]?,
    _ request: AutomationTrial.Request
  ) -> Result<Any, ControlError>
  /// 裏で動く agent が、自分の回の道具（入力を読む・結果を出す）を 1 つ呼ぶ（run_tool）。終わった回の札は -32004。道具の
  /// 引数の誤りは道具の答え（断った）で返す。
  func controlRunTool(token: String, name: String, arguments: [String: Any]) -> Result<
    Any, ControlError
  >
  /// 試走を試走の ID で読む（get_automation_trial）。`wait` なら終わりか `timeoutMs` まで待つ。知らない試走（忘れた試走を含む）は
  /// -32004。
  func controlAutomationTrial(
    trialId: Int, wait: Bool, timeoutMs: Int,
    completion: @escaping (Result<Any, ControlError>) -> Void)
}

/// 自動化の 9 動詞と、裏の agent の回の道具。ハンドラが見るのは引数の在否と JSON の型（違反は -32602）だけで、定義の中身・値の
/// 検証・不変条件は `AutomationDefinition`・`AutomationStore`・`AutomationTrials` が持つ。
extension ControlServer {
  /// `get_automation_trial`（`wait` なら待つので、接続ごとに自分で応える）。
  func automationTrial(id: Any?, params p: ControlParams, conn: Connection) {
    let trialId: Int
    let wait: Bool
    let timeoutMs: Int
    do throws(ControlError) {
      trialId = try p.int("trialId")
      wait = try p.optionalBool("wait") ?? false
      timeoutMs = try WaitTimeout.parse(p, default: WaitTimeout.promptDefaultMs)
    } catch {
      return conn.respond(id: id, result: .failure(error))
    }
    DispatchQueue.main.async {
      let respond = { result in self.queue.async { conn.respond(id: id, result: result) } }
      guard let target = self.target else {
        return respond(.failure(ControlError(code: -32000, message: "no window")))
      }
      target.controlAutomationTrial(
        trialId: trialId, wait: wait, timeoutMs: timeoutMs, completion: respond)
    }
  }

  static func listAutomations(_ target: ControlAutomationTarget, _: ControlParams) -> Result<
    Any, ControlError
  > {
    target.controlListAutomations()
  }

  /// 定義は外の形の JSON のまま渡す（知らない欄・形・値の誤りは定義の読みが場所付きで断る）。
  static func setAutomation(_ target: ControlAutomationTarget, _ p: ControlParams)
    throws(ControlError) -> Result<Any, ControlError>
  {
    target.controlSetAutomation(
      automationId: try p.optionalInt("automationId"), version: try p.optionalInt("version"),
      try p.object("definition"))
  }

  static func listAutomationRuns(_ target: ControlAutomationTarget, _ p: ControlParams)
    throws(ControlError) -> Result<Any, ControlError>
  {
    target.controlListAutomationRuns(
      automationId: try p.int("automationId"), nodeKey: try p.optionalString("nodeKey"),
      before: try p.optionalInt("before"), limit: try p.optionalInt("limit"))
  }

  static func runAutomation(_ target: ControlAutomationTarget, _ p: ControlParams)
    throws(ControlError) -> Result<Any, ControlError>
  {
    target.controlRunAutomation(
      automationId: try p.int("automationId"), nodeKey: try p.optionalString("nodeKey"))
  }

  static func pauseAutomation(_ target: ControlAutomationTarget, _ p: ControlParams)
    throws(ControlError) -> Result<Any, ControlError>
  {
    target.controlPauseAutomation(
      automationId: try p.int("automationId"), nodeKey: try p.optionalString("nodeKey"),
      paused: try p.bool("paused"))
  }

  static func deleteAutomation(_ target: ControlAutomationTarget, _ p: ControlParams)
    throws(ControlError) -> Result<Any, ControlError>
  {
    target.controlDeleteAutomation(automationId: try p.int("automationId"))
  }

  static func listAutomationProposals(_ target: ControlAutomationTarget, _ p: ControlParams)
    throws(ControlError) -> Result<Any, ControlError>
  {
    target.controlListAutomationProposals(automationId: try p.optionalInt("automationId"))
  }

  /// 道具の引数はオブジェクトだけを運ぶ（無ければ空）。受ける欄はその回の道具が照らす。
  static func runTool(_ target: ControlAutomationTarget, _ p: ControlParams) throws(ControlError)
    -> Result<Any, ControlError>
  {
    target.controlRunTool(
      token: try p.string("token"), name: try p.string("name"),
      arguments: try p.optionalObject("arguments") ?? [:])
  }

  /// 与える行は JSON オブジェクトの列で受け、1 要素 1 行の JSON の文にして運ぶ（行は余分な欄を残すデータ）。
  static func tryAutomation(_ target: ControlAutomationTarget, _ p: ControlParams)
    throws(ControlError) -> Result<Any, ControlError>
  {
    let automationId = try p.optionalInt("automationId")
    let version = try p.optionalInt("version")
    let definition = try p.optionalObject("definition")
    let from = try p.optionalStrings("from")
    let to = try p.optionalStrings("to")
    let rows = try p.optionalObjects("rows")
    let limit = try p.optionalInt("limit")
    return target.controlTryAutomation(
      automationId: automationId, version: version, definition: definition,
      AutomationTrial.Request(
        from: from, to: to,
        rows: try rows?.map { object throws(ControlError) in
          guard
            let data = try? JSONSerialization.data(
              withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
            let line = String(bytes: data, encoding: .utf8)
          else { throw p.invalid("rows") }
          return line
        }, limit: limit))
  }
}
