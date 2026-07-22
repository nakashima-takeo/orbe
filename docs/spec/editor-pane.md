---
title: エディタペイン（現状）
description: Cmd+/ の Git ワークベンチペイン — cwd 追従・右 ToolRail（ツリー/git/ブラウザ）＋ヘッダー3種＋左本体（ファイル/diff/md/CommitDetail）＋CommitBar・ブラウザは dev サーバー実描画
updated: 2026-07-22
---

ターミナルの右隣に据わる Git ワークベンチペイン（chrome レベル・タブ/workspace を跨いで 1 枚）。フォーカス中ペインが git リポジトリ内なら右端の ToolRail が常駐し、本体パネルを閉じてもレールは残る。非 git（repo 未解決）では facade ごと隠れる。加えて facade 全体の表示は設定「開発中の機能を有効化」（`dev-features`・[settings-palette](settings-palette.md)）が gate し、オフのときは repo 内でもどの経路でも facade を出さない（可視は `WindowController` の投影集約点 1 箇所に一本化）。gate 値は**アクティブ workspace の実効 `dev-features`** で、他設定と同じく workspace 上書きでき、workspace 切替・設定適用ごとに再評価される（→ [workspace](workspace.md)）。

本体幅の既定は窓幅に応じた上限つきで、本体を開いているときのみ左端ドラッグで固定幅を選べる（以降その値・クランプあり）。`Cmd+/` はアクティブタブの本体パネルの開閉トグル（レールは隠さない・repo 未解決なら no-op）で、ペイン内にフォーカスがあっても効く（facade のキー当量がコミット入力の field editor より先に受ける）。閉じるとターミナルへフォーカスを返す。ペイン内の Esc も同様。

EditorPane の操作は index/ref のみを書き、worktree へは書かない。**例外**: 変更破棄（discard）は確認ダイアログ付きで worktree を書く唯一の確定操作（tracked は index の内容へ戻し、untracked は物理削除する）。

ペインは別ホストビューで、地は背景透過設定の実効 opacity で薄まり、透過時は端末面と同濃度でデスクトップまで透ける（[config](config.md)・[layout](layout.md)）。

## 紐づけ
フォーカス中ペインの cwd から `git rev-parse` でチェックアウト（linked worktree 含む）を解決して追従する。トリガはフォーカス移動・cd（OSC 7）・タブ/workspace 切替。非同期解決が交錯しても最後の retarget だけを勝たせる。UI 状態（本体パネルの開閉・ツール・git サブタブ・選択ファイル・ビューモード・フォルダ開閉・hunk 折りたたみ・コミット下書き・履歴選択）の単一真実は**タブが所有する**ので、同じ repo を別タブで開けばタブごとに別の画面状態になり、cwd 同一でもタブが変われば UI を張り替える。repo 由来のキャッシュ（GitRepo・watcher・snapshot・ツリー・履歴）だけを repo root キーで持ち、切替直後はキャッシュを即描画して裏で最新へ更新する。空状態は文言で表す（cwd 不明・git 外・読み込み中・状態取得失敗）。

## 状態機械
`Tool = tree|git|browser` ＋ `GitTab = changes|history` の2階層。ツールは右 ToolRail で切替、git サブタブは Segmented で切替。ツール/サブタブ切替でファイルが変わらない限り選択ファイルは維持され、ビューモードは切替先の既定へ戻る（履歴は選択維持）。

## 右 ToolRail（3ツール: ツリー/git/ブラウザ）
ペイン右端の縦レール（repo 解決時は常駐）。ボタンは本体パネルのトグル: 閉じているとき押すとそのツールで開き、開いていて同ツールを再度押すと閉じ、別ツールなら開いたまま切替える。`Cmd+Shift+↑/↓` は本体パネルを開いているとき隣ツールへ移動し、端でさらにその方向へ押すとラップせず本体を閉じる（Cmd+/ 閉と同一副作用: 幅投影＋保存＋ターミナルへフォーカス返し）。閉じているときは現ツールを無視し端から開く（↓=先頭 tree・↑=末尾 browser）。結果として `Cmd+Shift+↓` 連打＝閉→tree→git→browser→閉、`Cmd+Shift+↑` 連打＝その逆の一方向循環になる。EditorPane 表示中かつ非空状態のみ有効。本体パネルを開いているときのみ現ツールがアクティブ表示になり、閉じている間はどのボタンも反転しない。非アクティブ時のみ右上に状態ドット: git は未コミット変更ありで点灯（実データ連動）。ブラウザボタンには出さない。git ボタンは変更ゼロのとき、ブラウザボタンは dev サーバー未検出のときグレーアウトするが、いずれも押下は可能（git は history が見え changes が空表示、ブラウザは空状態で開くだけ）。レール最下部に `⌘/`（開閉ヒント）を1箇所だけ置く。

