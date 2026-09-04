---
title: コマンド補完
description: zsh の zle フックが control.sock 経由で編集バッファを送り、JavaScriptCore 埋め込みの spec エンジンが候補を算出、カーソル位置のドロップダウンから $BUFFER を直接書き換える
updated: 2026-09-04
---

# コマンド補完

入力中のコマンドラインに対し、カーソル位置へ候補（値＋説明）のドロップダウンを出し、選んで挿入する IDE 風の補完。対応は **zsh のみ**。tmux/ssh 先・bash・fish では後述の env が届かず popup が出ない（劣化なしの無効）。

## 経路（zsh ↔ host）

編集バッファの取得は zsh の zle フック → 既存 `control.sock`（[control/api](../control/api.md)）直結。グリッドスクレイプや独自 OSC は使わない——`$BUFFER`/`$CURSOR` は shell の真の編集状態なので、右プロンプト・複数行編集でも壊れない。socket を渡るのは「バッファ更新（通知）」と「accept（要求応答）」だけ。popup の表示・候補・選択 index はペインのローカル状態で、↑/↓/Esc は host ローカルに処理し socket を介さない。挿入は host が PTY へ流すのではなく、zsh widget が `$BUFFER` を直接書き換える。

## プロトコル契約（control.sock に追加した 3 メソッド）

[control/api](../control/api.md) の改行区切り JSON-RPC に相乗りする。pane は `$ORBE_PANE` で指す。

- `completion_update {paneId, buffer, cursor}` … **無応答**。host が現在トークンの候補を算出し、候補>0 かつ補完可能位置ならカーソル矩形直下に popup 表示/更新（選択 index を 0 に戻す）、さもなくば消す。候補が唯一で、accept しても buffer が変わらないときも popup を出さない。ただし直前の Enter 確定から buffer/cursor が不変の間は再表示せず閉じたまま保つ。
- `completion_accept {paneId, advance}`（id 付き要求応答）… 選択中候補を現在トークンに適用した結果 `{buffer, cursor}` を返す。候補が無い/popup 非表示なら `{buffer:null}`。応答後 popup を消す。`advance=true`（Tab）は素の候補に末尾空白を補い次トークンへ進める。`advance=false`（Enter）は末尾のパス区切り `/` を 1 つ落として（Tab は保つ）空白なしで確定し、以後の同一 `completion_update` による再表示を抑える。省略時は `true`。
- `completion_end {paneId}` … **無応答**。コマンド確定/中断で popup を消す。

`completion_update`/`completion_end` は host が応答を書かない（ルータが `completion_` 分岐を宛先解決ガードより前に置き、無応答メソッドは宛先不在でも応答を出さない）——打鍵ごとの update が accept 用 fd に行を積まないため。ただし読めない行には host が分岐より前で `id:null` のエラー行を返すため、この fd に accept 応答以外が混じることはある。zsh 側は accept ごとに進める `id` を送り、`"id":<n>` が値の終端まで一致する行だけを選んで読む——接続は持続するので、締切内に読めなかった応答は fd に残る。id が進まなければ次の確定がそれを拾い、以後ずっと 1 つ前の応答をコマンドラインへ適用し続けてしまうため。

## zsh 側（`orbe-completion.zsh`）

`ORBE_SOCK`/`ORBE_PANE` 未設定なら widget を一切定義せず no-op。設定時は `zsocket` で `control.sock` へ接続を 1 本張り、ペイン寿命中保持する（失敗は静かに無効化・次の行頭で再接続）。

- 再描画フック: `$BUFFER`/`$CURSOR` が前回送信値から変化したときだけ `completion_update` を fire-and-forget で送る。
- 確定（Tab / Enter）: `completion_accept` を送り 1 行応答を読む。`result.buffer` が非 null なら `$BUFFER`/`$CURSOR` を直書換する（改行は送らない）——Tab は末尾空白を補い次トークンへ進み、Enter は空白なしで確定して popup を閉じる（host が再表示を抑えるので次の Enter は accept 不可となりコマンド実行へ回る）。null/失敗時のフォールバックはキーごとに分かれ、Tab は退避した従来 Tab、Enter は `accept-line`（＝コマンド実行）へ。いずれもキー bind で自前 widget を挟む方式で、`accept-line` widget 自体は差し替えない。
- 行終了フック: `completion_end` を送る。

