import Foundation

@testable import Orbe

/// ボードの自動化の fixture（4 件: 前回が失敗・候補あり・新しい項目なし・止めている）。今と今日は提案タブと同じ
/// （2025-10-04 15:00）。走らせ役は `automationRunner` の部品が終わらない偽物で、本物の claude は起きない。
extension DesignSceneFixtures {
  private static func agentFetch(
    _ tool: String, _ instruction: String, _ coverage: AutomationCoverage,
    _ trigger: AutomationNode.Trigger
  ) -> AutomationDefinition.Node {
    agentPart(
      "fetch", "取る", trigger, model: "haiku", tools: [tool], instruction: instruction,
      coverage: coverage)
  }

  private static var boardCreated: Date { automationAt(9, 0, daysAgo: 7) }

  static func boardAutomationSamples() -> [AutomationSample] {
    [boardSlack, boardGitHub, boardBacklog, boardGmail]
  }

  /// 候補ありで成功（「今すぐ」の回を含む）。
  private static var boardSlack: AutomationSample {
    let at = automationAt
    return AutomationSample(
      definition: candidatesDefinition(
        "Slack: 自分宛の DM",
        fetch: agentFetch(
          "mcp__slack__search_messages", "自分宛の DM とメンションを、新しい順に 50 件取る。", .newArrivals,
          .scheduled(.every(1800))),
        instruction: "自分に頼まれたことだけをタスクにする。お礼や雑談は外す。"),
      createdAt: boardCreated,
      passes: round("slack", at: at(12, 30, 0), items: 9, fresh: 2, proposed: 1)
        + round(
          "slack", at: at(13, 0, 0), items: 0, fresh: 0,
          failure: "Slack API rate limited")
        + round("slack", at: at(13, 30, 0), items: 10, fresh: 2)
        + round("slack", at: at(14, 0, 0), items: 11, fresh: 1)
        + round("slack", at: at(14, 12, 0), items: 11, fresh: 0, trigger: .now)
        + round("slack", at: at(14, 45, 0), items: 14, fresh: 3, proposed: 2))
  }

  /// 新しい項目なしで成功（コマンド）。
  private static var boardGitHub: AutomationSample {
    let at = automationAt
    return AutomationSample(
      definition: candidatesDefinition(
        "GitHub: レビュー依頼",
        fetch: commandPart(
          "fetch", "取る", .scheduled(.every(3600)),
          script: "gh search prs --review-requested=@me --json url,title", coverage: .currentSet),
        instruction: "すべてタスクにする。期限は付けない。"),
      createdAt: boardCreated,
      passes: round("github", at: at(13, 0, 0), items: 2, fresh: 1, proposed: 1)
        + round("github", at: at(14, 20, 0), items: 2, fresh: 0))
  }

  /// 前回が失敗。
  private static var boardBacklog: AutomationSample {
    let at = automationAt
    return AutomationSample(
      definition: candidatesDefinition(
        "Backlog: 担当課題",
        fetch: agentFetch(
          "mcp__backlog__get_issues", "自分が担当の未完了の課題を、更新の新しい順に 30 件取る。", .currentSet,
          .scheduled(cron("0 9,13 * * *"))),
        instruction: "期限のある課題と、自分がコメントで頼まれた課題をタスクにする。"),
      createdAt: boardCreated,
      passes: round("backlog", at: at(9, 0, 0), items: 12, fresh: 1, proposed: 1)
        + round(
          "backlog", at: at(13, 0, 0), items: 0, fresh: 0,
          failure: "Backlog の認証が切れています（401 Unauthorized）"))
  }

  /// 止めている。
  private static var boardGmail: AutomationSample {
    AutomationSample(
      definition: candidatesDefinition(
        "Gmail: 請求書",
        fetch: agentFetch(
          "mcp__gmail__search_threads", "請求書と支払い依頼のメールを、直近 3 日分取る。", .newArrivals,
          .scheduled(cron("0 10 * * 1-5"))),
        instruction: "請求書の受領と支払い依頼をタスクにし、支払期日を期限にする。"),
      createdAt: boardCreated, paused: true,
      passes: round("gmail", at: automationAt(10, 0, daysAgo: 1), items: 3, fresh: 1, proposed: 1))
  }

