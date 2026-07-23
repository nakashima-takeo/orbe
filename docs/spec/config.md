---
title: 設定（現状）
description: キュレート既定 → user 設定 → GUI 生成 conf の後勝ち3層読み込みと、テーマ（Auto/Dark/Light 外観スイッチ）によるライト/ダーク決定
updated: 2026-07-23
---

## 3 層読み込み

`Config.load()` が3層を後勝ちで読む: ① キュレート既定 `app/orbe-defaults.conf`（バンドル同梱・非バンドル起動〔素の `swift build`〕では不在でスキップ）、② user の `~/.config/ghostty`、③ `StateDir.base()/gui.conf`（存在時のみ）。後勝ちなので user が既定を上書きし、GUI 生成 conf が user 設定にも勝つ。user の `~/.config/ghostty` は一切書き換えない。

層1（キュレート既定）が持つのは端末テーマ・フォントチェーン・背景不透明度/ブラー・パディング・カーソル・シェル統合の既定。うち意図が値に宿るもの:

- `theme = light:OrbeLight,dark:OrbeDark` … 自前 named theme 2 枚。`app/themes/` の実体は識別色 SSOT（`DesignSystem/OrbePalette.swift`）から生成・コミットされ、`swift test` が ANSI ink スロットの WCAG AA と SSOT 再生成の drift を検証し、さらに層1と gui.conf の `theme =` 行からテーマ名をパースして `app/themes/<name>` の実在を照合する——テーマ名は層1・gui.conf・テーマファイル名・`build-app.sh` の4箇所に独立して埋まり、解決に失敗しても ghostty は診断を積むだけで既定色のまま起動してしまうため。
- 本文等幅チェーンは JetBrainsMono Nerd Font（プライマリ・4スタイル同梱で bold/italic も設計字形）→ JuliaMono（広カバレッジ fallback）。JuliaMono を明示段に置くのは、JetBrains に無い記号を ghostty 解決順の最終段（discovery＝起動文脈・LANG 依存で不安定）より前で決定論的に確定するため。これら同梱 TTF（絵文字用含む）は起動時（フォント解決より前）にプロセス登録する（非バンドル起動では no-op）。
- 日本語コードポイント範囲を `Hiragino Sans W3` へ固定する `font-codepoint-map` … CJK フォールバックが起動文脈の優先言語に依存して中華字形になるのを防ぐ。解決順の最上位で名前解決するためプライマリ等幅に不干渉。ウェイトを W3 と明示するのはファミリ名だけだと極細の W0 まで全マッチするため。UI 言語切替はプロセスのロケールに触れない（[localization](localization.md)）ので、この固定は日英どちらでも不変。
- 背景不透明度は既定でわずかに透ける（設定パレットの既定と対称。GUI 未介入でも初期から透過）、`background-blur` も既定 ON。
- `shell-integration-features = no-cursor,no-title` … cursor はプロンプトでの bar 上書きを止めブロックを効かせ、title は自動タイトル送出を止めてタブ名を chrome の precedence へ委ねる（→ [chrome](chrome.md)）。
- 絵文字の `font-codepoint-map` は層1に置かず gui.conf（層3）が**常時出力**する（単一出所・後述）。

## gui.conf（GUI 管理層）

設定パレット（[settings-palette](settings-palette.md)）が実効設定から再生成する層。実効設定の raw 値（明示されたキーだけ・既定へは解決しない）を sparse に書く。例外は 2 つの**常時行**:

- `theme = light:OrbeLight,dark:OrbeDark` を設定値に関わらず常時書く（全 nil でも空ファイルにはならない）——user の `~/.config/ghostty` の `theme =` を層3の後勝ちで恒久無効化し、ターミナル配色を Orbe の 2 枚に固定するため（`palette =` 等の個別色キー直書きは容認スコープ外）。ライト/ダークのどちらに見せるかはこの行でなくテーマ設定（外観スイッチ）が決める。
- 絵文字の `font-codepoint-map` を絵文字フォント設定から分岐して常時書く: noto は emoji-presentation 全域（Unicode プロパティを実行時走査して範囲圧縮。chrome 側と同一の判定源＝端末とタブの対象集合が定義上一致）を同梱 Noto Color Emoji（sbix 変換版）へ、apple は JuliaMono の横取りを防ぐ固定集合だけを Apple Color Emoji へ向ける。text-presentation の記号はどちらの map にも含めず presentation で出し分ける。text 既定＋VS16 の文字（❤️ 等）は map 対象外＝端末セルでは Apple のまま（codepoint-map は VS 条件を表現できない）。map は font-family でないため後述の reset 非対象で、user 層の同名 map には後着の層3が勝つ。