既存 zle フック（zsh-syntax-highlighting 等）は退避してチェーン呼び出しし、壊さない。JSON 文字列化は制御文字をエスケープし、複数行 buffer も 1 行 JSON に収める。

## host 側 UI

popup は端末ビューに載せた SwiftUI ホスト。**focusable な要素を持たず**端末が first responder のまま——popup 表示中も通常文字入力・IME がそのまま PTY に届く。位置は libghostty の IME point から毎 update 算出してカーソルに追従し、画面下端で溢れるならカーソル上に、右端で溢れるなら左へ寄せる。見た目は補完専用のガラスパネル popup で、背景透過設定に連動して薄まり、ブラー OFF では素通し半透明になる（[config](../platform/config.md)）。popup 表示中かつ IME 非変換中のときだけ ↑/↓（選択移動）・⌘↑/⌘↓（先頭/末尾候補へジャンプ）・Esc（消去）を chrome キーより先取りし、それ以外・popup 非表示時は素通しする（popup を閉じれば ⌘↑↓ は従来どおり端末スクロールバック先頭/末尾）。⌘⇧↑↓ は popup 表示中も横取りしない。

### レイアウト（素の候補リスト）

候補の種別は fig の suggestion `type` **のみ**から導出する（description 文字列には結合しない＝汎用・git 固有判定なし）: オプション / サブコマンド / ファイル / それ以外は候補。表示順は種別順（サブコマンド→候補→ファイル→オプション＝位置候補を先・修飾子を後）で、engine の flat 候補を**この順へ 1 度だけ並べ替えて**保持し（種別グループ化の直前に学習ランキングで安定再ソートしてから種別へ畳む。学習ゼロなら engine 返却順を安定保持）、選択 index・accept はこの並びの上で回る。engine 側の flat 候補は **一致品質(完全>前方>部分) → priority → 名前長(短い順・query 入力時のみ) → 元順序で安定** の合成順で並ぶため、種別内では query に完全一致する候補が上に来る。空 query の全列挙は列挙順を安定保持する（名前長で並べ替えない）。見出し・footer は持たない。

行はテキストのみ。**インライン説明列は持たず**、説明は side card だけが持つ。**engine が照合に使った正規化済みトークン**（候補値と先頭一致するとき）は accent 色で強調する——候補リストは候補値をそのまま並べるので、パス候補では basename 部分が光り、ディレクトリを打ち切った位置（照合トークンが空）ではどこも光らない。選択行は淡塗り（形グリフ・左バー・太字は持たない）。パネル幅は**内容フィット**（最長候補の実測幅・上限あり）。

候補は engine から**全件取得**（総数キャップ無し）して保持し、可視ぶんだけを仮想描画、超過分はスクロールする。スクロールは自前の viewport clip + offset——可視インデックス範囲を算出して**その行だけ生成し**（数百件でも生成行は十数行）、スライスを offset して外側で clip する。スクロール位置は独立した状態を持たず選択 index から派生して算出し（行高が固定なので決定的）、選択行が常に可視域に収まるようクランプする。超過時のみ細いつまみと下端フェードを重ねる（透過時はフェードも薄め、不透明帯を残さない）。↑/↓ は host ローカルで選択を回し、view が再算出して追従する。

**side detail card**: 選択候補に **description があるときだけ**、本体の脇（右・画面右端で溢れるなら左）に小カードを出す。中身は汎用データのみ——種別グリフ＋名前＋description で、git メタ（最終更新・コミット等）は出さない。左右反転は SwiftUI の HStack 内では出せないため、利用可能空間を知る AppKit 側が配置を担う。縦は本体 top 揃え。description が空の候補（ブランチ名・パス等）ではカードを出さない。

表示・選択移動とも instant（アニメ無し）。

