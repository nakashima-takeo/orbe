# 型 — 自動化の設計の参考

自動化はノードのグラフで、ノードはそれぞれ自分の予定で動く。予定のある取得は予定のたびに実行され、「届いたら」（`arrival`）のノードは、上流の行が変わったときだけ実行される（`take` が `new` なら、新しい行が届いたときだけ）。だから取得を agent にすると回ごとに LLM が起動し、取得をコマンドにすれば、LLM は上流の行が変わったときだけ起動する。型はこの構造から導いた形で、依頼に合わなければ外れてよい。外れるときは、外れた理由と代替を人に示す。

どの JSON も、そのまま `set_automation` の定義として通る。ノードの欄の意味と組み合わせの規則は `set_automation` の説明にある。

## 型 1: 見張ってタスク候補にする

「○○の△△を拾ってタスクにして」。取得のコマンドが予定どおり実行され、新しい行があったときだけ判定の agent が起動して候補を作る。

```json
{"name": "GitHub: 自分へのレビュー依頼",
 "nodes": [
  {"key": "requests", "name": "レビュー依頼を取る", "trigger": {"kind": "interval", "minutes": 30},
   "command": "gh search prs --review-requested=@me --state open --draft=false --json url,title,repository,updatedAt,author --jq '.[] | select(.author.type != \"Bot\") | {id: .url, link: .url, body: (.repository.nameWithOwner + \" \" + .title), time: .updatedAt}'",
   "coverage": "currentSet"},
  {"key": "judge", "name": "タスクにするか決める", "trigger": {"kind": "arrival"},
   "from": ["requests"], "model": "sonnet", "deliver": "taskCandidates",
   "instruction": "タスクにする: 自分がレビューする PR\nタスクにしない: タイトルに WIP や do not merge とある PR\nタイトル: 「レビュー: <リポジトリ名> #<番号> <タイトル>」\n期限: 付けない\n付け先: リポジトリ名と同じ名前の workspace があればそれ。それ以外は省く"}
 ]}
```

レビュー依頼は済むと取得から消えるので `currentSet`。消えた依頼の候補は、⌘⇧X の候補の一覧から下がる。draft の PR と bot が開いた PR は、判定に届く行からは見分けられないので、取得の条件で落とす。draft の PR は ready になると取得に現れ、そのとき判定に届く。

### 判定の指示文

```
タスクにする: 自分への依頼・質問・レビューや確認の頼み・判断を求められているもの
タスクにしない: お礼・挨拶・周知・bot の通知・自分で完結した報告
タイトル: 「<送り手>: <何をするか>」。何をするかは動詞で終える
期限: 文面にあればそれ
付け先: 請求の話なら billing-api。それ以外は省く
```

状態・担当・期間のように条件で落とせるものは取得の条件で落とし、判定には読まないと決まらないものだけを渡す。

## 型 2: MCP でしか読めない出どころを見張ってタスク候補にする

認証が MCP サーバーの中にしか無く、コマンドでは読めない出どころ（Slack の OAuth 接続など）。取得を軽い agent にし、読み取りのツールだけを指定する。回ごとに LLM が起動するので、そのことを人に伝える。

```json
{"name": "Slack: 自分へのメンションと DM",
 "nodes": [
  {"key": "slack", "name": "メンションと DM を取る", "trigger": {"kind": "interval", "minutes": 30},
   "model": "haiku", "tools": ["mcp__slack__slack_search_public_and_private"],
   "instruction": "自分へのメンションと DM を取る。id はチャンネル ID と ts の組、link は permalink、body は「#チャンネル / 送り手: 本文」、time は送信時刻。",
   "coverage": "newArrivals"},
  {"key": "judge", "name": "タスクにするか決める", "trigger": {"kind": "arrival"},
   "from": ["slack"], "model": "sonnet", "deliver": "taskCandidates",
   "instruction": "タスクにする: 自分への依頼・質問・判断を求められているもの\nタスクにしない: お礼・挨拶・周知・bot の通知\nタイトル: 「<送り手>: <何をするか>」\n期限: 文面にあればそれ\n対応済み: 自分が返信した・相手が取り下げた候補は対応済みにする"}
 ]}
```

