---
title: テストアーキテクチャ
description: Orbe のテストが従う層構成・横断方針・各層の責務
updated: 2026-10-02
---

# テストアーキテクチャ

あるべき姿の文書。実装の計画と進捗は [roadmap.md](roadmap.md) が持つ。

## 1. 対象

**形**: macOS ネイティブのターミナルマルチプレクサ（GUI 本体）＋ 3 つの CLI 実行体（ほかに配布しない dev CLI が 1 つ）。表面は 7 つ。

| 表面 | 実体 |
|---|---|
| GUI chrome | SwiftUI のパレット・オーバーレイ・MenuBar・Settings |
| ターミナル表面 | libghostty（キー翻訳・IME・スクロール・マウス） |
| 制御 API | `control.sock` 上の JSON-RPC（外部契約） |
| CLI | `orbe-cli` / `orbe-report` |
| MCP | `orbe-mcp` |
| 永続化 | state dir の JSON（workspaces / settings / app-state / gui.conf） |
| 生成物 | `.app` バンドル・agent-plugin パッケージ・L10n カタログ・`docs/design/tokens.json` |

**スタック**: Swift 6.0（tools-version、言語モード v5）/ macOS 14+ / SwiftPM のみ（Xcode プロジェクトなし）/ AppKit + SwiftUI 混在 / libghostty を `binaryTarget` の xcframework で取り込み / 外部依存は swift-markdown・Sparkle・tree-sitter（C API を直接呼ぶ）と tree-sitter 文法 14 パッケージ / CI は GitHub Actions macos-26 で `swift build --build-tests` + `swift test --skip-build`。

## 2. テスト戦略

層をまたいで全テストが従う決定。

**ランナーは XCTest 一本。** Swift 6.3 では swift-testing との相互運用が `none` で、両者でアサーションヘルパを共有すると失敗が黙殺される。Swift 6.4 で相互運用が既定 `limited` になった時点で再検討する。

**隔離は単一ハーネスが立てる。** state dir・全 override・ghostty の設定探索先を 1 箇所で立て、テストごとの申告制にしない（対象は `Tests/OrbeTests`。他 7 ターゲットは `Orbe` 以外のモジュール内部を測るだけで、隔離の要る対象を持たない）。申告制は張り忘れが 1 本でも残れば破れる（`GuiConfig` の override を張らないテストが 1 本あれば、`Config.load()` が前回実行の設定を読み戻す）。書き込まれうる先は全て per-test ディレクトリの下に置き、配り直しの削除に乗せる（向き先だけ張り直しても中身は消えない）。唯一 `CompletionLearning` だけは `shared` が初回タッチで in-memory へ焼くため per-test にできず、プロセス級固定＝学習状態がテスト間で持ち越されるので、書いたテストが自分で消す。実環境を汚さないことは `scripts/verify-test-isolation.sh`（手動・CI 非搭載）で実証する。

**テストクラスの doc は「壊れると何が起きるか」を書く。** 何を測るかはテスト名が言う。doc が言うのは、その assert が落ちたとき利用者に何が起きるか——それが無いと、後から読む人はテストを弱めてよいか判断できず、直すより消す方へ倒れる。

**state dir は 90 バイト以下。** AF_UNIX の `sun_path` は 104 バイト上限で、超えると `ControlServer` が制御 API を無言で無効化する。`$TMPDIR` + UUID は 108 バイトに達するため使わない。

**管理下は実物、管理外のみ差し替える。** 実物で回す: ファイルシステム・git・libghostty・Unix domain socket・自前 CLI バイナリ。差し替える: GitHub API（`gh`）・Sparkle の appcast。

**時間依存は時刻注入の状態機械へ寄せる。** タイマーを内蔵せず、時刻を引数で受けて実時間ゼロで境界を測る（`MenuBarArrivalDriver` が範）。

**`swift test --parallel` を使わない。** クラスごとに別プロセスになり、`ControlServer` の socket を奪い合う。

**プロセス全域のシングルトンに触る層は start/stop を対にする。** `ControlServer.shared` の `target` は weak で、前のテストの `WindowController` が解放済みだと "no window" になる。

**ゴールデン画像は 1x で固定する。** 手元は 2x・GitHub runner は 1x なので、固定しなければ両者で必ず不一致になる。フォントと GPU の微小差は `perceptualPrecision` が引き受ける。

## 3. 層構成

### L0 静的健全性

