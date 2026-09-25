---
title: テスト実装ロードマップ
description: テストアーキテクチャへ到達するためのスライスと進捗
updated: 2026-09-26
---

# テスト実装ロードマップ

生きた進捗文書。あるべき姿は [test-architecture.md](test-architecture.md) が持つ。

## 現状と到達点

出発点（2026-08-03 時点）。進捗では更新しない（事実誤りの訂正だけは入れる）。

| 層 | 現状 | 到達点 |
|---|---|---|
| L0 静的 | SwiftLint / swift format を CI と pre-commit で強制 | 変更なし |
| L1 ユニット | 主戦場。Git パーサ群・`SessionStore`・`SettingsLayer`・`AttentionSnapshot`・`MenuBarArrivalDriver` などが厚い | 穴を埋める。とくに `GitRepo+WorktreeClean` の取り込み判定 |
| L2 結合 | 観測面が `window.title` 止まり。永続は保存側が厚く**復元側がゼロ**。IME / スクロール / キー翻訳は**テスト 0** | 復元ラウンドトリップ・設定適用の配線・keep-alive・ターミナル入力表面 |
| L3 wire 契約 | **0**。既存の control テストは `WindowController` を直接叩き、検証層を迂回している | socketpair 上の実 `Connection` でプロトコルの語を固める |
| L4 プロセス境界 | **0**。`orbe-cli` は 16 サブコマンド中 0、`orbe-mcp` はテストターゲット自体が無い。唯一の導通確認は CI 外の手動確認だけ | 実バイナリ × in-process `ControlServer` |
| L5 コンポーネント | `MenuBarStatusViewTests` と `ChromeStatusRowTests` のみ | 状態 → 表示とレイアウト数値 |
| L6 見た目 | **0**。`Design*SnapshotTests` は `XCTAssert` 0 件・ゴールデン 0 枚・CI ではスキップされる PNG 生成器 | 1x 固定のゴールデン比較 |
| L7 生成物 | `L10nCompletenessTests` と `OrbePalette` の drift ゲートのみ | `.app` 静的検査・agent-plugin 構成・tokens drift |

**規模**: Sources 28.7k 行に対しテスト 18.5k 行 / 119 ファイル / 1105 関数、CI で 59 秒（うち 15 スキップ）。

**既知 Issue との対応**: 未修正バグはテストが無い層に集中している。#50 #62 #63 #64 #74 は L3/L4、#56 #68 #54 は L2 の復元、#72 #77 は L7。穴を埋める作業がそのまま再発防止網になる。

## スライス

状態: 未着手 / 仕様確定済 / 実装中 / 完了

