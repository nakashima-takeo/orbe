import Foundation

@testable import Orbe

/// 見本 O2Board（案2 地図＋選んだ部品）の自動化。12 部品の「受け持ちの全部」（判定「連絡」の最新の回が失敗・取得「Backlog」の
/// 出力が決まりを外した・取得の新着なしが続く区間・判定と週報の溜まり）、コマンドだけの「日報スクリプト」、止めた「週末の依存
/// 更新」と、入力が 8 本の判定を持つ自動化（溝が見本より広がる）。並びは 受け持ちの全部 → 日報スクリプト → 取り込みの多い判定
/// → 週末の依存更新。
extension DesignSceneFixtures {
  static func boardMapSamples() -> [AutomationSample] {
    [boardMapCharge, boardMapDailyScript, boardMapWide, boardMapWeekend]
  }

  /// 受け持ちの全部。部品の鍵は GitHub・CI・Backlog・Sentry・Slack・メールの取得、処理 2 つ、報告 2 つ、判定 2 つ。
  private static var boardMapCharge: AutomationSample {
    let at = { (hour: Int, minute: Int, daysAgo: Int) in
      automationAt(hour, minute, daysAgo: daysAgo)
    }
    var passes: [AutomationSamplePass] = []
    func fetch(_ key: String, _ hour: Int, _ minute: Int, items: Int, fresh: Int, daysAgo: Int = 0)
    {
      let all = sampleItems(key, items, at: at(hour, minute, daysAgo))
      passes.append(
        AutomationSamplePass(
          part: key, at: at(hour, minute, daysAgo),
          outcome: fetched(key, all, fresh: Array(all.suffix(fresh)))))
    }
    func process(
      _ key: String, _ hour: Int, _ minute: Int, rows: Int, from source: String, daysAgo: Int = 0
    ) {
      let origins = sampleItems(source, rows, at: at(hour, minute, daysAgo))
      let out = origins.map {
        AutomationPartRow(
          id: "\(key):\($0.id)", text: #"{"id":"\#(key):\#($0.id)","summary":"まとめ"}"#,
          origin: AutomationOrigin(part: source, item: $0))
      }
      passes.append(
        AutomationSamplePass(
          part: key, at: at(hour, minute, daysAgo), trigger: .arrival,
          outcome: processed(out, read: rows)))
    }
    func judge(_ key: String, at time: Date, proposed: Int, rows: Int, from source: String) {
      let items = sampleItems(source, proposed, at: time)
      passes.append(
        AutomationSamplePass(
          part: key, at: time,
          outcome: .succeeded(
            .judge(
              proposals: items.map {
                AutomationPartPass.Proposal(
                  origin: AutomationOrigin(part: source, item: $0), title: "\($0.body)に返事をする",
                  due: nil, workspace: nil)
              }, resolved: []), execution(rows), breach: nil)))
    }

    // 10/2・10/3 の連絡の判定。
    fetch("slack", 12, 50, items: 12, fresh: 6, daysAgo: 2)
    process("dedupe", 12, 51, rows: 6, from: "slack", daysAgo: 2)
    judge("contact", at: at(13, 0, 2), proposed: 0, rows: 6, from: "slack")
    fetch("slack", 12, 50, items: 12, fresh: 5, daysAgo: 1)
    process("dedupe", 12, 51, rows: 5, from: "slack", daysAgo: 1)
    judge("contact", at: at(13, 0, 1), proposed: 1, rows: 5, from: "slack")
    passes.append(
      AutomationSamplePass(
        part: "weekly", at: at(17, 0, 1),
        outcome: reported("今週は PR 12 件をマージ、Backlog の課題 4 件を完了。")))
    // 今日の 9:00 の開発の判定。
    fetch("github", 8, 50, items: 18, fresh: 12)
    judge("dev", at: at(9, 0, 0), proposed: 2, rows: 12, from: "github")
    // 13:00 の連絡の判定が時間切れで失敗。溜まりは残る。
    fetch("slack", 12, 40, items: 14, fresh: 4)
    process("dedupe", 12, 41, rows: 4, from: "slack")
    passes.append(
      AutomationSamplePass(
        part: "contact", at: at(13, 0, 0),
        outcome: failed("the judge ended: stopped at the time limit")))
    fetch("mail", 13, 30, items: 2, fresh: 2)
    process("dedupe", 13, 31, rows: 2, from: "mail")
    // 新着なしが続く（畳まれる）。どの部品も、走らせ役の今（15:00）にはまだ次の予定が来ていない。
    for hour in [13, 14] {
      for minute in stride(from: hour == 13 ? 10 : 0, through: hour == 13 ? 50 : 40, by: 10) {
        fetch("ci", hour, minute, items: 7, fresh: 0)
        fetch("sentry", hour, minute, items: 3, fresh: 0)
        fetch("slack", hour, minute, items: 14, fresh: 0)
      }
    }
    // 14:45 の Backlog は、出力が決まりを外して出し直しで通った。
    let backlog = sampleItems("backlog", 9, at: at(14, 45, 0))
    let backlogRows = Array(backlog.suffix(1)).map { item in
      AutomationPartRow(
        id: "backlog:\(item.id)",
        text: AutomationPrompts.row(
          AutomationItem(
            id: "backlog:\(item.id)", link: item.link, body: item.body, time: item.time)),
        origin: AutomationOrigin(part: "backlog", item: item))
    }
    passes.append(
      AutomationSamplePass(
        part: "backlog", at: at(14, 45, 0),
        outcome: .succeeded(
          .fetch(
            rows: backlogRows,
            lastOutput: backlog.map { AutomationSeen(id: $0.id, link: $0.link) }),
          execution(9),
          breach: AutomationPartPass.Breach(
            lines: [
              AutomationBrokenLine(line: 3, reason: "not a JSON object"),
              AutomationBrokenLine(line: 7, reason: "missing \"link\""),
              AutomationBrokenLine(line: 8, reason: "missing \"link\""),
            ],
            redo: AutomationPartPass.Redo(firstCall: execution(9), lines: [])))))
    process("mine", 14, 45, rows: 1, from: "backlog")
    fetch("mail", 14, 45, items: 2, fresh: 2)
    process("dedupe", 14, 45, rows: 2, from: "mail")
    fetch("ci", 14, 55, items: 7, fresh: 0)
    fetch("slack", 14, 55, items: 14, fresh: 0)
    fetch("github", 14, 55, items: 18, fresh: 2)
    passes.append(
      AutomationSamplePass(
        part: "digest", at: at(14, 56, 0), trigger: .arrival,
        outcome: reported(
          "レビュー依頼が 2 件。#412 認証のリトライを追加（tanaka）、#415 設定画面の文言を直す（sato）。")))

    var contact = agentPart(
      "contact", "連絡", .scheduled(cron("0 13 * * 1-5")), from: ["dedupe"], model: "sonnet",
      instruction: "Slack とメールから、自分への依頼と、自分の返事を待たれているものだけをタスク候補にする。",
      deliver: .taskCandidates)
    contact.inboxLimit = AutomationPart.InboxLimit(maxAgeHours: 24, maxItems: 100)
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
          agentPart(
            "mail", "メール", .scheduled(.every(1800)), tools: ["mcp__gmail__search_threads"],
            instruction: "自分宛のメールを、直近 1 日分取る。", coverage: .newArrivals),
          agentPart(
            "mine", "自分の担当だけ", .arrival, from: ["backlog", "sentry"],
            instruction: "自分が担当のものだけを残す。"),
          agentPart(
            "dedupe", "重複をまとめる", .arrival, from: ["slack", "mail"],
            instruction: "同じ話題のメッセージを 1 行にまとめる。"),
          agentPart(
            "digest", "要約", .arrival, from: ["github"], instruction: "レビュー依頼を 2〜3 行で要約する。",
            deliver: .report),
          agentPart(
            "weekly", "週報", .scheduled(cron("0 17 * * 5")), from: ["github", "ci", "backlog"],
            instruction: "今週の動きを週報にまとめる。", deliver: .report),
          agentPart(
            "dev", "開発", .scheduled(cron("0 9 * * *")), from: ["github", "ci", "mine"],
            model: "sonnet", instruction: "自分が手を動かすべきものだけをタスク候補にする。",
            deliver: .taskCandidates),
          contact,
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

  /// 取得 8 つが 1 つの判定へ入る。
  private static var boardMapWide: AutomationSample {
    let sources = (1...8).map { "src\($0)" }
    return AutomationSample(
      definition: AutomationDefinition(
        name: "取り込みの多い判定", notify: nil,
        parts: sources.map {
          commandPart(
            $0, "取得 \($0.dropFirst(3))", .scheduled(.every(3600)), script: "~/bin/\($0).sh",
            coverage: .newArrivals)
        } + [
          agentPart(
            "judge", "まとめて判定", .arrival, from: sources, instruction: "依頼だけをタスク候補にする。",
            deliver: .taskCandidates)
        ]),
      createdAt: automationAt(14, 30))
  }

  /// 止めている。
  private static var boardMapWeekend: AutomationSample {
    AutomationSample(
      definition: AutomationDefinition(
        name: "週末の依存更新", notify: nil,
        parts: [
          agentPart(
            "update", "依存を更新", .scheduled(cron("0 10 * * 0,6")), tools: ["Bash(npm outdated:*)"],
            instruction: "古くなった依存を調べて、上げてよいものを報告する。", deliver: .report)
        ]),
      createdAt: automationAt(9, 0, daysAgo: 7), paused: true,
      passes: [
        AutomationSamplePass(
          part: "update", at: automationAt(10, 0, daysAgo: 7),
          outcome: worked(.done("react を 18.3.1 へ上げた。")))
      ])
  }
}
