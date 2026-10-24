import Foundation

@testable import Orbe

/// 判定の部品の回の終わり方ごとの見本。どれも 13:00 に普段どおり候補を出し、14:30 の回の終わり方だけが違う: 形式エラー 2 件を
/// その場で修正して成功（`fixed`）・修正されず出力の形式エラーで失敗（`unfixed`）・コマンドの判定の出力の形式エラー（`command`）・
/// 入力の読み残し（`unread`）・結果なし（`noResult`）。
extension DesignSceneFixtures {
  static func boardJudgeOutcomeSamples() -> [(String, AutomationSample)] {
    let at = automationAt(14, 30)
    let (all, new) = sampleRound("github", at: at, items: 5, fresh: 3)
    let rejected = AutomationRejections([
      AutomationBrokenLine(line: 2, fault: .titleNotOneLine("1:\(new[1].id)")),
      AutomationBrokenLine(line: 3, fault: .dueNotDate("1:\(new[2].id)", "来週")),
    ])
    let fixed = AutomationNodePass.Outcome.succeeded(
      .judge(proposals: [proposal(new[0], "\(new[0].body)に返信する")], resolved: []),
      execution(1), breach: rejected)
    let unfixed = AutomationNodePass.Outcome.failed(
      .brokeRules, execution(0, ending: .exited(0)), breach: rejected)
    let broken = AutomationNodePass.Outcome.failed(
      .brokeRules, execution(0, ending: .exited(0)),
      breach: AutomationRejections([
        AutomationBrokenLine(line: 1, fault: .notNewItem(new[0].id)),
        AutomationBrokenLine(line: 2, fault: .notJSON),
      ]))
    let unread = failed(.unreadInput(2), ending: .exited(0))
    let noResult = failed(.noResult, ending: .exited(0))
    func sample(_ outcome: AutomationNodePass.Outcome, command: Bool = false) -> AutomationSample {
      var definition = candidatesDefinition(
        "GitHub: 自分の担当",
        fetch: commandNode(
          "fetch", "担当の課題", .scheduled(.every(3600)),
          script: "gh search issues --assignee @me --state open --json url,title,body,updatedAt",
          coverage: .newArrivals))
      if command {
        definition.nodes[1] = commandNode(
          "judge", "判定", .arrival, from: ["fetch"], script: "~/bin/judge.sh",
          deliver: .taskCandidates)
      }
      // 判定は 1 時間ごと——失敗した回の行が残っても、撮る時点では起き直さない（「届いたら」なら残った行で走り出す）。
      definition.nodes[1].trigger = .scheduled(.every(3600))
      var passes = round("github", at: automationAt(13, 0), items: 2, fresh: 2, proposed: 1)
      passes.append(
        AutomationSamplePass(
          nodeKey: "fetch", at: at, outcome: fetched(all),
          kept: Array(all.prefix(all.count - new.count))))
      passes.append(
        AutomationSamplePass(
          nodeKey: "judge", at: at.addingTimeInterval(60), outcome: outcome,
          take: new.count))
      return AutomationSample(definition: definition, createdAt: automationAt(9, 0), passes: passes)
    }
    return [
      ("fixed", sample(fixed)), ("unfixed", sample(unfixed)),
      ("command", sample(broken, command: true)), ("unread", sample(unread)),
      ("no_result", sample(noResult)),
    ]
  }
}
