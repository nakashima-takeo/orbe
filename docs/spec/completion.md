---
title: コマンド補完（ドロップダウン・現状）
description: zsh の zle フックが control.sock 経由で編集バッファを host へ送り、JavaScriptCore 埋め込みの spec エンジン（cwd 連動 generator 込み）が算出した候補をカーソル位置のドロップダウンに出し Tab/Enter で zle の $BUFFER を直書換するコマンド補完
updated: 2026-07-22
---

入力中のコマンドラインに対し、カーソル位置へ候補（値＋説明）のドロップダウンを出し、選んで挿入する補完。対応は **zsh のみ**。tmux/ssh 先・bash・fish では後述の env が届かず popup が出ない（劣化なしの無効）。

## 経路（zsh ↔ host）
編集バッファの取得は zsh の zle フック → 既存 `control.sock`（[control-api](control-api.md)）直結。グリッドスクレイプや独自 OSC は使わない——`$BUFFER`/`$CURSOR` は shell の真の編集状態なので右プロンプト・複数行編集でも壊れない。socket を渡るのは「バッファ更新（通知）」と「accept（要求応答）」だけ。popup の表示・候補・選択 index はペインのローカル状態で、↑/↓/Esc は host ローカルに処理し socket を介さない。挿入は host が PTY へ流すのでなく、zsh widget が `$BUFFER` を直接書き換える。

## プロトコル契約（control.sock に追加した 3 メソッド）
[control-api](control-api.md) の改行区切り JSON-RPC に相乗り。pane は `$ORBE_PANE` で指す。

- `completion_update {paneId, buffer, cursor}` … **無応答**。host が現在トークンの候補を算出し、候補>0 かつ補完可能位置ならカーソル矩形直下に popup 表示/更新（選択 index を 0 に戻す）、さもなくば消す。候補が唯一で、accept しても buffer が変わらないときも popup を出さない。ただし直前の Enter 確定から buffer/cursor が不変の間は再表示せず閉じたまま保つ。
- `completion_accept {paneId, advance}`（id 付き要求応答）… 選択中候補を現在トークンに適用した結果 `{buffer, cursor}` を返す。候補が無い/popup 非表示なら `{buffer:null}`。応答後 popup を消す。`advance=true`（Tab）は素の候補に末尾空白を補い次トークンへ進める。`advance=false`（Enter）は末尾のパス区切り `/` を1つ落として（Tab は保つ）空白なしで確定し、以後の同一 `completion_update` による再表示を抑える。省略時は `true`。
- `completion_end {paneId}` … **無応答**。コマンド確定/中断で popup を消す。

`completion_update`/`completion_end` は host が応答を書かない（ルータが `completion_` 分岐を宛先解決ガードより前に置き、無応答メソッドは宛先不在でも応答を出さない）——これにより accept 用 fd から読める行は accept 応答だけになり、改行 framing が保たれる。

## zsh 側（`orbe-completion.zsh`）
`ORBE_SOCK`/`ORBE_PANE` 未設定なら widget を一切定義せず no-op。設定時は `zsocket` で `control.sock` へ接続を 1 本張りペイン寿命中保持する（失敗は静かに無効化・次の行頭で再接続）。

- 再描画フック: `$BUFFER`/`$CURSOR` が前回送信値から変化したときだけ `completion_update` を fire-and-forget で送る。
- 確定（Tab / Enter）: `completion_accept` を送り 1 行応答を読む。`result.buffer` が非 null なら `$BUFFER`/`$CURSOR` を直書換（改行は送らない）——Tab は末尾空白を補い次トークンへ進み、Enter は空白なしで確定して popup を閉じる（host が再表示を抑えるので次の Enter は accept 不可となりコマンド実行へ回る）。null/失敗時のフォールバックはキーごとに分かれ、Tab は退避した従来 Tab、Enter は `accept-line`（＝コマンド実行）へ。いずれもキー bind で自前 widget を挟む方式で、`accept-line` widget 自体は差し替えない。
- 行終了フック: `completion_end` を送る。

既存 zle フック（zsh-syntax-highlighting 等）は退避してチェーン呼び出しし、壊さない。JSON 文字列化は制御文字をエスケープし、複数行 buffer も 1 行 JSON に収める。

## host 側 UI
popup は端末ビューに載せた SwiftUI ホスト。**focusable な要素を持たず**端末が first responder のまま——popup 表示中も通常文字入力・IME がそのまま PTY に届く。位置は libghostty の IME point から毎 update 算出してカーソルに追従、画面下端で溢れるならカーソル上に、右端で溢れるなら左へ寄せる。見た目は補完専用のガラスパネル popup で、背景透過設定に連動して薄まり、ブラー OFF では素通し半透明になる（[config](config.md)）。popup 表示中かつ IME 非変換中のときだけ ↑/↓（選択移動）・⌘↑/⌘↓（先頭/末尾候補へジャンプ）・Esc（消去）を chrome キーより先取りし、それ以外・popup 非表示時は素通しする（popup を閉じれば ⌘↑↓ は従来どおり端末スクロールバック先頭/末尾）。⌘⇧↑↓ は popup 表示中も横取りしない。