### 学習ランキング（頻度・recency）

engine(JS) は純関数のまま、host が種別グループ化の直前に**学習キーで安定再ソート**する。accept（Tab／Enter 双方）で候補の使用回数・最終使用時刻を記録し、読み取り時に frecency（半減期つき指数減衰）へ合成する。ソートキーは **一致品質 降順 → frecency 降順 → engine 元順**で、元 index を最終タイブレークに安定化する。一致品質は engine と同じ照合トークンで測るため、パス区切りを含むトークンでも候補名（basename）と噛み合う。一致品質が最上位キーゆえ**完全一致優先は不可侵**、学習ゼロ（新規ユーザ）は engine 返却順と完全一致する。

学習対象は accept された**全候補**で、記録単位のスコープを候補種別で二層化する。二層とも engine の**確定コマンド列**から導く: **静的候補**（subcommand / option）はコマンド列そのもの（`git commit`。別コンテキストへの誤爆防止）、**動的候補**（それ以外＝file・folder・arg・type 無し等）はその**先頭 1 語**（`git switch` で覚えたブランチが `git rebase <Tab>` でも上がる＝サブコマンド間で共有）。ある補完点の静的候補集合を決めるのは spec ノードだけなので、途中のオプションや引数の自由テキストはキーに入らない（`git commit -m "…" --am` の静的スコープは `git commit`）。コマンド列は同一 spec ノードで一意に定まる名前で持つため、**打鍵の綴りが違っても学習を共有する**（`npm i` と `npm install` は同じキー）。コマンド名自体の補完は両層とも空スコープ。二層の導出は 1 関数系に集約し、record（accept 経路）と rank（update 経路）が必ず共有する（非対称を構造的に排除）。相対ナビゲーション候補（`../` 等）は記録から除外する。層間でキーが衝突し得るが、帰結は無害なブーストに留まるため名前空間は分けない。永続は state ディレクトリ（`ORBE_STATE_DIR` 隔離規約に追従）の JSON で、accept ごとに atomic 書き込み・件数上限を超えたら frecency 最小を退避する。キーの形が変わったら version を上げ、**別 version のファイルは読まずに捨てる**——学習は体験を良くするキャッシュであって、移行してまで保つユーザ資産ではない。

### IME preedit 共存

日本語 IME 変換中は popup を**抑止**する——未確定文字は shell の `$BUFFER` に未反映で、confirmed buffer 基準の候補を出すのは誤誘導だから。preedit が始まると popup を消し、変換確定で確定文字が PTY→shell→`$BUFFER` へ入り、`completion_update` 経由で候補があれば popup が復帰する。preedit 中の Tab/↑/↓/Esc は IME（確定・候補移動・変換取消）に帰属し、popup へ漏れない。

## 候補エンジン

候補ソースは **JavaScriptCore 埋め込みの spec エンジン**。fig の補完 spec エコシステム（withfig/autocomplete）の宣言的 spec を、inshellisense 由来の parser/suggestion ロジックで解釈する。エンジンは prebuilt の単一 JS バンドルを `JSContext` に load して駆動する（spec の `postProcess` 等が JS 関数のため JS ランタイムが要る）。同梱 spec は主要コマンドの curated subset（一覧は `vendor/completion-engine/README.md`）。うち `claude`・`codex` は上流に無い**自家最小 spec**（実 CLI の `--help` 実測由来・純静的）。