  /// まだ回っていない（作ったばかり）。
  private static var boardDraft: AutomationSample {
    AutomationSample(
      definition: candidatesDefinition(
        "日報の素材",
        fetch: commandPart(
          "fetch", "取る", .scheduled(cron("0 23 * * *")), script: "~/bin/daily-notes.sh --today",
          directory: "/Users/me/notes", coverage: .newArrivals)),
      createdAt: automationAt(14, 50))
  }

  /// 見本と突き合わせる一覧: 4 件にまだ回っていないものを足す。
  static func boardDesignSamples() -> [AutomationSample] {
    boardAutomationSamples() + [boardDraft]
  }

  /// 取得の指示文・使えるツール・コマンドと作業ディレクトリが長く、詳細がスクロールする。回の記録は部品ごとに 20 件。
  static func boardLongSamples() -> [AutomationSample] {
    var samples = boardAutomationSamples()
    samples[2].definition.parts[0] = agentPart(
      "fetch", "取る", .scheduled(cron("0 9,13 * * *")), model: "haiku",
      tools: [
        "mcp__backlog__get_issues", "mcp__backlog__get_issue_comments",
        "mcp__backlog__get_project_list", "mcp__backlog__get_users",
        "mcp__backlog__get_notifications",
      ],
      instruction: (1...8).map { "\($0). 自分が担当の未完了の課題を、更新の新しい順に 30 件取る。期限の近いものを先に。" }
        .joined(separator: "\n"), coverage: .currentSet)
    samples[2].passes =
      (1...17).reversed().flatMap {
        round(
          "backlog", at: automationAt(13, 0, daysAgo: $0), items: 10 + $0 % 3, fresh: $0 % 2,
          proposed: $0 % 2)
      } + samples[2].passes
    samples[1].definition.parts[0] = commandPart(
      "fetch", "取る", .scheduled(.every(3600)),
      script: (1...6).map {
        "gh search prs --review-requested=@me --json url,title,body --limit \($0 * 10) \\"
      }
      .joined(separator: "\n") + "\n  | jq -c '.[] | {id: .url, link: .url, body: .title}'",
      directory:
        "/Users/someone/work/very/long/path/to/the/repository/that/wraps/onto/the/next/line",
      coverage: .currentSet)
    samples[1].passes += round("github", at: automationAt(14, 40), items: 999, fresh: 0)
    return samples
  }
}

/// 見本『日報の下書き』（入力の無い副作用のコマンド）と、取得 → 要約 → 副作用のコマンド。副作用のコマンドは走った回を
/// 「完了」と読む。
extension DesignSceneFixtures {
  /// 毎晩 23 時にコマンドだけを走らせる。
  static func boardDailyNoteExample() -> AutomationSample {
    AutomationSample(
      definition: AutomationDefinition(
        name: "日報の下書き", notify: nil,
        parts: [
          commandPart(
            "note", "日報を書く", .scheduled(cron("0 23 * * *")), script: "~/bin/daily-note.sh",
            directory: "/Users/me/notes", deliver: .sideEffect)
        ]),
      createdAt: boardCreated,
      passes: (1..<20).reversed().map { daysAgo in
        AutomationSamplePass(
          part: "note", at: automationAt(23, 0, daysAgo: daysAgo),
          outcome: daysAgo == 3
            ? failed("daily-note: ~/notes is not writable")
            : sideEffected(0))
      })
  }