新着だけが返る出どころなので `newArrivals`。取得の `instruction` には、取る範囲と、1 項目の作り方（`id`・`link`・`body`・`time` に何を入れるか）を書く。判定の指示文には対応済みにする条件を必ず書く。

## 型 3: 出どころごとの予定で集め、まとめて判定する

「GitHub と Slack を見て、平日の朝 9 時にまとめてタスクにして。GitHub は来たらすぐ要約も欲しい」。取得はそれぞれの予定で実行され、判定は平日の朝に 1 回、まだ受け取っていない行をまとめて読む。別の受け手（要約）は、同じ取得の行が届いたらすぐ読む。

```json
{"name": "朝の仕分け",
 "nodes": [
  {"key": "github", "name": "GitHub のレビュー依頼を取る", "trigger": {"kind": "interval", "minutes": 10},
   "command": "gh search prs --review-requested=@me --state open --json url,title,repository,updatedAt --jq '.[] | {id: .url, link: .url, body: (.repository.nameWithOwner + \" \" + .title), time: .updatedAt}'",
   "coverage": "currentSet"},
  {"key": "slack", "name": "Slack のメンションと DM を取る", "trigger": {"kind": "interval", "minutes": 10},
   "model": "haiku", "tools": ["mcp__slack__slack_search_public_and_private"],
   "instruction": "自分へのメンションと DM を取る。id はチャンネル ID と ts の組、link は permalink、body は「#チャンネル / 送り手: 本文」、time は送信時刻。",
   "coverage": "newArrivals"},
  {"key": "triage", "name": "朝にまとめて判定する", "trigger": {"kind": "cron", "expression": "0 9 * * 1-5"},
   "from": ["github", "slack"], "model": "sonnet", "deliver": "taskCandidates",
   "instruction": "タスクにする: 自分への依頼・質問・レビューの頼み\nタスクにしない: お礼・周知・bot の通知\nタイトル: 「<送り手>: <何をするか>」\n期限: 文面にあればそれ\n対応済み: 自分が返信した・PR が閉じた候補は対応済みにする"},
  {"key": "digest", "name": "GitHub を届いたら要約する", "trigger": {"kind": "arrival"},
   "from": ["github"], "model": "haiku", "deliver": "report",
   "instruction": "新しいレビュー依頼を、急ぐものから数行で要約する。1 行目は件数。"}
 ]}
```

1 つの判定に入力を集めるので、同じリンクの行が両方から届いても候補は 1 つ。

## 型 4: 定時にまとめて報告する

「平日 18 時に○○を要約して」。取得は自分の予定で今の集合を保ち、報告は cron で回るたびに、取得の今有効な行をすべて読む（`take` を `all`）。予定が取得と別なので、毎回全体をまとめられる。

```json
{"name": "GitHub: 開いている自分の PR の要約",
 "nodes": [
  {"key": "prs", "name": "自分の PR を取る", "trigger": {"kind": "interval", "minutes": 60},
   "command": "gh search prs --author @me --state open --json url,title,repository,updatedAt --jq '.[] | {id: .url, link: .url, body: (.repository.nameWithOwner + \" \" + .title), time: .updatedAt}'",
   "coverage": "currentSet"},
  {"key": "summary", "name": "夕方に要約する", "trigger": {"kind": "cron", "expression": "0 18 * * 1-5"},
   "from": [{"node": "prs", "take": "all"}], "model": "haiku", "deliver": "report",
   "instruction": "PR を 1 行ずつ、止まっているものを先にまとめる。1 行目は件数。"}
 ]}
```

## 型 5: 定時にツールで作業をさせる

「平日 9 時に○○を△△へ投稿して」。入力の無い、ツール付きの agent が cron で起動し、指定したツールで作業をして、したことを報告に残す。行は agent に渡らないので、対象は agent 自身にツールで調べさせる。

```json
{"name": "レビュー待ちの PR を Slack に投稿",
 "nodes": [
  {"key": "post", "name": "レビュー待ちを投稿する", "trigger": {"kind": "cron", "expression": "0 9 * * 1-5"},
   "model": "sonnet", "tools": ["Bash(gh search prs:*)", "mcp__slack__slack_send_message"],
   "deliver": "report",
   "instruction": "自分がレビュー待ちの open な PR を gh で調べ、1 行ずつまとめて Slack の #dev-me に投稿する。無ければ投稿しない。"}
 ]}
```