### レイアウト（素の候補リスト）
候補の種別は fig の suggestion `type` **のみ**から導出する（description 文字列には結合しない＝汎用・git 固有判定なし）: オプション / サブコマンド / ファイル / それ以外は候補。表示順は種別順（サブコマンド→候補→ファイル→オプション＝位置候補を先・修飾子を後）で、engine の flat 候補を**この順へ 1 度だけ並べ替えて**保持し（種別グループ化の直前に学習ランキングで安定再ソートしてから種別へ畳む。学習ゼロなら engine 返却順を安定保持）、選択 index・accept はこの並びの上で回る。engine 側の flat 候補は **一致品質(完全>前方>部分) → priority → 名前長(短い順・query 入力時のみ) → 元順序で安定** の合成順で並ぶため、種別内では query に完全一致する候補が上に来る。空 query の全列挙は列挙順を安定保持する（名前長で並べ替えない）。見出し・footer は持たない。

### 学習ランキング（頻度・recency）
engine(JS) は純関数のまま、host が種別グループ化の直前に**学習キーで安定再ソート**する。accept（Tab／Enter 双方）で候補の使用回数・最終使用時刻を記録し、読み取り時に frecency（半減期つき指数減衰）へ合成する。ソートキーは **一致品質 降順 → frecency 降順 → engine 元順**で、元 index を最終タイブレークに安定化する。一致品質が最上位キーゆえ**完全一致優先は不可侵**、学習ゼロ（新規ユーザ）は engine 返却順と完全一致する。

学習対象は accept された**全候補**で、記録単位のスコープを候補種別で二層化する: **静的候補**（subcommand / option）は現在トークン直前までの**全プレフィックス**（別コンテキストへの誤爆防止）、**動的候補**（それ以外＝file・folder・arg・type 無し等）は **root コマンド 1 語**（`git switch` で覚えたブランチが `git rebase <Tab>` でも上がる＝サブコマンド間で共有）。コマンド名自体の補完は両層とも空スコープ。二層の導出は 1 関数系に集約し、record（accept 経路）と rank（update 経路）が必ず共有する（非対称を構造的に排除）。相対ナビゲーション候補（`../` 等）は記録から除外する。層間でキーが衝突し得るが帰結は無害なブーストに留まるため名前空間は分けない。永続は state ディレクトリ（`ORBE_STATE_DIR` 隔離規約に追従）の JSON で、accept ごとに atomic 書き込み・件数上限を超えたら frecency 最小を退避。

行はテキストのみ。**インライン説明列は持たず**説明は side card だけが持つ。現在トークンの**入力済みプレフィックス**（候補値と先頭一致するとき）は accent 色で強調する。選択行は淡塗り（形グリフ・左バー・太字は持たない）。パネル幅は**内容フィット**（最長候補の実測幅・上限あり）。

候補は engine から**全件取得**（総数キャップ無し）して保持し、可視ぶんだけを仮想描画、超過分はスクロールする。スクロールは自前の viewport clip + offset——可視インデックス範囲を算出して**その行だけ生成し**（数百件でも生成行は十数行）、スライスを offset して外側で clip する。スクロール位置は独立した状態を持たず選択 index から派生して算出し（行高が固定なので決定的）、選択行が常に可視域に収まるようクランプする。超過時のみ細いつまみと下端フェードを重ねる（透過時はフェードも薄め不透明帯を残さない）。↑/↓ は host ローカルで選択を回し、view が再算出して追従する。

**side detail card**: 選択候補に **description があるときだけ**、本体の脇（右・画面右端で溢れるなら左）に小カードを出す。中身は汎用データのみ——種別グリフ＋名前＋description で、git メタ（最終更新・コミット等）は出さない。左右反転は SwiftUI の HStack 内では出せないため、利用可能空間を知る AppKit 側が配置を担う。縦は本体 top 揃え。description が空の候補（ブランチ名・パス等）ではカードを出さない。

表示・選択移動とも instant（アニメ無し）。

### IME preedit 共存
日本語 IME 変換中は popup を**抑止**する——未確定文字は shell の `$BUFFER` に未反映で、confirmed buffer 基準の候補を出すのは誤誘導だから。preedit が始まると popup を消し、変換確定で確定文字が PTY→shell→`$BUFFER` へ入り `completion_update` 経由で候補があれば popup が復帰する。preedit 中の Tab/↑/↓/Esc は IME（確定・候補移動・変換取消）に帰属し popup へ漏れない。