  /// 取得の後に要約の処理を挟み、副作用のコマンドへ要約の行を渡す。新しい項目の無い回は先へ流れない。
  static func boardMergedPostExample() -> AutomationSample {
    let at = { (hours: Int) in automationAt(14, 30).addingTimeInterval(TimeInterval(-3600 * hours))
    }
    var passes: [AutomationSamplePass] = []
    for (hours, items, fresh) in [(3, 3, 3), (2, 3, 1), (1, 3, 0), (0, 5, 2)] {
      let (all, new) = sampleRound("merged", at: at(hours), items: items, fresh: fresh)
      passes.append(
        AutomationSamplePass(
          part: "fetch", at: at(hours), outcome: fetched(all),
          kept: Array(all.prefix(items - fresh))))
      guard !new.isEmpty else { continue }
      passes.append(
        AutomationSamplePass(
          part: "summary", at: at(hours).addingTimeInterval(60), trigger: .arrival,
          outcome: processed([], read: new.count), take: new.count, passThrough: new.count))
      passes.append(
        AutomationSamplePass(
          part: "post", at: at(hours).addingTimeInterval(120), trigger: .arrival,
          outcome: sideEffected(new.count)))
    }
    return AutomationSample(
      definition: AutomationDefinition(
        name: "GitHub: マージした PR を Slack へ", notify: nil,
        parts: [
          commandPart(
            "fetch", "マージした PR を取る", .scheduled(.every(3600)),
            script: "gh search prs --merged --author=@me --json url,title", coverage: .newArrivals),
          agentPart(
            "summary", "要約", .arrival, from: ["fetch"], instruction: "PR ごとに 1 行の要約を付ける。"),
          commandPart(
            "post", "Slack へ投稿", .arrival, from: ["summary"], script: "~/bin/post.sh '#dev-log'",
            deliver: .sideEffect),
        ]),
      createdAt: boardCreated, passes: passes)
  }
}

/// 見本『段の多い例』『一番単純な例』の自動化。段の多い例は取得と処理 2 つ（コマンド・既定のモデルの agent）と判定を持ち、
/// 一番単純な例は取得と判定だけ。
extension DesignSceneFixtures {
  static func boardStepsExample() -> AutomationSample {
    let at = { (minutes: Int) in
      automationAt(14, 55).addingTimeInterval(TimeInterval(-60 * minutes))
    }
    // 取得の回だけを置く（判定は処理の部品の先にあり、取得の行は処理が読めば取る行になる）。
    let passes = (0..<20).reversed().map { n -> AutomationSamplePass in
      let fresh = n.isMultiple(of: 3) ? 2 : 0
      let (all, _) = sampleRound("dm", at: at(n * 10), items: 6, fresh: fresh)
      return AutomationSamplePass(
        part: "fetch", at: at(n * 10), outcome: fetched(all), kept: Array(all.prefix(6 - fresh)))
    }
    return AutomationSample(
      definition: AutomationDefinition(
        name: "自分宛ての Slack DM", notify: nil,
        parts: [
          commandPart(
            "fetch", "Slack の DM を取る", .scheduled(.every(600)), script: "~/bin/slack-dm.sh",
            coverage: .newArrivals),
          commandPart(
            "bots", "bot の投稿を除く", .arrival, from: ["fetch"],
            script: "jq 'select(.bot_id == null)'"),
          agentPart("chat", "雑談を除く", .arrival, from: ["bots"], instruction: "挨拶やお礼だけのメッセージは除く。"),
          agentPart(
            "judge", "依頼をタスク候補にする", .arrival, from: ["chat"],
            instruction: "自分に何かを頼んでいるものだけを候補にする。\n期限が書かれていれば期限に入れる。",
            deliver: .taskCandidates),
        ]),
      createdAt: boardCreated,
      passes: passes)
  }

  static func boardSimpleExample() -> AutomationSample {
    AutomationSample(
      definition: candidatesDefinition(
        "毎朝の PR 報告",
        fetch: commandPart(
          "fetch", "PR を取る", .scheduled(cron("0 9 * * *")), script: "gh pr list --json url",
          coverage: .currentSet)),
      createdAt: boardCreated,
      passes: (0..<20).reversed().flatMap {
        round("pr", at: automationAt(9, 0, daysAgo: $0), items: 1, fresh: 1, proposed: 1)
      })
  }
}