指定するツールは最小にする。書き込みのツールは、agent が読んだ文面に仕込まれた指示で使われうる。失敗した回は次の回でもう一度実行されるので、投稿が二重になりうることを人に伝える。

## 型 6: 定時にコマンドを実行する

「毎晩 23 時に○○.sh を実行して」。入力の無いコマンドが cron で実行される。

```json
{"name": "日報の下書き",
 "nodes": [
  {"key": "note", "name": "日報の下書きを作る", "trigger": {"kind": "cron", "expression": "0 23 * * *"},
   "command": "~/bin/daily-note.sh", "deliver": "none"}
 ]}
```

## 型 7: 届いたら外部操作をする

「担当の課題が増えたら○○に送って」。取得が新しい行を出したときだけ、コマンドが届いた行を標準入力で受けて実行される。

```json
{"name": "GitHub: 担当の課題をチャットに送る",
 "nodes": [
  {"key": "issues", "name": "担当の課題を取る", "trigger": {"kind": "interval", "minutes": 15},
   "command": "gh search issues --assignee @me --state open --json url,title,repository --jq '.[] | {id: .url, link: .url, body: (.repository.nameWithOwner + \" \" + .title)}'",
   "coverage": "currentSet"},
  {"key": "send", "name": "チャットに送る", "trigger": {"kind": "arrival"},
   "from": ["issues"], "command": "~/bin/send-issues.sh", "deliver": "none"}
 ]}
```

コマンドの中では、行の値をシェルとして評価せず、agent（claude -p など）にも渡さない。済んだ行は行の `id` で除外し、`ORBE_RUN_ID` を使うなら終わりに記録する（理由は `set_automation` の説明の REPORT, WORK, SIDE EFFECT）。

## 組み合わせ

型は組み合わせて使う。例は網羅ではない。

- 取得と判定の間にコマンドの処理を置き、安く絞ってから高い判定に回す（処理は行の `id` と `link` を保つ）。
- 同じ取得から、判定と報告の両方へ分ける（型 3）。
- 判定の代わりに報告を置けば「見張って知らせる」、外部操作を置けば「届いたら何かする」。

```json
{"name": "GitHub: 急ぎの課題",
 "nodes": [
  {"key": "issues", "name": "担当の課題を取る", "trigger": {"kind": "interval", "minutes": 15},
   "command": "gh search issues --assignee @me --state open --json url,title,repository,labels --jq '.[] | {id: .url, link: .url, body: (.repository.nameWithOwner + \" \" + .title), labels: [.labels[].name]}'",
   "coverage": "currentSet"},
  {"key": "urgent", "name": "急ぎだけに絞る", "trigger": {"kind": "arrival"},
   "from": [{"node": "issues", "take": "all"}], "command": "jq -c 'select(.labels | index(\"urgent\"))'",
   "coverage": "currentSet"},
  {"key": "judge", "name": "タスクにするか決める", "trigger": {"kind": "arrival"},
   "from": ["urgent"], "model": "sonnet", "deliver": "taskCandidates",
   "instruction": "タスクにする: 自分が手を動かす課題\nタスクにしない: タイトルが質問や議論の呼びかけで、手を動かすことが無い課題\nタイトル: 「<リポジトリ名>: <タイトル>」\n期限: 付けない"},
  {"key": "notice", "name": "急ぎを知らせる", "trigger": {"kind": "arrival"},
   "from": ["urgent"], "model": "haiku", "deliver": "report",
   "instruction": "新しい急ぎの課題を 1 行ずつ並べる。1 行目は件数。"}
 ]}
```

urgent のラベルは後から付くことがある。取得の項目は中身が変わっても同じ項目で、`take` が `new` の受け手には再び届かないので、ラベルで絞る処理は取得の今の項目を毎回すべて読み（`take` を `all`）、自分も `currentSet` にする。後からラベルが付いた課題は処理の新しい項目として下流に届き、ラベルが外れたり課題が閉じたりすると、その候補は下がる。
