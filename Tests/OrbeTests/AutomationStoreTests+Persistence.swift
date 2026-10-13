import XCTest

@testable import Orbe

/// 自動化と候補の永続——再起動で同じ状態に戻ること。
extension AutomationStoreTests {
  func testStateSurvivesARestart() throws {
    let store = try store(automations: 2)
    let a = Self.item("a")
    commit(store, 1, fetched: [a], proposing: [a])
    _ = try store.setPaused(1, true)
    var steps = Self.definition("受信 2")
    steps.steps = [
      AutomationStep(
        name: "絞り込み", method: .command(BackgroundCommand(script: "jq -c .", directory: "/tmp"))),
      AutomationStep(
        name: "判定",
        method: .agent(AutomationStepAgent(cli: "claude", model: nil, instruction: "判定して"))),
    ]
    _ = try store.replace(2, with: steps)

    let reloaded = AutomationStore()

    XCTAssertEqual(reloaded.automations, store.automations)
    XCTAssertEqual(reloaded.proposals, store.proposals)
    XCTAssertEqual(try reloaded.create(Self.definition(), now: t0).id, 3, "採番位置も戻る")
  }
}

/// 凍結した automations.json。制御 API の `definition`・回の記録も同じ形なので、これと食い違う変更は AI に見える形の変更でもある。
extension AutomationStoreTests {
  private static let frozenFile = #"""
    {
      "version": 1, "nextAutomationId": 5, "nextProposalId": 5,
      "automations": [
        {
          "id": 1,
          "definition": {
            "name": "GitHub: レビュー依頼",
            "trigger": {"everyMinutes": 30},
            "source": {"command": "gh api notifications", "directory": "/repo", "coverage": "currentSet"},
            "steps": [
              {"name": "絞り込み", "command": "jq -c ."},
              {"name": "判定", "agent": "claude", "instruction": "自分がやること"}
            ],
            "sink": {"kind": "taskCandidates"}
          },
          "sinkState": {"accepted": 1, "dismissed": 0},
          "paused": false, "reviewAll": false,
          "createdAt": "2026-10-01T09:00:00.000Z",
          "lastRunAt": "2026-10-02T09:30:00.000Z",
          "lastSucceededAt": "2026-10-02T09:00:00.000Z",
          "lastFetched": [{"id": "a", "link": "https://example.com/a"}],
          "runs": [
            {
              "startedAt": "2026-10-02T09:30:00.000Z", "endedAt": "2026-10-02T09:30:01.000Z",
              "trigger": "now",
              "source": {
                "commandLine": "gh api notifications", "ending": "exited 1", "count": 0,
                "rejected": {"count": 0, "reasons": []}
              },
              "steps": [],
              "failure": "the source exited 1"
            },
            {
              "startedAt": "2026-10-02T09:00:00.000Z", "endedAt": "2026-10-02T09:00:05.000Z",
              "trigger": "schedule",
              "source": {
                "commandLine": "gh api notifications", "ending": "exited 0", "count": 2,
                "rejected": {"count": 1, "reasons": ["line 3: not JSON"]}
              },
              "fresh": 2,
              "steps": [
                {
                  "name": "絞り込み", "commandLine": "jq -c .", "ending": "exited 0", "count": 1,
                  "rejected": {"count": 0, "reasons": []}
                },
                {
                  "name": "判定", "commandLine": "claude -p", "ending": "exited 0", "count": 1,
                  "rejected": {"count": 0, "reasons": []}
                }
              ],
              "sink": {
                "kind": "taskCandidates", "proposed": 1, "resolved": 0, "withdrawn": 1,
                "rejected": {"count": 0, "reasons": []}
              }
            }
          ]
        },
        {
          "id": 2,
          "definition": {
            "name": "日報の下書き",
            "trigger": {"dailyAt": ["23:00"]},
            "steps": [],
            "sink": {
              "kind": "command", "command": "~/bin/daily-note.sh", "directory": "/Users/me",
              "timeoutMinutes": 10
            }
          },
          "paused": false, "reviewAll": false,
          "createdAt": "2026-10-01T09:30:00.000Z",
          "lastRunAt": "2026-10-01T14:00:00.000Z",
          "lastSucceededAt": "2026-10-01T14:00:00.000Z",
          "lastFetched": [],
          "runs": [
            {
              "startedAt": "2026-10-01T14:00:00.000Z", "endedAt": "2026-10-01T14:00:02.000Z",
              "trigger": "schedule", "steps": [],
              "sink": {"kind": "command", "commandLine": "~/bin/daily-note.sh", "ending": "exited 0", "count": 0}
            }
          ]
        },
        {
          "id": 3,
          "definition": {
            "name": "Slack: 自分宛",
            "trigger": {"dailyAt": ["09:00", "13:00"]},
            "source": {
              "agent": "claude", "model": "haiku", "tools": ["mcp__slack__search"],
              "request": "自分宛の DM", "coverage": "newArrivals"
            },
            "steps": [{"name": "判定", "agent": "claude", "model": "opus", "instruction": "返事が要るもの"}],
            "sink": {"kind": "taskCandidates"}
          },
          "sinkState": {"accepted": 0, "dismissed": 1},
          "paused": true, "reviewAll": true,
          "createdAt": "2026-10-01T10:00:00.000Z",
          "lastFetched": [], "runs": []
        },
        {
          "id": 4,
          "definition": {
            "name": "開いている PR の要約",
            "trigger": {"dailyAt": ["18:00"]},
            "steps": [{"name": "要約", "agent": "claude", "instruction": "開いている PR を要約する"}],
            "sink": {"kind": "report"},
            "notify": "menuBar"
          },
          "paused": false, "reviewAll": false,
          "createdAt": "2026-10-01T11:00:00.000Z",
          "lastRunAt": "2026-10-02T18:00:00.000Z",
          "lastSucceededAt": "2026-10-02T18:00:00.000Z",
          "lastFetched": [],
          "runs": [
            {
              "startedAt": "2026-10-02T18:00:00.000Z", "endedAt": "2026-10-02T18:00:30.000Z",
              "trigger": "schedule",
              "steps": [
                {
                  "name": "要約", "commandLine": "claude -p", "ending": "exited 0", "count": 0,
                  "rejected": {"count": 0, "reasons": []}
                }
              ],
              "sink": {"kind": "report"}
            },
            {
              "startedAt": "2026-10-01T18:00:00.000Z", "endedAt": "2026-10-01T18:00:30.000Z",
              "trigger": "schedule",
              "steps": [
                {
                  "name": "要約", "commandLine": "claude -p", "ending": "exited 0", "count": 1,
                  "rejected": {"count": 0, "reasons": []}
                }
              ],
              "sink": {"kind": "report", "text": "開いている PR は 2 件。\n- #412 レビュー待ち"}
            }
          ]
        }
      ],
      "proposals": [
        {
          "id": 1, "automationId": 1, "title": "a に返信する", "due": "2026-10-05",
          "item": {"id": "a", "link": "https://example.com/a", "body": "a の本文", "time": "2026-10-02T08:00:00.000Z"},
          "proposedAt": "2026-10-02T09:00:05.000Z", "state": "open"
        },
        {
          "id": 2, "automationId": 1, "title": "b を見る",
          "item": {"id": "b", "link": "https://example.com/b", "body": "b の本文", "time": "2026-10-01T08:00:00.000Z"},
          "proposedAt": "2026-10-01T09:00:05.000Z", "state": "accepted", "taskId": 7
        },
        {
          "id": 3, "automationId": 3, "title": "c を見る",
          "item": {"id": "c", "link": "https://example.com/c", "body": "c の本文", "time": "2026-10-01T08:00:00.000Z"},
          "proposedAt": "2026-10-01T09:00:05.000Z", "state": "dismissed"
        },
        {
          "id": 4, "automationId": 3, "title": "d を見る",
          "item": {"id": "d", "link": "https://example.com/d", "body": "d の本文", "time": "2026-10-01T08:00:00.000Z"},
          "proposedAt": "2026-10-01T09:00:05.000Z", "state": "resolved"
        }
      ]
    }
    """#

  /// 見本は読め、書き戻しても同じ JSON になる。
  ///
  /// 壊れると何が起きるか: 鍵の改名や必須化を読み書きの両側に入れると、往復のテストは通ったまま、手元の automations.json が
  /// 読めずに退避され、自動化と候補がすべて消えた状態で起動する。片側だけ鍵を読み飛ばすと、次の保存でその値が黙って消える。
  func testTheFrozenFileLoadsAndSavesBackUnchanged() throws {
    let frozen = Data(Self.frozenFile.utf8)
    try frozen.write(to: automationsFile())

    let loaded = try XCTUnwrap(AutomationPersistence.load(), "見本が読めずに退避された")
    let written = try AutomationWire.encoder().encode(loaded)

    XCTAssertEqual(
      try JSONSerialization.jsonObject(with: written) as? NSDictionary,
      try JSONSerialization.jsonObject(with: frozen) as? NSDictionary)
  }
}
