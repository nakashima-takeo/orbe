# 実戦パターン集（非網羅）

グラフ設計と指示文の具体例。依頼に合わせて組み替えて使う。例に当てはめようとして品質を落とさない。

本番の定義で Orbe の Home（~/orbe 等）配下のスクリプトを呼ぶときは、`list_workspaces` で得た Home の ID を `workspace` に、"scripts" を `directory` に指定し、`command` は python3 ./github-reviews.py のように相対パスで書く（下の JSON 例は特定の workspace ID に依存しない参考形として、OS のホームディレクトリからのパス ~/orbe/scripts/... で書いている）。定義の必須項目や検証規則は、正本である `set_automation` の説明に従う。

---

## パターン 1: スクリプトによる文脈付き取得 → 意味判断による判定（`currentSet`）

タイトルだけ抽出する貧弱な取得をやめ、ローカルスクリプトで本文・直近コメント・レビュー状態・CI をまとめて整形し、bot・draft・自分の既承認 PR を取得段階で決定論的に除外する。LLM 判定には本当に文脈判断が要る PR だけが渡る。

```json
{
  "name": "GitHub: 自分の対応が必要なレビュー依頼",
  "notify": "menuBar",
  "nodes": [
    {
      "key": "reviews",
      "name": "未対応のレビュー依頼を文脈付きで取る",
      "trigger": {"kind": "interval", "minutes": 30},
      "command": "python3 ~/orbe/scripts/github-reviews.py",
      "coverage": "currentSet",
      "timeoutMinutes": 3
    },
    {
      "key": "judge",
      "name": "タスク候補にするか判定する",
      "trigger": {"kind": "arrival"},
      "from": [{"node": "reviews", "maxAgeHours": 336}],
      "maxItems": 30,
      "model": "sonnet",
      "deliver": "taskCandidates",
      "instruction": "タスクにする: 自分のレビュー・設計判断・再レビューが実際に求められている PR（他者が未解決の指摘を出して作成者待ちの状態は除く）\nタスクにしない: 依存更新の自動 PR、他レビュアーの修正依頼後に作成者が未修正のままの PR、WIP・検証用の PR\nタイトル: 「レビュー: <リポジトリ名> #<番号> <変更の要点を確認する行動>」\n理由: PR の変更要点と、なぜ今自分の確認が必要かを本文・最新コメントの事実から 1〜2 文で書く\n期限: 本文やコメントにリリース日・締切が明示されていれば算出する。無ければ省く\n付け先: リポジトリ名に一致する workspace があればそれ。無ければ省く"
    }
  ]
}
```

---

## パターン 2: 増分取得（`newArrivals`＋`ORBE_SINCE`＋スレッド文脈）→ 判定・自動で対応済みにする処理

チャットや通知ログのように、対応後も取得結果から項目が消えないイベント追記型のソースでは、`ORBE_SINCE` を使って前回以降の更新を取り、同じスレッドの後続返信や自分の返信も同じ `link`（スレッド先頭の permalink）で出力する。

```json
{
  "name": "社内チャット: 自分宛ての依頼を拾う",
  "notify": "menuBar",
  "nodes": [
    {
      "key": "messages",
      "name": "自分宛てと関連スレッドを取る",
      "trigger": {"kind": "interval", "minutes": 15},
      "command": "python3 ~/orbe/scripts/chat-mentions.py",
      "coverage": "newArrivals",
      "retentionDays": 30,
      "timeoutMinutes": 3
    },
    {
      "key": "judge",
      "name": "依頼と決着を判定する",
      "trigger": {"kind": "arrival"},
      "from": [{"node": "messages", "maxAgeHours": 168}],
      "maxItems": 50,
      "model": "sonnet",
      "deliver": "taskCandidates",
      "instruction": "タスクにする: 自分への作業依頼・質問・承認や意思決定の求めで、スレッド内でまだ解決していないもの\nタスクにしない: お礼・挨拶・了解のみ・自動通知・自分が既に回答または引き取り完了を返信済みのもの・他者が引き取って決着したもの\nタイトル: 「<送り手>: <具体的に何をするか>」（動詞で終える）\n理由: 誰がどの件について何を求めているかを本文の事実から 1〜2 文で書く\n期限: 文面に具体的な日時・曜日があれば現在日時から算出する。無ければ省く\n付け先: 本文のリポジトリ名やプロジェクト名に明確に一致する workspace があればそれ。迷えば省く\n対応済み: 同じ link の新しい行で、送り手が取り下げた・解決を報告した・自分が完了を返信したことが確認できた判断待ち候補は対応済みにする"
    }
  ]
}
```