- **担保する**: 型・lint・format
- **担保しない**: 振る舞い
- **ツール**: SwiftLint `--strict` / `swift format lint --strict`
- **実行**: pre-commit（lefthook）＋ CI

### L1 ユニット（純ロジック）

- **担保する**: 入出力の規則。パーサ・状態機械・解決規則・境界値。コードに書かれた制約（設定の解決チェーン、`status --porcelain` の計数規則など）もここで固める
- **担保しない**: 配線・組み立て
- **起動と差し替え**: Foundation のみ。依存は引数で受ける
- **データ**: 不要（値を直接組む）
- **実行**: CI 全量
- **配置**: `Tests/OrbeTests/<型名>Tests.swift`。大きい対象は `<型名>Tests+<話題>.swift` に分割。`Orbe` 以外のターゲットのモジュール内部シンボルを測るものだけは当該ターゲット（`OrbePathsTests` / `OrbeReportTests` / `OrbeSessionLogTests` / `OrbeSoundTests` / `OrbeSoundCliTests` / `OrbeEditorCoreTests` / `OrbeEditorEngineTests`）に置く——`OrbeTestCase` は `OrbeTests` の中にあり他ターゲットからは継承できないので、隔離が要る対象をそちらへ置かない
- **正解の作り方**: テキスト面の編集の規則（純関数）は、VS Code を動かした正解と突き合わせる——`scripts/gen-vscode-edit-cases.sh` が monaco-editor（VS Code のエディターの核）を deno で動かし、語の移動・語の削除・ダブルクリックの語・⌘← の正解の表（`VSCodeEditCases`）を書き直す。⌫ の単位は窓を出さない NSTextView の ⌫ と、行の中の位置と x の対応は Core Text の双方向の API と突き合わせる。乱択の操作列（打鍵・削除・移動・字下げ・マウス・undo / redo を数千手）で、写し・選択・undo が決してずれないこと、配り先が編集の列を順に畳んだ本文と行の増減が文書と一致し続けることを見る。面の IME は、IME の呼び出しの列（ライブ変換・確定と次の未確定・取り消し・再変換・範囲を指した確定）を再生する道具で、呼ぶたびに IME から見える状態（未確定の範囲・その中の選択・範囲の文字列）が本文と一致し、契約の選択へ漏れないこと、undo と redo を尽くすと元と最後の本文に戻ることを見る。IME の呼び出しは乱択の操作列にも混ぜ、変換を終わらせる他の入口（クリック・コマンド・カット・ペースト・焦点の喪失・丸ごと置き換え・変換中の ⌘Z）と交ぜても同じことが成り立つのを見る。IME の側は入力の仕組み（`NSTextInputContext`）を偽物に差し替えて決める——窓の根で ⌘ キーを先に IME へ渡す順（IME が使った・使わなかった・先に確定してからコマンドを返した）も、この偽物で端末とエディターの受け手ごとに固定する。端末で keyDown の外の確定（先に確定してからコマンドを返した IME・音声入力）が打った文字として PTY へ届き、bracketed paste に包まれないことは、実 libghostty の駆動台（PTY へ届いたバイト）で見る。コピー・ペーストの確かめは名前つきの専用のペーストボードを使い、一般のペーストボードに触れない。本文へ落とす受け口は、落とす位置・板・送り手・送り手が許す操作を決めたドラッグの偽物（`NSDraggingInfo`）で呼ぶ（⇧ の修飾は差し替えられないので、落とすときの判断の純関数で見る）

### L2 プロセス内結合

- **担保する**: アプリの組み立て。永続の復元（保存→復元→再保存のラウンドトリップ）・設定適用の配線・workspace の keep-alive・`SessionStore` と `WindowController` の結合・**ターミナル入力表面**（IME の preedit 同期・キー翻訳・スクロールの蓄積と合体 flush）
- **担保しない**: プロセス境界を越える契約（L3/L4）・見た目（L6）
- **起動と差し替え**: 実 `WindowController`（実 NSWindow ＋ 実 libghostty ＋ 実シェル spawn）。`NSApp.activationPolicy()` は `.prohibited` で画面には出ず、フォーカスも奪わない。IME・キー・スクロールは実 `SurfaceView` を直接駆動する
- **データ**: 単一ハーネスが temp の state dir を立て、全 override と ghostty 設定探索先を隔離する。各テストは自分の `WindowController` を作る。**永続の後始末**はハーネスの per-test ディレクトリ配り直しと ARC が担い、テスト側は書かない。**ハーネスが触れないプロセスグローバル**（`NSApp.appearance`・key window・ordered-in の窓）だけはテスト側の `tearDown` が戻す
- **実行**: CI 全量
- **ツール**: XCTest