| # | スライス | 内容 | 依存 | 状態 |
|---|---|---|---|---|
| 0 | 基盤足場 | 単一ハーネス（`OrbeTestCase` が点火し `XCTestObservation` が毎テスト隔離。state dir は `ORBE_STATE_DIR` を 90 バイト以下の temp へ向けて隔離し、`control.sock` も自動で追従。永続・同梱リソース根・プラグイン実体化先・ghostty 設定探索先の override を毎テスト張り直す。補完の学習ストアだけはプロセス級固定で、学習状態はテスト間で持ち越される）。`Bundle.main` 直参照 8 箇所（7 ファイル）を `BundledResources` へ集約。`.swiftlint.yml` の custom rule 3 本で、同梱リソースの直参照・`Tests/OrbeTests` で `OrbeTestCase` を継承しないテストクラス・swift-testing の import を error に落とす。ビルド済み CLI 実行体がテストバンドルの隣にある前提と、その解決規則の固定 | — | 完了 |
| 1 | wire 契約 | 制御プロトコルの語を socketpair 上の実 `Connection` で固める（`ControlWireTests` 群）。method 名・params キー・エラーコード・成功時の応答キーと宛先への配線・`wait_for_event`・framing・不正入力。前提として `ControlServer` に `adopt(fd:)` を切り出し、不正入力へ `-32700` / `-32600` を返すよう直した。エラーコードの語彙は `docs/spec/control/api.md` の「エラー」節と 1 対 1。#50 #62 | 0 | 完了 |
| 2 | プロセス境界 | 実 `orbe-cli` / `orbe-mcp` / `orbe-report` を subprocess で駆動し、テストプロセス内の実 `WindowController` ＋ `ControlServer` へ繋ぐ（`ControlProcess`。子の待機は runloop を回して行い、env は明示辞書のみで親から継承しない）。全 22 サブコマンドのライフサイクル・終了コード（`orb wait` の時間切れ 124 を含む）・`--json` の出力先・`ORBE_TAB` / `current` の文脈解決・`--workspace` の意味論・hook 実経路・bare `orb` の PATH 解決・`orbe-report` が書く生 1 行の語。**スライス 1 からの持ち越し**だった `get_tab_text` の `scrollback` も実 surface で固定した。エージェント起動（`orb agent spawn` / `resume`）は偽実行体と `ShellPATH` 差し替えで検出を固定し、**背景 workspace への spawn が手元の画面を奪わないまま読み書きできる**ことまで実タブで見る。`.app` 起動経路と `AppDelegate` 配線は範囲外で、その煙探知は `sandbox-run` が持つ。#63 #64 #74 | 0, 1 | 完了 |
| 3 | 復元と移行 | 保存 → 復元 → 再保存のラウンドトリップ。`TabState`（タブの面の配置 `faces` を含む）・設定層の寛容 decode の境界・範囲外クランプ・デバウンス・旧バージョンファイルからの起動移行。#56 #68 #54 | 0 | 完了 |
| 4 | 既存テストの整理 | assert 0 件の PNG 生成器を「テスト」から出す。自分のクロージャを自分で呼ぶ配線テスト・production を再実装したテスト・13 ファイルに浸透した行 index ハードコード・ヘッドレスで fail する 4 本・条件付きアサートを直す | — | 未着手 |
| 5 | ターミナル入力表面 | IME の preedit 同期と Backspace 貫通防止・キー翻訳・スクロールの蓄積と合体 flush。実 `SurfaceView` を直接駆動する。キー翻訳は着手済——`TtyDumpTab`（実タブで raw tty の dump を走らせ PTY に届いたバイトを読む駆動台）の上で、`send_key` と物理キー（合成 NSEvent を `keyDown` へ）が端末モードごとに届けるバイトを `SurfaceKeyInputTests` が固定している。クリップボードも同じ駆動台の上で `SurfaceClipboardTests` が固定している——⌘V / ⌘⇧V のペースト（bracketed paste の有無）・⌘C のコピー・選択だけでのコピー・中クリックのペースト・端末アプリ発の読み取り（OSC 52 / Kitty clipboard）がクリップボードの中身に関わらず拒否されること（読み取りを許しても PRIMARY は非対応）・Kitty clipboard の書き込みはテキストと解される MIME だけが入ること。**スライス 1 からの持ち越し**——`completion_accept` の `advance` と `completion_update` の `buffer`/`cursor`。前者は popup（`CompletionController`）が生まれないと `completionAccept` が結果を返さず、後者は無応答契約で観測面がゼロ（値の到達は `CompletionController` の内部状態にしか現れない）。補完経路を実際に駆動するときに `CompletionLearning.shared` のリセット可能化も同じ地点で要る | 0 | 実装中 |
| 6 | アプリ結合 | 設定適用の配線（scope 別の保存先・ライブ反映）・workspace の keep-alive と全タブ mount。`WindowController.init` の分解が前提。#75 #61 | 0, 3 | 未着手 |
| 7 | コンポーネント | 状態 → 表示の対応とレイアウト数値。`MenuBarDropdown`・`StatusRowView` の並び替え計算・`CompletionList` の可視範囲 | 0 | 未着手 |
| 8 | 見た目の足場 | 描画完了の確定的待機・1x 固定・1 枚 1 テストへの分解・ゴールデン比較の導入。まず 1 画面で成立を確認してから広げる | 0, 4 | 未着手 |
| 9 | 生成物 | `.app` の静的検査（署名・同梱物・`Info.plist`）・agent-plugin パッケージ構成・tokens の全単射 drift ゲート。Swift 側が期待する同梱物の相対パス（`bin/orbe-report`・`agent-plugin/install.sh`・`completion-engine.js`・`zsh/.zshenv`・`zsh/orbe-completion.zsh`・`orbe-defaults.conf`）と `scripts/build-app.sh` の配置の照合——ずれると全機能が無警告で no-op に倒れる。フォントに対しては `TerminalFontDelegationTests` が同じ論法で番人になっている。#72 #77 | — | 未着手 |
| 10 | 外部プロセス異常系 | `gh` の 3 分岐フォールバック・`GitHubCLI` の打ち切り後の待ち・`AgentCatalog` の 10 秒タイムアウト。#13 #95 | — | 未着手 |
| 11 | カバレッジ可視化 | `swift test --enable-code-coverage` → lcov → PR コメント。閾値ゲートにはしない | — | 未着手 |
| 12 | エディター | エディター面の中身。純ロジックは専用 target `OrbeEditorCoreTests`（行索引・capture 名の正規化・16 文法の queries 解決・15 言語と injections の色付け・保存の往復を、fake のテキスト面と見本ファイルで回す。queries の根は `.build/<config>` を明示注入する——テスト実行体が同梱物を持たないため）。`Tests/OrbeTests` 側は本物のテキストエンジンで打鍵・undo・未保存の意味（queries はここも明示注入する——ハーネスが `BundledResources.root` を空 dir へ張り替えるため）、面の中身の入れ替えと焦点の行き先、chrome キーの所有面（⌘S の保存と端末への素通し）、`open_file`、`EditorStyle`（見本の寸法と役割色の外観追従）。git と FS の土台（u3）は `OrbeEditorCoreTests` が行差分（ハンク）と文書のディスクの姿（外部変更の差し替えと印・force 保存）を fake の面で、`Tests/OrbeTests` が実 git リポジトリ（`TempGitRepo`）と実 FSEvents で根の判定・監視の 3 本の通知・status とバッジ・index 版の baseline・観測者の関心・一覧と新規作成・寿命・文書の結線（外で書き換えたファイルの反映と ⌘S の失敗）を固める。観測が `.exclusive` のハングに巻き込まれないことは `GitHangFixture` で測る。待ちは `pumpMain` で通知を待ち、時間で眠らない。監視のテストは fixture が直前に起こした変化が最初の配達に混ざるので、目印を 1 つ書いてその配達を待ってから測る。u4（面の骨）は、pane の矩形と SwiftUI の中身の両方を見る——サイドバーの切り詰め・表示幅 0・レールの開閉・共有状態の追随は画素プローブで、列の頭は `NSHostingView` の `fittingSize` で、溢れと可視位置への送りは SwiftUI が生む `NSScrollView` の可視矩形で固める。行内の新規作成は本物の入力欄（field editor）を焦点に取らせ、打鍵・Return・Esc（`window.sendEvent`）・blur で駆動し、焦点の行き先を `window.firstResponder` で見る。sheet の再入（応答までに文書・タブ・workspace が動く）は `endSheet(_:returnCode:)` で応答を注入して測り、窓側の結線（app-state のサイドバー記憶・mount の順序・復元の往復・デバウンス保存・materialize 前の `open_file`）は実 `WindowController` で固める。u5（行の装備）は、規則（ハンク → 印・インデント単位・段・boundary の空白・URL の刈り込み・行の同一性はバイト列）を `OrbeEditorCoreTests` の純関数で、文書が印を面へ押して打鍵に付いてくることを fake の面で固める。`Tests/OrbeTests` は本物のテキストエンジンを黒地の窓に載せ、印（3 色・三角・先頭行の上・スクロール追従）・行番号の右寄せと印の列・インデント線とタブ幅（丸ごと置き換えでの再検出を含む）・丸点・下線の位置と色を画素で、⌘クリックが開く／開かないを合成マウスイベントで見る。地が 1 層で行番号の列も本体と同じ濃度になること・横スクロールで本文が行番号の列の下をくぐらないことは `EditorPaneView` を layer に描いて画素で見る。baseline が checkout 後の姿（`cat-file --filters`）になること・blob の一時失敗の取り直しと 3 回で諦めること・status の通知が blob より先に出ることは実 git で固める。u6（俯瞰とファイル内検索）は、規則（ミニマップの字の列と配置・スクロールバーのつまみ・印の写像と近似・一致の列と次／前と上限・出現の規則と語を探す窓・編集に合わせた区間のずらし）を `OrbeEditorCoreTests` の純関数で固める——配置・つまみ・印の正解は VS Code（f83f3fba）の該当コードを行高 18 で実行した値。文書が答える構文の事実（役割の区間）・インデント単位の所有・「変わった」の通知の時機は fake の面で固める。`Tests/OrbeTests` は本物のテキストエンジンで面の契約（viewport とその逆の「この行を先頭に」・遠くへ飛んでも落ち着く着地・最終行を最上段まで送れる範囲とその下の押下・本文が右に続くか・横スクローラーの様式の固定・強調の地が選択の上に出る層の並び）を、実 pane で俯瞰・検索・出現の強調を見る——ミニマップとスクロールバーは view 1 枚を透明な地に描いて alpha と色で（字の桁と形・役割の色・滑っている間の字と地の段・字の画像の捨て方〔打鍵・役割の変化・外観・文書の切替・上限〕・帯のホバーとドラッグ・帯の外の押下・一致と語の出現と git の印・つまみのドラッグとトラックの押下からのドラッグ・印のレーン）、見え隠れと出現の強調と検索の取り直しの時間の規則（50ms・100ms・500ms）は差し替えた時計で、クリックとドラッグは合成マウスイベントで、検索は選択・件数・上限・焦点を、一致の地・現在の一致の地とその行の地・編集の間も字に付く地と、出現の強調の地を pane の画素で見る。画素で読むテストが守る約束がある: 字の有無は字のあるセルの縁で読まない（1x と 2x で結果が同じ位置だけ）／一致の地は検索バーの下に入らない行の、字の無いセルの中心か行の上端寄りで、選択の地に覆われない（現在でない）一致を読む／つまみは印の上に重なるので、印を読むときはつまみとキャレットの印を離す。バーに件数が届くことは、一致なしの danger（赤）がバーの矩形に現れて消えることで見る（`SearchBar` の model は閉じている）。u6p（スクロール性能）は、色の窓（窓の外に色が無い・見えている字の色が今の役割・帯は見えるまで塗らずスクロールで見えたら塗る・描く前の layout で見えている行だけ塗り直す・遠くへ飛んだ先や帯から見えてきた行が描き直しを待たずに色付き）と行番号の列（行索引の番号・縦スクロールで見えている行の番号に替わる・桁で広がる・行の選択と ⇧の起点は動かない側の端・pane の中で押下とホイールを列が受ける）を本物のテキストエンジンで、文書の役割の答えが区間の切り方に依らないことを fake の面で、ミニマップの素の色の先描きと猶予の後の色付け（動き続ける間は猶予を置き直す）・行の選択の本文の外での自動スクロールを差し替えた時計で固める。自動スクロールを display link が実際に回すことは担保しない（テストの窓は画面に出ず display link が回らないので、コマの処理を直に呼ぶ）。時間そのものは `scripts/perf-editor.sh`（手元の release）が測り、CI では回さない。**u6p まで完了。**担保しないもの: Edit メニュー経由のキー（⌘Z / ⌘⇧Z / ⌘X / ⌘C / ⌘V / ⌘A）と IME——`MainMenu` が responder chain に載る `.app` 起動経路が層の外——と、キャレット・選択の地の描画。どちらも人が実機と gallery で見る。⌘押下中の指カーソル（`NSEvent.modifierFlags` と cursor rect に観察面が無い）・URL が既定ブラウザで開くこと（`NSWorkspace` は管理外）・続く行のバーが 1 本に繋がる見え方・gallery / flow と見本の一致（env ゲート）も人が見る。検索バーの件数の文字列・Enter / ⇧Enter / Esc の打鍵から closure まで（`SearchBar` の中身。端末と共有の既存部品）と、ヘルプの ⌘F の文言は固めない。FSEvents の取りこぼし（「全部見直せ」）は起こせないので担保しない。取り直しジョブの直列化は観察面を持たず、最終状態が最新の index と一致することだけを見る | 0 | 実装中 |