`font-family` は gui.conf が解決順の最後で append されるため、既定チェーンへ単純追記すると選択が末尾に回って無視される——**空値でチェーンを reset → 選択をプライマリに据え直し → 末尾 fallback を再付与**の3行を吐く。絵文字の color 固定は上記の常時 codepoint-map が担い reset の影響を受けない。背景不透明度は percent Int を整数演算で 2 桁固定の小数へ変換して書く（浮動小数の誤差を避ける）。ブラー・カーソル点滅は Bool をそのまま書き、nil なら行を出さず層1の既定に委ねる。カーソル色はテーマ側 `cursor-color`（accent トークン）固定で GUI から変更できない。出力行と順序は設定レジストリ（各項目の宣言を 1 箇所に集約）を走査して組む。

## 実効設定と反映

`regenerate` に渡すのは global 層にアクティブ workspace の上書き層を重ねた**実効設定**（[workspace](workspace.md)）。値の担体はスコープ非依存の均一レイヤで、**全設定が workspace 上書き可**。gui.conf に出るのはフォント/テーマ/背景/カーソル/絵文字系のみで、`default-agent`（AgentLauncher 直行）・`agent-state-icons`／`tab-title-font-family`（chrome へ直配信・[chrome](chrome.md)）・`dev-features`（右バーの UI gate）は gui.conf を経由しない。

反映は集約点 `WindowController.applyActiveWorkspaceConfig()`（外観同期→gui.conf 再生成→config reload）に一本化し、**workspace 切替・起動復元・空 workspace アクティブ化の共有経路・初回起動・新規 workspace 作成（上書き無し＝global 実効へ切り替え、前 workspace の上書きを持ち越さない）・設定パレット適用**が呼ぶ。画面に載るのは常にアクティブ 1 workspace のみなので、全 surface へ一律伝播する reload で常に正しい。font-size のライブ反映は trailing デバウンスでキーリピートの連射を畳む。

## 背景透過とブラー（host 側の配線）

背景不透明度は surface アルファ（libghostty）だけでは背景が合成されず透けないため、host NSWindow 側の透過を対で適用する（本家 ghostty 踏襲）: 透過かつ非フルスクリーンのとき窓を非不透明・ほぼ透明な背景色にし、それ以外は不透明へ戻す。適用は起動時・config reload 後（surface アルファ更新と同一 tick）・フルスクリーン遷移の 3 経路。判定に読む値はアクティブ workspace の実効設定（未構築の init 初回は global にフォールバック）。

同一 tick で chrome 各面へも透過を配る: 実効の不透明度/ブラーから `ChromeTranslucency`（実効 opacity・透過フラグ・ブラーフラグ）を更新し、Environment 注入された chrome 面（StatusRow・GlassPanel・EditorPane・端末上に浮く検索バー／補完 popup）が自分の地を薄めて端末面と veil 濃度を揃える。浮遊 popup は別ホストビューなので窓 delegate 経由でホルダーを解決し、hosting layer を非不透明にして素通し半透明を端末面まで通す。背景グローは透過時に不透明地を敷かない（二重 veil 回避）。GlassPanel はブラー ON で VisualEffectView を残し、OFF で外して素通し半透明にする（→ [layout](layout.md)・[settings-palette](settings-palette.md)）。

`background-blur` は gui.conf 再生成＋reload だけでは効かない——macOS の背後ブラーは private CGS API 経由で、host が自分の NSWindow を渡して能動的に呼ぶ配線が必須。半径と「不透明なら適用しない」ゲートは libghostty(Zig) 側が config を読んで判定するため Swift で再実装しない。フルスクリーンだけは Swift 側で除外する——フルスクリーン中は config の不透明度が据え置きで Zig 側は早期 return せず、opaque 窓の背後に blur を敷いても不可視で無駄なため。呼び出しは gui.conf 更新後の 3 経路: reload 後・**ウィンドウが key になった時**（起動時 init は窓が可視前で windowNumber 未確定＝CGS が効かないため、初回適用をここで担保する）・フルスクリーン遷移。

## テーマ（外観スイッチ）

テーマ設定は **Auto / Dark / Light**（[settings-palette](settings-palette.md)）で、実体は `NSApp.appearance`（auto=OS 追従）。chrome は動的トークンが、ターミナルは surface が effectiveAppearance を libghostty へ通知し、libghostty が返す soft の reload アクションを surface config の再適用へ回して、appearance 変化に**アプリ全体が揃って**追従する（非 soft＝キーバインドの reload_config はディスク再読込へ分岐）。ghostty のテーマ解決は finalize 時に最終値のみをファイルへ解決するため、user config の `theme = <stock名>` が中間層にあっても warning は出ない。バンドルには OrbeDark / OrbeLight の 2 枚のみ同梱する（`build-app.sh` が stock テーマを撤去）。