### L3 wire 契約

- **担保する**: 制御プロトコルの語。method 名・params キー・エラーコード（`-32700` / `-32600` / `-32601` / `-32602` / `-32004` / `-32006` / `-32000`）・`wait_for_event` のフィルタ・履歴カーソル（`after` / `value` / 応答の `seq`）とタイムアウト・`prompt_agent` と spawn / resume の ready 待ちの経路・行 framing・不正入力の扱い
- **担保しない**: ドメインの振る舞い（L2）・実バイナリの引数解釈（L4）。観測面を持たない params も L3 の外で、受け皿は [roadmap.md](roadmap.md) が持つ——`get_tab_text` の `scrollback`（値が libghostty surface へ吸い込まれる）と、`completion_accept` の `advance` / `completion_update` の `buffer`・`cursor`（popup が生まれないと適用結果が出ず、無応答契約で wire 側に観測点が無い）
- **起動と差し替え**: **socketpair 上の実 `Connection`**。テストが socketpair の片端を `ControlServer.shared.adopt(fd:)` へ載せ、もう片端から行を書いて応答を読む。`ControlTarget` は Fake。listener は張らない（`start()` を呼ばない）ので、実 socket に bind する L4 と待ち受けを奪い合わず、path も持たないため `sun_path` 制約を受けない。`ControlServer.init()` は private なのでインスタンスは `.shared` を使う
- **データ**: Fake target が返す値をテストが決める。宛先解決に使う `TerminalTab` は window に載せないタブで、libghostty surface は生まれない
- **実行**: CI 全量
- **ツール**: XCTest

### L4 プロセス境界・制御チャネル導通

- **担保する**: 実行体をまたいだ導通。実 `orbe-cli` / `orbe-mcp` / `orbe-report` の引数解釈・終了コード・stdout・組み立てる JSON-RPC。タブへの env 注入から `orbe-report` が `report_agent` を届けるまでの hook 実経路。bare `orb` の PATH 解決
- **担保しない**: `.app` の起動経路と `AppDelegate` の配線
- **起動と差し替え**: テストプロセス内で `ControlServer.shared.start(target:)` に実 `WindowController` を与え、外部プロセスとして `.build/.../debug/` のビルド済みバイナリを起動する。バイナリ位置は `Bundle(for:).bundleURL` の親から解決する。同梱物はハーネスが配る `BundledResources.root`（caseDir 配下）の下へ `.app` と同じレイアウトで置く（`bin/orb`・`bin/orbe-report`）
- **データ**: 単一ハーネス（L2 と同じ）。サーバの `socketPath` と子プロセスの `ORBE_STATE_DIR` は同じ値を指す。テスト冒頭で `socketPath` の実値を assert する（空や別値だと `start` が no-op になり、クライアント側は "Orbe not running" と区別できず緑に化ける）
- **実行**: CI 全量
- **ツール**: XCTest ＋ `Process`。子プロセスの env は明示辞書のみで親から継承しない

### L5 コンポーネント

- **担保する**: 状態 → 表示の対応とレイアウトの数値契約。ビューがモデルをどう読むか、幅の配分・折り返し・可視範囲の計算
- **担保しない**: 色・余白・字種（L6）
- **起動と差し替え**: `NSHostingView` を実 `NSWindow` に載せて `fittingSize` / `sizeThatFits` を測るか、切り出した純関数を直接呼ぶ
- **データ**: fixture を引数で与える
- **実行**: CI 全量

### L6 見た目