## 前倒しリファクタ

テストで固める前に直す本番コード変更。上位の網を張ってから、1 件ずつ提案して決める。

| 対象 | 理由 | 必要なスライス |
|---|---|---|
| `WindowController.init` の分解（#75） | 結合層の観測面が `window.title` 止まりの根本原因。70 行で永続 3 種ロード・libghostty 起動・login shell subprocess 起動・プラグイン実体化を全部やる | 6 |
| `MenuBarController` の判断部切り出し（#78） | 319 行の時間ロジックが未検証。`MenuBarArrivalDriver` と同じ時刻注入の形へ | 7 |
| `UpdaterService` への `UserDefaults` 注入点 | standard domain は cfprefsd がユーザーレコードで解決するため HOME 差し替えでは曲がらず、ハーネスの隔離が届かない。`swift test` が実ホームの `com.apple.dt.xctest.tool.plist` を書き、逆に開発者マシンのシステム設定（`AppleInterfaceStyle`・`AppleActionOnDoubleClick`）がテストへ入り込む | 6 |
| `CompletionLearning.shared` のリセット可能化 | `private init` が初回タッチで in-memory ストアを焼くためテスト間でリセットできない。ハーネスはプロセス級固定で回避しており、per-test の学習状態が要るスライスで必要になる | 5 |
| `CompletionList` / `StatusRowView+Reorder` の純ロジック切り出し | 数値契約が `private` や `body` 内ローカルに埋まり、PNG を見る以外に検証手段が無い | 7 |