## 候補エンジン
候補ソースは **JavaScriptCore 埋め込みの spec エンジン**。fig の補完 spec エコシステム（withfig/autocomplete）の宣言的 spec を、inshellisense 由来の parser/suggestion ロジックで解釈する。エンジンは prebuilt の単一 JS バンドルを `JSContext` に load して駆動する（spec の `postProcess` 等が JS 関数のため JS ランタイムが要る）。同梱 spec は主要コマンドの curated subset（一覧は `vendor/completion-engine/README.md`）。うち `claude`・`codex` は上流に無い**自家最小 spec**（実 CLI の `--help` 実測由来・純静的）。

- **責務分界**: JS は parse・spec 走査・postProcess（純変換）だけを担い、シェルは叩かない。spec の generator（動的候補）が要求するシェル実行は、Swift が `JSContext` へ注入した native 関数経由で `posix_spawn` が行う——当該ペインの cwd（OSC 7、未報告時は initialCwd→ホーム）で `zsh -c`・login PATH・stdin 無し・stdout のみ・**数秒のハードタイムアウト**・失敗/タイムアウトは空（静的候補は保つ）。子は自分の**プロセスグループのリーダー**として起こし、タイムアウト時はグループごと kill する——孫が pipe を握り続けると書き手が残って EOF が起きず、drain が永久ハングして補完 queue が恒久停止するため。出力は別 queue で drain する。これにより `git checkout <Tab>` が実ブランチ名、`ls <Tab>` がカレント dir の実ファイルを出す。
- **スレッド規律**: `JSContext` とシェル実行は専用 serial queue（main 非依存）、popup 表示は main へ hop。候補取得は**非同期**で `completion_update` から駆動し、連続更新は debounce で coalesce、generator 結果は短 TTL キャッシュ。ペインごとの単調増加 token で**古い結果を破棄**する（stale ガード）。
- **accept**: `completion_accept` はキャッシュした置換範囲＋選択候補の挿入値から適用結果を **main・同期**で組む（JS round trip 無し＝zsh 側の短い read タイムアウト内に収める）。Tab のとき、素の候補は挿入直後に空白を1つ補い次トークンへ進める（後続が既に空白なら足さない）。明示挿入値を持つ候補（`--flag=`・パス末尾 `/` 等）は verbatim 挿入で空白を足さない（inshellisense 忠実）。Enter は末尾のパス区切り `/` を1つ落として空白を足さず確定し（ディレクトリを `src` の形で確定）、以後の再表示を抑える。候補取得が追いつく前の accept は退避し従来 Tab へフォールバックする。
- **出力スキーマ**: バンドルの出力候補は名前・説明・任意の挿入値・任意の `type`（fig の suggestion type）。host は `type` を保持して UI の種別グルーピング・グリフ導出に使う（generator 出力など type 無しは nil）。スキーマを変えたら `vendor/completion-engine/` でバンドルを再生成しコミットする。

## 自動インストール
`.app` に `orbe-completion.zsh` を同梱し、surface 生成時にその絶対パスを env `ORBE_COMPLETION_ZSH`（バンドル有時のみ）で `ORBE_PANE`/`ORBE_SOCK` と同じ経路で注入する。初回起動時（onboarding と同じ経路）にユーザの `~/.zshrc`（`$ZDOTDIR` 尊重・symlink は実体へ解決）へ managed block を冪等追記する:

```
# >>> Orbe completion >>>
[[ -n $ORBE_COMPLETION_ZSH ]] && source "$ORBE_COMPLETION_ZSH"
# <<< Orbe completion <<<
```

source 先を固定パスでなく env 参照にしてあるため block 文言は不変で、2 回実行しても 1 ブロック（冪等）、マーカー外の既存行は不可侵、非 Orbe shell では env ガードで完全 no-op。`uninstall` はマーカー対のみ除去する。

## 境界
- 対応 shell は zsh のみ。bash/fish・tmux/ssh 先は env 不達で無効。
- 同梱 spec は curated subset のみ（上流 600+ の全網羅・ユーザ提供 spec・上流 spec の自家 fork 運用は無い。`claude`/`codex` の自家 spec は上流に無いコマンドの新規最小 spec であり fork ではない）。
- generator のシェル実行は vendored curated spec のみが起点＝信頼境界内。任意のユーザ spec は受けない。
- `swift run`（バンドル無し）では env 未注入で managed block が no-op・engine 未ロードで候補非表示（クラッシュしない）。

バンドルの再生成一式は `vendor/completion-engine/`（npm/esbuild・trim/改変した runtime・curated spec・上流 SHA pin）、由来表記はリポジトリ root の `NOTICE`。