---

## パターン 3: MCP 取得（CLI 不可）＋複数ソース統合の定時仕分けと即時速報

認証が MCP サーバーの中にしか無く、コマンドで読めないソースだけ、軽い agent（読み取り専用ツール限定）で取得する。取得はソースごとの頻度で回し、判定は人がさばく時間帯に cron でまとめて実行して費用を抑えつつ、同じ `link` の重複候補を 1 件に統合する。

```json
{
  "name": "朝の仕分けと急ぎの速報",
  "notify": "menuBar",
  "nodes": [
    {
      "key": "github",
      "name": "GitHub の担当課題とレビュー依頼を取る",
      "trigger": {"kind": "interval", "minutes": 20},
      "command": "python3 ~/orbe/scripts/github-inbox.py",
      "coverage": "currentSet",
      "timeoutMinutes": 3
    },
    {
      "key": "slack",
      "name": "Slack の自分宛てとスレッド返信を取る",
      "trigger": {"kind": "interval", "minutes": 30},
      "model": "haiku",
      "tools": ["mcp__slack__slack_search_public_and_private", "mcp__slack__slack_get_thread_replies"],
      "instruction": "自分へのメンション・DM と、関連するスレッドの後続返信（自分の返信を含む）を取得する。現在日時と前回成功時刻があればそれ以降の更新を対象にし、初回は直近 24 時間に限る。各項目は id に「<channel_id>:<ts>」、link にスレッド先頭メッセージの permalink（同一スレッドは同じ link）、body に「#<チャンネル> / <送り手>: <本文の要点>（返信があれば最新 3 件を要約）」、time に ISO 8601 の送信時刻を入れる。bot の自動通知と絵文字のみの投稿は省く。",
      "coverage": "newArrivals",
      "retentionDays": 30,
      "timeoutMinutes": 5
    },
    {
      "key": "triage",
      "name": "平日の朝にまとめて判定する",
      "trigger": {"kind": "cron", "expression": "0 9 * * 1-5"},
      "from": [
        {"node": "github", "maxAgeHours": 336},
        {"node": "slack", "maxAgeHours": 168}
      ],
      "maxItems": 80,
      "model": "sonnet",
      "deliver": "taskCandidates",
      "instruction": "タスクにする: 自分の対応・判断・返信が未完了の依頼、質問、レビュー依頼\nタスクにしない: 既に対応済みのやり取り、周知・共有のみ、他者間で完結した会話、自動通知\nタイトル: 「<対象または送り手>: <次の具体的な行動>」\n理由: 何が依頼・阻害されているかを本文の事実から 1〜2 文で書く\n期限: 文面に明確な期日があれば現在日時から算出する。無ければ省く\n付け先: リポジトリ名やプロジェクト名から明確に一致する workspace があればそれ。迷えば省く\n対応済み: 同じ link の新しい行で解決・取り下げ・自分の完了返信が確認できた判断待ち候補は対応済みにする"
    },
    {
      "key": "urgent_alert",
      "name": "GitHub の緊急案件だけ即座に知らせる",
      "trigger": {"kind": "arrival"},
      "from": [{"node": "github", "maxAgeHours": 24}],
      "maxItems": 20,
      "model": "haiku",
      "deliver": "report",
      "instruction": "障害対応・本番修正・urgent ラベル付きなど即対応が要る案件だけを報告する。該当が無ければ報告しない。1 行目は「緊急 N 件: <最重要の 1 件の要点>」とし、2 行目以降に案件ごとの状況と URL を 1 行ずつ並べる。"
    }
  ]
}
```

---

## パターン 4: 後から変わる属性を拾う多段パイプライン（決定論的フィルタを行う `currentSet` の処理ノード）

ラベルや状態のように後から付く属性で絞る場合、`take` が `new` の下流ノードには中身が変わった行（項目）が再配送されない。処理ノードで `take` を `all` にし、かつ `coverage` を `currentSet` にすることで、後から条件を満たした行が下流へ届き、条件から外れたら候補も自動で取り下げられる。