## ヘッダー（共通枠＋ツール別3種）
共通枠にツール別の中身を差す。

- **TreeHeader**: 検索ボックス。描画のみ・無配線。
- **GitHeader**: branchChip（実ブランチ名。`▾` は描画のみ・無配線）＋`↑N ↓M`（upstream 有時のみ・実 ahead/behind）＋`+A −D`（非0のときのみ）。
- **BrowserHeader**: `‹ › ⟳`（実配線・`canGoBack`/`canGoForward`・リロードは稼働時のみ活性）＋URLバー（緑ドットは dev サーバー稼働時のみ・現在 URL を表示のみ）。

## ツリーツール
git ツールと独立した閲覧専用ツール。`git ls-files -z --cached --others --exclude-standard` から構築したワークツリー全ファイル（フォルダ優先・辞書順）。フォルダ開閉は**既定で全フォルダ閉**（明示的に開いた状態はタブごとに保持）。ファイル種別アイコン・status バッジ。全ファイル選択可でビューアに内容表示。変更ゼロの repo でもツリーは開ける。

## git ツール
GitHeader 直下に Segmented「変更 N」/「履歴」（変更サブタブのみ右に「新しい順 ▾」＝描画のみ・無配線）。N は変更ファイル数。

- **変更サブタブ**: フォルダグルーピング＋3状態 StageBox（none / partial / staged）＋ファイル行（partial は hunk 進捗 `staged/total`・M/A/D/C バッジ）＋フォルダ集計。フォルダ行の StageBox は配下の全ファイルを一括 stage/unstage する（配下 conflict 除く全 staged→staged・一部→partial・皆無→none）。ファイル行・フォルダ行は右クリック→「変更を破棄」→確認ダイアログ（対象ファイル数を表示）で discard。conflict ファイルは C バッジで並ぶ。CommitBar はこのサブタブでのみ表示される。
- **履歴サブタブ**: 実コミット履歴を first-parent 基準の 2 レーングラフで描く（lane 0=HEAD の first-parent 連鎖・lane 1=それ以外。複雑トポロジはレーン退化）。各行にコミットドット（uncommitted/head/unpushed/merge/other で表現差）・HEAD/remote/tag の ref バッジ・相対日時・author・未push 表示。先頭に「未コミットの変更」擬似ノード。未push 判定は `rev-list @{upstream}..HEAD` の oid 照合。スクロール末尾で追加読み込み（ページング）。選択は CommitDetail に反映。

## FileViewer（ctx: tree|changes）
文脈は git ツールの変更サブタブなら `.changes`、それ以外は `.tree`。ヘッダ・表示セグメント・本文の出し分けを ctx が決める。

- **ヘッダ左側**: `.changes` は `‹ i/N ›`＋パス＋M バッジ＋`+A −D`。`.tree` はアイコン＋dir `›` name。
- **表示セグメント**: `.tree` は非md=**セグメント無し**（右肩に「変更は git ツール で」誘導文）・md=［ソース｜プレビュー］。`.changes` は md=［ソース｜プレビュー｜diff］・非md=［ファイル｜diff］。
- **md × changes × preview**: プレビュー本文の上に情報帯「プレビューに変更を重ねて表示 / 追加＝緑 / 削除＝打ち消し / stage は diff 表示で」。
- **ファイル表示**: 実ファイル内容＋行番号＋変更行ガターマーク（staged＋unstaged diff の新行番号から導出。hunk 内で removed と対になる added を mod・余りを add）。
- **diff 表示**: hunk 単位（ヘッダ＋折りたたみ＋`stage`/`解除` ボタン＋staged 状態の背景差）。staged hunk（HEAD↔index）と unstaged hunk（index↔worktree）を新行番号順に統合表示する（基準が異なるため順序は近似）。
- **md プレビュー**: read-only markdown レンダラ（swift-markdown で AST→SwiftUI）を EditorPane 用スタイルで使う。
- **CommitDetail（履歴サブタブ）**: hash・メッセージ・日時・author・files 集計・変更ファイルリスト・選択ファイルの diff プレビュー・`checkout`/`revert`（描画のみ・無配線）・hash のクリップボードコピー。「未コミットの変更」ノード選択時は現在の変更を同レイアウトで出す。
- **本文を出さない note**: conflict は「競合 — ターミナルで解決」・バイナリ・rename のみ・mode 変更のみ・空ファイルはそれぞれの note。