- **担保する**: 色・余白・字種・状態の視覚的符号化の退行
- **担保しない**: 振る舞い
- **起動と差し替え**: 既存の描画経路（`NSHostingView` を borderless `NSWindow` に載せ、`NSAppearance` を明示して `cacheDisplay`）をそのまま使う。ライブラリはこの部分の面倒を見ないので自前のままにする。**スケールは 1x に固定**する
- **前提条件**: ①描画完了を確定的に待つ（固定 sleep では CI 負荷下で白紙がそのままゴールデンになる）②1 枚 1 テストに分解する（1 メソッド 30 枚超のままだと最初の 1 枚で落ちて残りが見えない）
- **データ**: `DesignSceneFixtures` と Sources 側の `*Fixtures.swift`。stub で外枠だけ描かず、本物のデータを本物のビューに流す
- **実行**: CI 全量
- **ツール**: 比較・許容差・記録モード・差分出力は swift-snapshot-testing（`precision` ＋ `perceptualPrecision`）
- **例外**: テキスト面（Metal）の字と git の印は、ゴールデン画像でなく別の方式で見る——`GlyphPixelTests` が、同じ行を Core Text で不透明な地に（font smoothing つきで）描いた基準と字のある画素で 1 段以内か（1x・2x）を、`MetalLineMarksTests` が撮影した画素で印の色と位置を確かめ、`ScrolledFrameTests` がスクロールの前後の絵を画素で突き合わせて本文・行番号・印がそろって動くことを確かめる（通常の `swift test`。Metal の装置が無ければ skip）。装備・強調の地・ミニマップ・スクロールバーは、規則の要所を撮影した画素で（`SurfaceDecorTests`・`SurfaceHighlightTests`・`SurfaceMinimapTests`・`SurfaceOverviewTests`）見る（端を越えて引っ張っている間の俯瞰が端の位置を表すことは、同じ材料から端の内外の位置で組んだコマの俯瞰の図形を比べ、引っ張った途中のコマを撮って確かめる）。役割だけが変わった行の描き直しは、同じ本文を開き直した絵と画素で一致するかで見る。見た目の全体は gallery の `editor_code` と flow の `editor_decor`・`editor_line_select`・`editor_overview`・`editor_find`・`editor_occurrences` を撮って人が見る（flow は面を 1 つの窓に載せたまま撮る）。手元で回し、CI では回さない

### L7 生成物

- **担保する**: 配布物の構成。`.app` の署名と同梱物の存在・`Info.plist` の値・agent-plugin パッケージの構成・L10n カタログの網羅・`docs/design/tokens.json` と `DesignTokens.swift` の一致
- **担保しない**: `.app` を起動したときの挙動
- **起動と差し替え**: `.app` を**起こさず**静的に検査する（`codesign --verify --deep --strict` / `spctl` / `PlistBuddy` / ファイル存在）。tokens の drift は値の一致だけでなくトークン集合の全単射まで見る（片側だけの追加を検出できないため）
- **実行**: CI 全量

## 4. 担保しないもの

どの層も担当しないと決めたもの。壊れたら実使用で気づくことになる。

