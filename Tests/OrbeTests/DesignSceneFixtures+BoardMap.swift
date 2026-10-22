import Foundation

@testable import Orbe

/// 見本 O2Board・O2PartCards（案2 地図＋選んだ部品）の自動化。12 部品の「受け持ちの全部」（判定「返事が要る連絡を選ぶ」の
/// 最新の回が制限時間で失敗・取得「メール」の出力の形式エラーが出し直しで通った・取得の新着なしが続く区間・処理が古い行を
/// 捨てた回・判定と週報の未処理）、コマンドだけの「日報スクリプト」、止めた「週末の依存更新」と、入力が 8 本の判定を持つ自動化
/// （溝が見本より広がる）。並びは 受け持ちの全部 → 日報スクリプト → 取り込みの多い判定 → 週末の依存更新。
extension DesignSceneFixtures {
  static func boardMapSamples() -> [AutomationSample] {
    [boardMapCharge, boardMapDailyScript, boardMapWide, boardMapWeekend]
  }

  /// 受け持ちの全部。どの部品も、走らせ役の今（15:00）にはまだ次の予定が来ていない。
  private static var boardMapCharge: AutomationSample {
    let at = { (hour: Int, minute: Int, daysAgo: Int) in
      automationAt(hour, minute, daysAgo: daysAgo)
    }
    var passes: [AutomationSamplePass] = []
    func fetch(_ key: String, _ hour: Int, _ minute: Int, items: Int, fresh: Int, daysAgo: Int = 0)
    {
      let (all, _) = sampleRound(key, at: at(hour, minute, daysAgo), items: items, fresh: fresh)
      passes.append(
        AutomationSamplePass(
          part: key, at: at(hour, minute, daysAgo), outcome: fetched(all),
          kept: Array(all.prefix(items - fresh))))
    }
    func process(
      _ key: String, _ time: Date, rows: Int, from source: String, expired: Int = 0
    ) {
      passes.append(
        AutomationSamplePass(
          part: key, at: time, trigger: .arrival, outcome: processed([], read: rows),
          expired: expired, passThrough: rows))
    }
    func judge(_ key: String, at time: Date, proposed: Int, rows: Int, from source: String) {
      let items = sampleItems(source, proposed, at: time)
      passes.append(
        AutomationSamplePass(
          part: key, at: time,
          outcome: judged(items.map { proposal($0, "\($0.body)に返事をする") }, rows: rows)))
    }

    // 10/2・10/3 の連絡の判定と、金曜の週の作業のまとめ。
    fetch("slack", 12, 50, items: 12, fresh: 6, daysAgo: 2)
    process("dedupe", at(12, 51, 2), rows: 6, from: "slack")
    judge("contact", at: at(13, 0, 2), proposed: 0, rows: 6, from: "slack")
    fetch("slack", 12, 50, items: 12, fresh: 5, daysAgo: 1)
    process("dedupe", at(12, 51, 1), rows: 5, from: "slack")
    judge("contact", at: at(13, 0, 1), proposed: 1, rows: 5, from: "slack")
    passes.append(
      AutomationSamplePass(
        part: "weekly", at: at(17, 0, 1),
        outcome: reported("今週は PR 12 件をマージ、Backlog の課題 4 件を完了。")))
    // 今日の 9:00 の開発の判定。
    fetch("github", 8, 50, items: 18, fresh: 12)
    judge("dev", at: at(9, 0, 0), proposed: 2, rows: 12, from: "github")
    // 13:00 の連絡の判定が制限時間で失敗。未処理は残る。
    fetch("slack", 12, 40, items: 14, fresh: 4)
    process("dedupe", at(12, 41, 0), rows: 4, from: "slack")
    passes.append(
      AutomationSamplePass(
        part: "contact", at: at(13, 0, 0), outcome: failed("", ending: .timeLimit, count: 0)))
    // 自分の担当だけは、古い行を 2 件捨ててから 2 件を受け、どれも次へ渡さなかった。
    fetch("backlog", 13, 0, items: 8, fresh: 4)
    process("mine", at(13, 45, 0), rows: 0, from: "backlog", expired: 2)
    fetch("mail", 13, 45, items: 1, fresh: 1)
    process("dedupe", at(13, 46, 0), rows: 1, from: "mail")
    // 新着なしが続く（畳まれる）。
    for hour in [13, 14] {
      for minute in stride(from: hour == 13 ? 10 : 0, through: hour == 13 ? 50 : 40, by: 10) {
        fetch("ci", hour, minute, items: 7, fresh: 0)
        fetch("slack", hour, minute, items: 14, fresh: 0)
      }
    }
    fetch("sentry", 14, 15, items: 3, fresh: 1)
    fetch("mail", 14, 15, items: 1, fresh: 0)
    // 14:45 のメールは、形式エラーをその場で直して通った。
    let mailItems = sampleItems("mail", 2, at: at(14, 45, 0))
    passes.append(
      AutomationSamplePass(
        part: "mail", at: at(14, 45, 0),
        outcome: .succeeded(
          .fetch(mailItems.map(row)),
          execution(2),
          breach: AutomationRejections([
            AutomationBrokenLine(line: 3, fault: .missingKey("link")),
            AutomationBrokenLine(line: 5, fault: .notJSON),
          ]))))
    fetch("backlog", 14, 45, items: 9, fresh: 1)
    fetch("sentry", 14, 45, items: 3, fresh: 0)
    process("mine", at(14, 46, 0), rows: 1, from: "backlog")
    process("dedupe", at(14, 46, 0), rows: 2, from: "mail")
    fetch("ci", 14, 55, items: 7, fresh: 0)
    fetch("slack", 14, 55, items: 14, fresh: 0)
    fetch("github", 14, 55, items: 18, fresh: 2)
    passes.append(
      AutomationSamplePass(
        part: "digest", at: at(14, 56, 0), trigger: .arrival,
        outcome: reported(
          "レビュー依頼が 2 件。#412 認証のリトライを追加（tanaka）、#415 決済画面の文言修正（suzuki）。どちらも今日中の確認を求めている。"
        )))

    var mine = commandPart(
      "mine", "自分の担当だけ", .arrival, from: ["backlog", "sentry"],
      script: #"jq -c 'select(.assignee == "nakatake")'"#, directory: "/Users/me/work/scripts")
    mine.from = mine.from.map { AutomationDefinition.Input(part: $0.part, maxAgeHours: 24) }
    var mail = agentPart(
      "mail", "メール", .scheduled(.every(1800)), model: "haiku",
      tools: ["mcp__gmail__search_threads"],
      instruction: "受信箱から、自分宛てで返事を求められているメールを取る。", coverage: .newArrivals)
    mail.action.timeoutMinutes = 5
    return AutomationSample(
      definition: AutomationDefinition(
        name: "受け持ちの全部", notify: .menuBar,
        parts: [
          commandPart(
            "github", "GitHub", .scheduled(.every(600)),
            script: "gh search prs --review-requested=@me --json url,title", coverage: .currentSet),
          commandPart(
            "ci", "CI", .scheduled(.every(600)), script: "gh run list --status failure --json url",
            coverage: .currentSet),
          agentPart(
            "backlog", "Backlog", .scheduled(.every(1800)), tools: ["mcp__backlog__get_issues"],
            instruction: "自分が担当の未完了の課題を、更新の新しい順に 30 件取る。", coverage: .currentSet),
          agentPart(
            "sentry", "Sentry", .scheduled(.every(1800)), tools: ["mcp__sentry__list_issues"],
            instruction: "自分のプロジェクトの未解決のエラーを取る。", coverage: .currentSet),
          agentPart(
            "slack", "Slack", .scheduled(.every(600)), tools: ["mcp__slack__search_messages"],
            instruction: "自分宛の DM とメンションを、新しい順に 50 件取る。", coverage: .newArrivals),
          mail,
          mine,
          agentPart(
            "dedupe", "重複をまとめる", .arrival, from: ["slack", "mail"],
            instruction: "同じ話題のメッセージを 1 行にまとめる。"),
          agentPart(
            "digest", "レビュー依頼を知らせる", .arrival, from: ["github"],
            instruction: "届いたレビュー依頼を 3 行以内で要約する。", deliver: .report),
          agentPart(
            "weekly", "週の作業をまとめる", .scheduled(cron("0 17 * * 5")),
            from: ["github", "ci", "backlog"], instruction: "今週の動きを週報にまとめる。",
            deliver: .report),
          agentPart(
            "dev", "開発の依頼を選ぶ", .scheduled(cron("0 9 * * *")), from: ["github", "ci", "mine"],
            model: "sonnet", instruction: "自分が手を動かすべきものだけをタスク候補にする。",
            deliver: .taskCandidates),
          agentPart(
            "contact", "返事が要る連絡を選ぶ", .scheduled(cron("0 13 * * 1-5")), from: ["dedupe"],
            model: "sonnet",
            instruction: "Slack とメールから、自分への依頼と、自分の返事を待たれているものだけをタスク候補にする。",
            deliver: .taskCandidates),
        ]),
      createdAt: automationAt(9, 0, daysAgo: 7), passes: passes)
  }

  /// コマンドだけの自動化。
  private static var boardMapDailyScript: AutomationSample {
    AutomationSample(
      definition: AutomationDefinition(
        name: "日報スクリプト", notify: nil,
        parts: [
          commandPart(
            "note", "日報を書く", .scheduled(cron("0 23 * * *")), script: "~/bin/daily-note.sh",
            deliver: .sideEffect)
        ]),
      createdAt: automationAt(9, 0, daysAgo: 7),
      passes: [
        AutomationSamplePass(
          part: "note", at: automationAt(23, 0, daysAgo: 1), outcome: sideEffected(0))
      ])
  }

  /// 取得 8 つが 1 つの判定へ入る。まだ動いていない。
  private static var boardMapWide: AutomationSample {
    let sources = (1...8).map { "src\($0)" }
    return AutomationSample(
      definition: AutomationDefinition(
        name: "取り込みの多い判定", notify: nil,
        parts: sources.map {
          commandPart(
            $0, "取り込み \($0.dropFirst(3))", .scheduled(.every(3600)), script: "~/bin/\($0).sh",
            coverage: .newArrivals)
        } + [
          agentPart(
            "judge", "依頼を選ぶ", .arrival, from: sources, instruction: "依頼だけをタスク候補にする。",
            deliver: .taskCandidates)
        ]),
      createdAt: automationAt(14, 30))
  }

  /// 止めている。作業の部品が前回の応答を残している。
  private static var boardMapWeekend: AutomationSample {
    AutomationSample(
      definition: AutomationDefinition(
        name: "週末の依存更新", notify: nil,
        parts: [
          agentPart(
            "update", "依存を上げる", .scheduled(cron("0 10 * * 0,6")), tools: ["Bash(npm:*)"],
            instruction: "古くなった依存を調べて、上げてよいものを上げる。", deliver: .report)
        ]),
      createdAt: automationAt(9, 0, daysAgo: 7), paused: true,
      passes: [
        AutomationSamplePass(
          part: "update", at: automationAt(10, 0, daysAgo: 7),
          outcome: worked(.done("react を 18.3.1 へ上げた。")))
      ])
  }
}