## ブラウザツール
フォーカス中プロジェクトの dev サーバーが稼働していれば、その実ページを WKWebView で描く埋め込みブラウザ。URL は cwd 追従（retarget 相乗り）で、稼働時のみ表示する。

- **dev サーバー検出**: `lsof` で LISTEN 中の socket を列挙し、各 pid の cwd が repo root 配下のものだけを採る。バインドアドレスが localhost のものに限る。候補ポート各々へ短 timeout で `GET` し、`Content-Type` が `text/html` のポートだけを残す——HTML を返さない MCP/API endpoint（`@react-grab/mcp` 等）を除外するため（timeout・接続不可・非 http も除外）。複数ポート時は慣習 dev ポート優先→無ければ最小ポートで1つ選ぶ。HTML を返せば非 dev の HTTP リスナ（`python -m http.server` の一覧等）も「稼働」と見なす。外部コマンド・HTTP プローブは背景キューで同期実行し短期 TTL キャッシュを持つ。起動時から数秒間隔でポーリング（root 解決時のみ実検出）＋retarget 時・browser ツール切替時に即再検出。
- **本体**: dev URL があれば WKWebView で実ページを描く。WKWebView はモデルが 1 つ保持して使い回す（再描画で作り直さない・URL 変化時のみ load）。retarget では新 root の dev URL へ load し直す（使い回しのため web の戻/進履歴は切替を跨いで残る＝プロジェクト横断で戻り得る）。dev URL が無ければ空状態「dev サーバー未起動」を出し、dead な localhost は出さない。
- **フッター**: 緑ドット（稼働時のみ）＋稼働状態テキスト／右端「外部ブラウザで開く ↗」（既定ブラウザに現 URL を開く・稼働時のみ活性）。chrome 色はテーマ追従。
- ブラウザ操作（戻る/進む/リロード/外部で開く）は EditorPaneController が唯一の入口。WKWebView の `canGoBack`/`canGoForward`/現在 URL は KVO で model へ写す。URL バーへの任意 URL 入力は持たない（dev サーバー専用・表示のみ）。

## ステージング・コミット
- **StageBox（ファイル）**: none→stage（未追跡は intent-to-add 経路）、staged→unstage、partial→残り全 stage。3 状態は status＋staged/unstaged diff の有無から判定。
- **StageBox（フォルダ）**: 全 staged→配下一括 unstage、それ以外→配下一括 stage（`git add`／`git reset` に複数パスを渡す・rename は oldPath も対象）。
- **hunk stage/解除**: 対象 hunk の全変更行を選択した再構成パッチを `git apply --cached`（解除は `--reverse`）で index のみへ適用。未追跡の hunk stage は `add --intent-to-add` を前置。
- **変更破棄（discard）**: 右クリック→確認ダイアログ→破棄で worktree を確定変更する。tracked は `git checkout -q -- <paths>`（index の内容へ戻す）、untracked は物理削除。ファイル単位・フォルダ単位とも同経路。
- **コミット**: `git commit -F -`。hooks・署名は通常の git commit と同様に効く（ログインシェルの PATH を一度解決して全 git 呼び出しへ引き継ぐ）。成功で下書きクリア、失敗/成功とも CommitBar 近傍の最小バナーに出力を出す。
- conflict ファイルは stage・discard の対象外（C バッジで見えるが解決 UI は持たない）。

## 更新
FSEvents（worktree root＋gitDir＋commonDir 監視）で外部変更が手動操作なしに反映され、表示中の repo のみ描画し直す。操作直後も即リフレッシュする。

## git 実行の契約
`/usr/bin/git` を背景キューで起動し completion をメインへ返す。`GIT_TERMINAL_PROMPT=0`（対話でハングさせない）。status は `--no-optional-locks`。diff/diff-tree は `--no-color --no-ext-diff --no-textconv --find-renames -U3`＋`core.quotepath=false`（信頼できないリポジトリの外部 diff driver / textconv を実行しない）。write 系（index/ref を変更する操作）は barrier で排他直列化し、read 系は並行で走らせる（index.lock 衝突の回避）。未追跡ファイルの diff は index に触れず合成する（先頭バイトに NUL・過大サイズ・非 UTF-8 はバイナリ扱いで全行展開を避ける）。

## 実装の境界
git のロジック・実行層（`Sources/Orbe/Git/`）は AppKit 非依存で、UI（`Sources/Orbe/EditorPane/`）から分離する。本体の開閉とツールは `workspaces.json` に永続化する（[persistence](persistence.md)）。localhost(http) 読み込みは `Info.plist` の `NSAllowsLocalNetworking`。ファイル種別アイコンは Catppuccin/vscode-icons（MIT・NOTICE 帰属）。