```json
{
  "name": "GitHub: 急ぎラベルの付いた担当課題",
  "notify": "notificationCenter",
  "nodes": [
    {
      "key": "issues",
      "name": "担当中の課題を取る",
      "trigger": {"kind": "interval", "minutes": 15},
      "command": "python3 ~/orbe/scripts/github-assigned-issues.py",
      "coverage": "currentSet"
    },
    {
      "key": "urgent",
      "name": "urgent・P0 ラベルだけに絞る",
      "trigger": {"kind": "arrival"},
      "from": [{"node": "issues", "take": "all"}],
      "command": "jq -c 'select((.labels // []) | any(. == \"urgent\" or . == \"P0\"))'",
      "coverage": "currentSet"
    },
    {
      "key": "judge",
      "name": "タスク候補を作る",
      "trigger": {"kind": "arrival"},
      "from": ["urgent"],
      "maxItems": 20,
      "model": "sonnet",
      "deliver": "taskCandidates",
      "instruction": "タスクにする: 自分が手を動かす必要のある急ぎの課題\nタスクにしない: 質問や議論の呼びかけのみで実装・調査の作業が発生しない課題\nタイトル: 「[急ぎ] <リポジトリ名> #<番号> <対応内容>」\n理由: 影響範囲と今すぐ対応すべき根拠を本文・ラベルから 1〜2 文で書く\n期限: 本文に期日があれば算出する。無ければ省く\n付け先: リポジトリ名に一致する workspace があればそれ。無ければ省く"
    }
  ]
}
```

---

## パターン 5: 定時の要約報告（`take` `all`＋ゼロノイズ設計）

報告は 1 行目がそのまま通知本文になる。変化や対象が無い回は報告しないという条件を明示し、定例スパムを防ぐ。

```json
{
  "name": "夕方チェック: 滞留している自分の PR",
  "notify": "menuBar",
  "nodes": [
    {
      "key": "my_prs",
      "name": "開いている自分の PR と状態を取る",
      "trigger": {"kind": "interval", "minutes": 60},
      "command": "python3 ~/orbe/scripts/github-my-prs.py",
      "coverage": "currentSet"
    },
    {
      "key": "summary",
      "name": "平日の夕方に滞留 PR をまとめる",
      "trigger": {"kind": "cron", "expression": "0 18 * * 1-5"},
      "from": [{"node": "my_prs", "take": "all"}],
      "maxItems": 30,
      "model": "sonnet",
      "deliver": "report",
      "instruction": "開いている自分の PR のうち、CI 失敗・修正依頼あり・24 時間以上レビュー待ちのものを優先順にまとめる。該当する PR が 1 件も無ければ報告しない。1 行目は「要対応 PR N 件（CI 失敗 X / 修正待ち Y / 滞留 Z）」のように具体的な数で始め、2 行目以降に各 PR の状態・次の行動・URL を 1 行ずつ書く。"
    }
  ]
}
```

---

## パターン 6: 冪等な自律作業と安全な外部操作

作業ノードでは失敗時の再実行で二重実行が起きうるため、実行前に既存状態を確認する手順と最小権限ツールを明示する。

```json
{
  "name": "朝のレビュー待ち共有（冪等作業）",
  "notify": "menuBar",
  "nodes": [
    {
      "key": "post_digest",
      "name": "レビュー待ち PR を #dev-review へ共有する",
      "trigger": {"kind": "cron", "expression": "0 9 * * 1-5"},
      "model": "sonnet",
      "tools": [
        "Bash(gh search prs:*)",
        "mcp__slack__slack_get_channel_history",
        "mcp__slack__slack_send_message"
      ],
      "deliver": "report",
      "timeoutMinutes": 5,
      "instruction": "1. まず #dev-review の当日分の履歴を確認し、今日すでに自分が同じレビュー待ち一覧を投稿済みなら何も投稿せず終了する。\n2. 自分がレビュー依頼されている open・非 draft の PR を gh search prs で調べる。0 件なら何も投稿せず終了する。\n3. 該当 PR をリポジトリ・番号・タイトル・URL の箇条書きで #dev-review のみに投稿する（他チャンネルへは投稿しない）。\n4. 報告の 1 行目は「#dev-review にレビュー待ち N 件を共有」とし、投稿した PR 一覧を簡潔に残す。"
    }
  ]
}
```

```json
{
  "name": "新規担当課題をローカル連携スクリプトへ送る",
  "nodes": [
    {
      "key": "issues",
      "name": "担当中の課題を取る",
      "trigger": {"kind": "interval", "minutes": 15},
      "command": "python3 ~/orbe/scripts/github-assigned-issues.py",
      "coverage": "currentSet"
    },
    {
      "key": "dispatch",
      "name": "新規課題を外部へ送信する",
      "trigger": {"kind": "arrival"},
      "from": [{"node": "issues", "maxAgeHours": 72}],
      "maxItems": 20,
      "command": "python3 ~/orbe/scripts/dispatch-issues.py",
      "deliver": "none",
      "timeoutMinutes": 3
    }
  ]
}
```