- **`.app` の起動経路と `AppDelegate` の配線**（`ControlServer.start` を実際に呼ぶのはここだけ）→ `sandbox-run` スキルで、リリース時と `.app` 構成を変えたときに人が回す
- **性能の実行時間**（起動時間・大量タブ時の応答）。SLO が定義されていない状態で時間を測ると、マシン差で flaky になるだけで回帰検知にならない。コードに書かれた境界値は L1 が固める
  - 例外はエディターの性能で、目標値を持つ。テキスト面のコマと打鍵は下の 2 項の 3 段（記録係・窓を出さない関門・画面に出す計測）で測り、構文・アウトライン・打鍵の main の仕事は、手元の release で `scripts/perf-editor.sh`（`EditorTypingPerfTests`・`EditorSyntaxPerfTests`・`EditorOutlinePerfTests` を回す。通常の `swift test` と CI では skip）が測る。打鍵 1 回で文書と Orbe 側が main でする仕事（編集の通知を受けてから文書と配り先が戻るまでの main のスレッドの CPU 時間。`typing-main`）は、64KB / 1MB / 8MB で中央値がほぼ同じ（文書の大きさに比例して増えない）こと——git 管理下（baseline あり）でも同じ。構文の裏の重さは、1MB の Swift とタグ付きテンプレートを含む 1MB の JS で、構文の崩れる打鍵（`let v = f(` の `(`）1 回の後の裏の CPU の総量が 1 秒未満、打鍵から見えている行の色が最終の色になるまで（`visible-final`。裏から届いた結果で見えている行の役割が最後に変わった時刻）が tree-sitter の差分解析の時間＋15ms 以内（`crumbling-keystroke`。差分解析の時間は、同じ打鍵を前の本文の構文の層へ写して解き直した時間を `incremental-parse` に並べる。差分解析は編集点より後ろの長さに比例する tree-sitter 本体の時間で、天井として受け入れ済み）。同じ崩れた文書で 30ms おきに 50 打鍵した間と止んでからの裏の CPU・その間の構文解析の回数・最後の打鍵から全体が揃うまで（`crumbled-burst`）と、1MB の Swift / JS / Markdown を開く直前から急かさずに全体の役割が揃うまで（`open-until-complete`。窓とファイルの用意は区間の外）も出す。裏の CPU はプロセスの CPU から main スレッドの CPU を引いたもの（窓は画面に出さないので、面は描かない）。`open-until-complete` の他は、測る前に文書の裏の仕事（文書全体の構文色）が追いつくのを待つ。アウトライン（`EditorOutlinePerfTests`）は、1MB の Swift で打鍵 1 回の main の仕事がアウトラインを開いても開かなくても変わらないこと（`typing-main (アウトラインを開いて)`）と、1MB の Swift・800KB / 5MB の package-lock.json 相当・要素の多い配列の JSON（2MB）・深い入れ子の JSON で、結果の受け取り（開いたときと、編集して取り直したとき）・カーソル追従 1 回・開閉 1 回・すべて折りたたむ／展開・絞り込みの打鍵 1 回とその結果の受け取り・列の 1 行 / 1 画面送り（描画まで）の p95 がどれも 8ms 以内であること、開いてから結果が揃うまでが深い入れ子の他は 1MB あたり 1 秒以内であることを関門にする（深い入れ子は深さの 2 乗になる問い合わせを受け入れて値を出すだけ）。打鍵 1 回の main の仕事は、開いても中央値が閉じたときの 1.5 倍以内
  - テキスト面（Metal）のコマは、完了条件を「指の出来事→画面に出た時刻（present）」と「落ちたコマ」で書き、3 段で測る。①面の中の記録係が常に動き、ジェスチャーごとの要約を OS のログ（カテゴリ `editor-frames`）へ出す。②窓を出さない自動の計測を実装の関門にする——`scripts/perf-editor-frames.sh`（release で `FramePerfTests` を回す。通常の `swift test` と CI では skip）が、画面外に 120Hz で描き GPU が描き終えた刻み（命令の列の GPU の終わりの時刻を次の刻みに切り上げたもの）を「出たコマ」とみなして、合成した指の出来事（約 5.7ms ごと。一定の速さのドラッグ・momentum 付きのはじき・端への引っ張りと離した後の戻り）を 1MB・200KB の Swift と、12000 字の行が 300 行並ぶ文書に流す。関門は、描画スレッドの 1 コマの CPU が p99 2ms 未満・描画スレッド自身が落とすコマ（画面に出る予定の刻みの 1ms 前までに命令を出し終えられなかったコマ）が 0（main に 33ms ごと 25ms の負荷を入れても）・もう 1 枚の面が画面に出なくなっても刻みごとに描き続ける・1MB と 200KB で差が無い（1 コマの CPU の中央値が 2 倍以内）・止まっている間の描画スレッドの起床が 0（スクロールで現れたつまみが消え終わった後で数える）で、他のビルドやテストが走って混んだ機械のままでも毎回通す。長い行の文書は、行を組版しなかったコマの CPU が p99 2ms 未満と、全部のコマの CPU が p99 1 刻み未満を関門にし、描画スレッド自身が落とすコマは記録して示す（初めて見える行の組版は行の長さに比例する割り切りで、長い行を数行まとめて組むコマは刻みに間に合わないことがある）。装備・強調の地・俯瞰が見えている場面（検索の一致 19999 件・語の出現・選択文字列の出現・現在の一致を置き、インデント線・空白の点・ミニマップ・スクロールバーの印が見える）でも同じ指の出来事と、ミニマップの帯の端から端へのドラッグ・縦のつまみのドラッグ（合成のマウスの出来事を面の入口へ）を流して同じ関門にかけ（`testOverviewScenes`。帯とつまみのドラッグは見えている行がコマごとに全部入れ替わる。描画スレッドのコマの多くは効率コアで動くので、関門は効率コアの上の値で通す）、一致が行ごとに千件近くある長い行の文書は長い行と同じ関門にかける（`testLongLinesWithManyMatches`）。改行だけが 100 万行続く 1MB の文書（`testBlankLines`。見えている端の行が空行の塊の中にあっても、インデント線の段のために塊をコマごとに歩かない）も 1MB の Swift と同じ関門にかける。前のコマの GPU・画面の合成の遅れで飛ばした・遅れて出たコマ（マシンの混み——画面ロック中の動く壁紙など——で起きる）、指の出来事→present、画面の間隔から見た落ちたコマは記録して示し、関門にしない（main の停止分だけ増えるのは設計上の性質）。刻みを打つスレッドは時間制約つきにする（普通の優先度だとタイマーの合体で数 ms 遅れて起き、描画スレッドのせいでない遅れを数える）。③画面に出す計測は `scripts/perf-editor-present.sh`（窓を画面に出し、1MB に合成の指の出来事を流して、記録係の要約と xctrace の Animation Hitches を取る。コマ落ちの割合は、テストが os_signpost で記録した出来事を流している区間の中の hitches を区間の長さで割る）で、実機のトラックパッドで VS Code と並べて人が見る場の結果を正とする——1MB で指のイベント→present の中央値 31ms 以下・p95 40ms 以下、動いている間のコマ落ちの時間の割合が 5ms/秒 未満。記録係の規則（落ちたコマの数え方・振り分け・分位）と刻みの止め方・再開・描画スレッドの時間制約は L1（`FrameRecorderTests`・`RenderLoopTests`）が固める
  - テキスト面の打鍵は、完了条件を「打鍵→画面に出た時刻（present）」と「打鍵 1 回の main の仕事」で書き、同じ 3 段で測る。main の仕事は main のスレッドの CPU 時間で数え、関門もそれで判定する——壁時計の時間は機械の混み具合で膨らむので参考に出すだけにし、利用者が感じる遅れは打鍵→present の関門が見る。①記録係は、取引が本文と同じ書き込みで材料の箱へ添えた打鍵の時刻から、その打鍵が入ったコマの present までを取り、打鍵の塊（間が 1 秒空けば区切る）ごとに要約を `editor-frames` へ出す。②`FramePerfTests`（`scripts/perf-editor-frames.sh`）が 1MB・200KB に合成の打鍵を 100ms と 33ms の間隔で流し、打鍵→present が中央値 12.5ms・p95 17ms 以下で 1MB と 200KB で差が無いこと、打鍵 1 回の面の編集係と文書の main の仕事が p99 1ms 以下（1 万字近い長い行の行末も）、焦点のある面の止まっている間の起床が点滅の刻み（点滅 1 回で 1 回、1 秒に 2 回）だけで焦点の無い面は 0 を関門にする（焦点・見えているか・点滅しない設定で点滅のタイマーを置くかと、タイマーが切り替わりの後の最初の刻みの半刻み前に起きることは L1 の `RenderLoopTests` が固める）。検索の一致 19999 件を出したまま、打鍵の処理の中で一致をずらして押し直す打鍵も、同じ打鍵→present の関門にかけ（`testTypingWithManyMatches`。スクロールバーの印は打鍵ごとに写し直さない）、検索語を変えて印を写し直すコマの CPU を記録して示す。main の queue に 5ms の仕事を入れ続けた状態で、Orbe から始まる呼び出し（選択を置き中央に見せ、現在の一致の地を置く）が描かれるまでを記録して示す（`testCallsFromOrbeAreDrawnWhileMainIsBusy`。runloop の 1 周の終わりを待ち続けて描かれないことが無い）。ライブ変換（未確定が 1 打鍵ごとに 1 字伸びて全体が置き換わり、20 字で確定する）も同じ関門にかける（プロセスで最初の変換は入力の仕組みの初期化なので、測る文書を開く前に別の文書で変換して数えない。窓に載せない面なので、ここの main の仕事は IME の呼び出しそのもの）。Orbe の配り先（検索・出現・プロジェクト検索）まで含めた打鍵 1 回の main の仕事は `EditorTypingPerfTests` の `keystroke-main`（`scripts/perf-editor.sh`）が p99 1ms 以下を見る。ライブ変換は、窓に載せた面で IME の呼び出しと直後の読み返し（未確定の範囲・未確定と選択の矩形・未確定の上の点の下の字）を 1 回と数える `composition-main` が見て、変換の続き（2 回目以降と確定）は 200KB・1MB・1 万字近い長い行のすべてで p99 1ms 以下、変換の始まり（未確定の先頭の x のために行を 1 回組む）は普通の行で p99 1ms 以下、長い行は値を出すだけ（除くのはプロセスで最初の 1 打鍵——入力の仕組みの初期化——と最初の変換だけで、測る文書を開く前に別の文書で打つ）。③実機の手元で 1MB を打ち、記録係の打鍵の塊の要約が中央値 31ms・p95 40ms 以下であることを人が読む
- **TCC 権限が絡む分岐の実環境挙動**（アクセシビリティ・入力監視）。分岐そのものは注入点を作って L1 で固める
- **dev / release 2 チャネル併存時の state・socket 分離**