- **責務分界**: JS は parse・spec 走査・postProcess（純変換）だけを担い、シェルは叩かない。spec の generator（動的候補）が要求するシェル実行は、Swift が `JSContext` へ注入した native 関数経由で `posix_spawn` が行う——当該ペインの cwd（OSC 7、未報告時は initialCwd→ホーム）で `zsh -c`・子プロセス PATH（[shell-path](../platform/shell-path.md)）・stdin 無し・stdout のみ・**数秒のハードタイムアウト**・失敗/タイムアウトは空（静的候補は保つ）。子は自分の**プロセスグループのリーダー**として起こし、タイムアウト時はグループごと kill する——孫が pipe を握り続けると書き手が残って EOF が起きず、drain が永久ハングして補完 queue が恒久停止するため。出力は別 queue で drain する。これにより `git checkout <Tab>` が実ブランチ名、`ls <Tab>` がカレント dir の実ファイルを出す。
- **スレッド規律**: `JSContext` とシェル実行は専用 serial queue（main 非依存）、popup 表示は main へ hop。候補取得は**非同期**で `completion_update` から駆動し、連続更新は debounce で coalesce、generator 結果は短 TTL キャッシュ。ペインごとの単調増加 token で**古い結果を破棄**する（stale ガード）。
- **accept**: `completion_accept` はキャッシュした置換範囲＋選択候補の挿入値から適用結果を **main・同期**で組む（JS round trip 無し＝zsh 側の短い read タイムアウト内に収める）。Tab のとき、素の候補は挿入直後に空白を 1 つ補い次トークンへ進める（後続が既に空白なら足さない）。明示挿入値を持つ候補（`--flag=`・パス末尾 `/` 等）は verbatim 挿入で空白を足さない（inshellisense 忠実）。Enter は末尾のパス区切り `/` を 1 つ落として空白を足さず確定し（ディレクトリを `src` の形で確定）、以後の再表示を抑える。候補取得が追いつく前の accept は退避し、従来 Tab へフォールバックする。
- **出力スキーマ**: 出力は候補列と、engine が解析時に確定させた事実の組。候補は名前・説明・任意の挿入値・任意の `type`（fig の suggestion type）。解析事実は 3 つ——**置換長**（現在トークンの文字数）、**照合トークン**（engine が絞り込みと並べ替えに実際に使った正規化済みの現在トークン。パス候補では basename、ディレクトリを打ち切った位置では空）、**確定コマンド列**（root ＋走査で確定したサブコマンドを、同一 spec ノードで一意に定まる名前〔宣言配列の先頭〕で並べたもの。打鍵の綴りが違っても同じ spec ノードなら同じ列になり、コマンド名自体の補完では空）。置換長と照合トークンは分界がある——前者は**置換すべきトークン全域**＝編集の座標、後者は**候補名と比較できる部分**＝照合の入力で、basename 化は不可逆ゆえ片方から他方は導けない（`cat sub/mai` なら置換長 7・照合トークン `mai`）。host は `type` を UI の種別グルーピング・グリフ導出に（generator 出力など type 無しは nil）、照合トークンをプレフィックス強調と一致品質に、確定コマンド列を学習スコープに使う——どれも生バッファから導き直さない。スキーマを変えたら `vendor/completion-engine/` でバンドルを再生成しコミットする。

## 自動有効化（ZDOTDIR interposition）

ユーザのファイルには書き込まない。`.app` の `Resources/zsh/` に shim `.zshenv` と `orbe-completion.zsh` の 2 ファイルを同梱し、GUI 起動時（Ghostty 初期化前・バンドル有時のみ）にプロセス env へ `ZDOTDIR=<shim dir>` を据える。surface spawn の base env はプロセス env そのものなので全ペインへ届く。注入点はプロセス env でなければならない——surface config の env_vars は ghostty の shell integration setup に後勝ちし、ghostty が立てた ZDOTDIR を上書きして integration（OSC 7 の cwd 報告）を壊すため。

**Orbe の shim dir** は `orbe-completion.zsh` を持つ dir で同定する（本番 / Dev / 旧版を区別しない）。GUI と shim が同じ述語を使う。

**ユーザの ZDOTDIR の受け渡し**: GUI は継承 env の `ZDOTDIR` → `ORBE_USER_ZDOTDIR` の順で「空でなく Orbe の shim dir でない」最初の値をユーザの ZDOTDIR とし、あれば `ORBE_USER_ZDOTDIR` に据え、無ければ消す（親 Orbe や汚染したシェルから継いだ shim dir・空文字はユーザ値ではない）。`ORBE_USER_ZDOTDIR` は GUI → shim の一回きりの経路で、shim が読んだ時点で消える。

