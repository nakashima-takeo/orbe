# 型 — 自動化の設計の参考

回のたびに走るのは取得元だけ。処理の段と出力先は、前の回に無かった項目がある回だけ走る（取得元の無い自動化は、トリガーのたびに出力先が走る）。だから取得元を agent にすると回のたびに LLM が起き、取得元をコマンドにすれば LLM は新しい項目があるときだけ起きる。型はこの構造から導いた形で、頼みに合わなければ外れてよい。外れるときは、外れた理由と代替を人に示す。

出どころ 1 つに自動化 1 つ。範囲（組織・状態・期間・宛先）は取得の条件で切る。

## 型 1: 見張ってタスク候補にする

「○○の△△を拾ってタスクにして」。取得元のコマンドが毎回走り、新しい項目があった回だけ判定の agent が起きて候補を作る。

```json
{"name": "GitHub: 自分へのレビュー依頼",
 "trigger": {"everyMinutes": 30},
 "source": {"command": "gh search prs --review-requested=@me --state open --json url,title,repository,updatedAt --jq '.[] | {id: .url, link: .url, body: (.repository.nameWithOwner + \" \" + .title), time: .updatedAt}'",
            "coverage": "currentSet"},
 "steps": [{"name": "判定", "instruction": "タスクにする: 自分がレビューする PR\nタスクにしない: draft の PR・bot が開いた PR\nタイトル: 「レビュー: <リポジトリ名> #<番号> <タイトル>」\n期限: 付けない\n付け先: リポジトリ名と同じ名前の workspace があればそれ。それ以外は省く"}],
 "sink": {"kind": "taskCandidates"}}
```

- `coverage`: 取得結果がその時点の全体（担当の未完了・レビュー待ち）なら `currentSet`。新着だけ（DM・メンション）なら `newArrivals` にし、コマンドは環境変数 `ORBE_SINCE` 以降を取る。
- 判定の agent は `model` を省く（sonnet で走る）。

### 判定の指示文

```
タスクにする: 自分への依頼・質問・レビューや確認の頼み・判断を求められているもの
タスクにしない: お礼・挨拶・周知・bot の通知・自分で完結した報告
タイトル: 「<送り手>: <何をするか>」。何をするかは動詞で終える
期限: 文面にあればそれ
付け先: Jリーグの話なら jleague-line-app。それ以外は省く
```

「タスクにしない」が空の指示文は判定になっていない。状態・担当・期間のように条件で落とせるものは取得の条件で落とし、判定には読まないと決まらないものだけを渡す。

## 型 2: MCP でしか読めない出どころを見張ってタスク候補にする

認証が MCP サーバーの中にしか無く、コマンドでは読めない出どころ（Slack の OAuth 接続など）。取得元を軽い agent にし、読み取りのツールだけを名指しする。回のたびに LLM が起きるので、そのことを人に伝える。

```json
{"name": "Slack: 自分へのメンションと DM",
 "trigger": {"everyMinutes": 30},
 "source": {"agent": "claude", "tools": ["mcp__slack__slack_search_public_and_private"],
            "request": "自分へのメンションと DM を、渡された開始時刻以降で取る。id はチャンネル ID と ts の組、link は permalink、body は「#チャンネル / 送り手: 本文」、time は送信時刻。",
            "coverage": "newArrivals"},
 "steps": [{"name": "判定", "instruction": "…型 1 と同じ形…"}],
 "sink": {"kind": "taskCandidates"}}
```

取得元の agent は `model` を省く（haiku で走る）。`request` に、取る範囲と 1 項目の作り方（id・link・body・time に何を入れるか）を書く。

## 型 3: 定時にまとめて報告する

「毎日 18 時に○○を要約して」。cron で回り、毎回全件を取って、agent が文章にする。

```json
{"name": "GitHub: 開いている PR の要約",
 "trigger": {"cron": "0 18 * * 1-5"},
 "source": {"command": "gh pr list --author @me --json url,title,updatedAt --jq '.[] | {id: .url, link: .url, body: .title, time: .updatedAt}'",
            "coverage": "everything"},
 "steps": [{"name": "まとめ", "instruction": "PR を状態ごとに 1 行ずつ。止まっているものを先に。"}],
 "sink": {"kind": "report"}}
```

## 型 4: 定時にツールで仕事をさせる

「平日 9 時に○○を△△へ投稿して」。cron で回り、使い捨ての agent が名指しのツールで仕事をする。届いた行は agent に渡らないので、対象は agent 自身にツールで調べさせる。

```json
{"name": "レビュー待ち PR を Slack に投稿",
 "trigger": {"cron": "0 9 * * 1-5"},
 "steps": [],
 "sink": {"kind": "agent", "tools": ["Bash(gh search prs:*)", "mcp__slack__slack_send_message"],
          "request": "自分がレビュー待ちの open な PR を gh で調べ、1 行ずつまとめて Slack の #dev-me に投稿する。無ければ投稿しない。"}}
```

名指しは最小にする。書き込みのツールは、agent が読んだ文面に仕込まれた指示で使われうる。

## 型 5: 定時にコマンドを走らせる

「毎晩 23 時に○○.sh を実行して」。

```json
{"name": "日報の下書き",
 "trigger": {"cron": "0 23 * * *"},
 "steps": [],
 "sink": {"kind": "command", "command": "~/bin/daily-note.sh"}}
```

## 組み合わせ

型は部品の組み合わせなので、頼みに合わせて組み替える（例は網羅ではない）:

- 届いたら作業: 型 1 の取得元と段に、出力先を agent かコマンドにする。新しい項目があった回だけ出力先が走る。
- 見張って報告: 型 1 の取得元に、出力先を報告にする。
- 他。