shim `.zshenv` は全 zsh 起動で読まれ、次の順で働く。

1. `ORBE_USER_ZDOTDIR` を `ZDOTDIR` に復元して消す（無ければ `ZDOTDIR` を unset＝home）。
2. 復元した値が空文字・Orbe の shim dir なら unset へ倒す。これが env の汚染からの自力回復で、shim を「ユーザの `.zshenv`」として source する再帰経路は構造的に閉じている。
3. ユーザの `.zshenv`（`$ZDOTDIR`、無ければ home）を source する。
4. interactive のときだけ、一回きりの precmd フックを積む。フックは最初のプロンプト直前に走り、自分を外して消えてから `orbe-completion.zsh` を source する（ユーザの alias・オプションから隔離した関数スコープでパースする）。

以降 shim は `ZDOTDIR` に触らない。続く `.zprofile`・`.zshrc`・`.zlogin` は zsh がユーザの dir から素で読むため、ユーザが `~/.zshenv` で `ZDOTDIR` を設定する構成もそのまま生きる。widget は**全 startup file の後**に bind され、ユーザの `.zshrc` 末尾の Tab bind（fzf-tab 等）に後勝ちし、既存の Tab bind は `$_ORBE_TAB_FALLBACK` へ退避されて popup 非表示時のフォールバックになる。

様式は ghostty/kitty shim と同一（`builtin` 前置・全クォート・`always` 節。alias 展開下でも壊れないための規律で、独自変更しない）。ghostty の shell integration 有効時（既定）は ghostty が shim を「ユーザの ZDOTDIR」として `GHOSTTY_ZSH_ZDOTDIR` へ退避・復元するため、ghostty shim → Orbe shim → ユーザ設定の順に連鎖する。`shell-integration = none` でも spawn env の ZDOTDIR がそのまま残り自立動作する。

旧方式が `~/.zshrc` へ書いた managed block が残る環境では、起動時に一度だけマーカー対を除去する（マーカー外は不可侵）。

## 境界

- 対応 shell は zsh のみ。bash/fish・tmux/ssh 先は env 不達で無効。
- Orbe が起こした zsh の子プロセス env に `ZDOTDIR=<shim dir>`・`ORBE_USER_ZDOTDIR` は残らない（対話・非対話・login を問わず）。非 zsh で起動したペイン（agent ペイン等）の env には GUI が据えた両者が見えるが、そこから zsh を起こしても shim が消費してユーザ設定へブリッジする。
- `exec zsh` は shim を経ず補完無効（ghostty shell integration と同じ制限）。
- `ORBE_USER_ZDOTDIR` が削除済み `.app` の shim dir を指す場合は同定できず、`ZDOTDIR` が不在の dir を指したままユーザ rc は読まれない（widget は入る）。
- `zsh -i -c`（プロンプトを出さない）では precmd が走らず widget は入らない。
- precmd 段で bind・keymap 切替をするプラグイン（zsh-vi-mode の既定 lazy init 等）には `^I` / `^M` を奪われる。Orbe のフックはユーザの `.zshrc` が積む precmd より先に走るため（zsh-vi-mode は `ZVM_INIT_MODE=sourcing` で回避できる）。ユーザ設定が `precmd_functions` を代入で丸ごと潰す場合も widget は入らない。
- 同梱 spec は curated subset のみ（上流 600+ の全網羅・ユーザ提供 spec・上流 spec の自家 fork 運用は無い。`claude`/`codex` の自家 spec は上流に無いコマンドの新規最小 spec であり fork ではない）。
- generator のシェル実行は vendored curated spec のみが起点＝信頼境界内。任意のユーザ spec は受けない。
- `swift run`（バンドル無し）では ZDOTDIR 未設定＝素の zsh 起動・engine 未ロードで候補非表示（クラッシュしない）。

バンドルの再生成一式は `vendor/completion-engine/`（npm/esbuild・trim/改変した runtime・curated spec・上流 SHA pin）、由来表記はリポジトリ root の `NOTICE`。
