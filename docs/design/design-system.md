---
title: Orbe デザインシステム
description: 外観の思想・契約を記す自由記述ドキュメント。値の正は DesignSystem/ の Swift、思想・契約の正は本書
updated: 2026-10-17
---

# Orbe デザインシステム

> ステータス: v0.14.0 · 2026-10-16
> 値の正（SSOT）: chrome/semantic は `Sources/Orbe/DesignSystem/DesignTokens.swift`（機械可読ミラー `docs/design/tokens.json`）／ 識別色（端末 ANSI 16 色・chrome 共有アンカー）は `Sources/Orbe/DesignSystem/OrbePalette.swift`（端末 conf を生成し、chrome アンカーへ定数を供給）／ worktree 識別色 48 色（24 色相 × 2 トーン）を dark / light 別に持つ表は `Sources/Orbe/DesignSystem/WorktreePalette.swift`（`scripts/gen-worktree-palette.py` が oklch から生成・手で編集しない）。
> ガラス質感・elevation・glow は `Sources/Orbe/DesignSystem/DesignTokens+Glass.swift` が所有（本書は再定義しない）。
> エディター面のトークン（`face.*` / `editor.*` / `diff.*` / `syntax.*` / `type.editor*` / `layout.editor*` `layout.face*` / `radius.face*` / `opacity.editor*` `opacity.face*` / `stroke.editor*` / `facePositionSpring` `faceShapeSpring` `faceDot` `editorSlider*` `editorScrollbar*`）は `Sources/Orbe/DesignSystem/DesignTokens+Editor.swift` が所有。
> 本書は思想・契約を記す自由記述ドキュメントで、**思想・契約の正は本書、値の正は上記 Swift**。Orbe の外観の**正**はこのリポジトリの中で閉じている。ただしコード中の一部コメントは、値が決まった経緯の記録として設計見本（リポジトリ外）を引用する——それは出所の記録であって、正ではない。

Orbe は AI コーディングエージェントのためのネイティブ macOS ターミナル。外観は
**dark = 温かい炭＋フロストガラス**（既定）、**light = 藤紙×電紫**（藤紙＋ガラス）。chrome（StatusRow・タブ・パレット・検索・オンボーディング）をこの semantic トークンで統一し、ターミナルと外側を一体にする。

---

## 1. 原則

1. **温かく、落ち着いて、密に。** 地は温かい炭／藤紙。装飾は最小、情報は密。
2. **色は状態と自分の出番に。** 無彩に近い土台の上で、色は **エージェントの状態（確定配色の温度分け）** と **自分の出番（電紫 accent＝選択・プロンプト）** にだけ使う。これに **面のキー色（どの面に居るか）** が加わる——タブの中の端末面とエディター面を識別する 2 色（`face.terminal` は無彩の藤、`face.editor` は紙の白）で、引き手・分割中の焦点の印・位置ドットだけが使う。状態でも選択でもない「居場所」の色なので、状態色・accent とは混ぜない。
3. **状態は3チャンネルで冗長に。** 動き=working／吹き出し=waiting／チェック=done／zzz=idle。色・形・動きのどれを失っても判別できる（→ §3・§4）。
4. **選択は tint 塗り、タブだけ反転。** リスト行の選択は `selectionFill` の淡塗り。タブの選択のみ前景色を背景にした**反転表示**（背景を状態色で塗らない）。左 3px バー・下線・太字による選択弁別は使わない。
5. **ラベルはターミナル語。** UI 本文・プローズはシステムサンセリフ、ターミナル・ラベル・コード・ステータス語は monospace。
6. **ガラスは Glass に委任。** フロストガラスの面・ぼかし・影・温度 glow は `DesignTokens+Glass.swift`（別ファイル）が持つ。本書のトークンは非ガラスの色・字・余白・角丸・モーション。
7. **トークンだけを参照する。** コンポーネントは semantic 名（`Theme.Color.textSecondary` 等）だけを使い、生 hex・`NSColor.systemXxx`・直書き `ofSize:` を書かない。

---

## 2. トークン

### 2.1 色 — semantic 役割名で
各色は dark / light の2値を持ち、`NSAppearance` で自動的に出し分ける。alpha 付きは重ねる面（tint）。

| token | 役割 | dark | light |
|---|---|---|---|
| `bg.base` | 不透明ベース | `#1a1721` | `#fcfbfe` |
| `bg.sunken` | 行地・gutter・淡い面 | `rgba(255,255,255,.03)` | `rgba(58,49,81,.05)` |
| `bg.deepest` | 最深・トグル溝 | `rgba(255,255,255,.04)` | `rgba(58,49,81,.04)` |
| `surface.0` | 面 | `rgba(255,255,255,.03)` | `rgba(58,49,81,.05)` |
| `surface.1` | 罫線・secondary 枠 | `rgba(255,220,180,.08)` | `rgba(110,90,170,.12)` |
| `surface.2` | 面（強）・強枠 | `rgba(255,220,180,.10)` | `rgba(110,90,170,.15)` |
| `text.primary` | 本文・選択ラベル・タブ反転面の地 | `#e6e1f0` | `#3a3151` |
| `text.secondary` | 通常ラベル・非選択タブ文字 | `#b8afc4` | `#5f5678` |
| `text.tertiary` | 三次 | `#8b8397` | `#8d85a3` |
| `text.muted` | 非アクティブ・補助・ヒント | `#8b8397` | `#8d85a3` |
| `text.mutedInactive` | 窓が main でない間、`text.muted` だった chrome の文字をさらに一段沈める色（§5.1） | `#6f6880` | `#a49cb5` |
| `accent.primary` | 選択・自分の出番・プロンプト | `#9068f0` | `#6d43d8` |
| `accent.focus` | フォーカス | `#9068f0` | `#6d43d8` |
| `accent.bright` | accent の明色変種（tint(accent) 面上の強調文字・タブ行の挿入キャレット） | `#b18aff` | `#6d43d8` |
| `on.accent` | accent 塗り上のインク＝地色 | `#1a1721` | `#fcfbfe` |
| `success` | 成功（green・端末の緑と同値） | `#81b88b` | `#279a4d` |
| `danger` | エラー（red・端末の赤と同値） | `#d16969` | `#e02d33` |
| `conflict` | 競合＝注意色（黄・ANSI黄） | `#e2cd6d` | `#b17b00` |
| `state.working` | エージェント実行中 | `#85adff` | `#1f66c9` |
| `state.waiting` | 要応答 | `#eec25a` | `#b17b00` |
| `state.done` | 完了 | `#82d894` | `#279a4d` |
| `state.idle` | 休止 | `#8a82b8` | `#8b82a8` |
| `state.dormant` | 休眠 | `#8b8397` | `#8d85a3` |
| `state.workingInverse` | 反転面上の working | `#1f66c9` | `#85adff` |
| `state.waitingInverse` | 反転面上の waiting | `#b17b00` | `#eec25a` |
| `state.doneInverse` | 反転面上の done | `#279a4d` | `#82d894` |
| `statusText` | ステータスストリップの件数 | `#cad3f5` | `#4d4368` |
| `stripDivider` | ストリップの区切り線 | `rgba(255,255,255,.12)` | `rgba(58,49,81,.16)` |
| `checkStroke` | done グリフの check 線 | `#0a0a0a` | `#f3f0fa` |
| `accentCheckStroke` | accent 塗り面上の ✓（clean のチェックボックス） | `#ffffff` | `#f3f0fa` |
| `tab.rowBg` | タブ行全幅の地 | `rgba(0,0,0,.28)` | `rgba(58,49,81,.08)` |
| `tab.segBg` | 単独タブ（1 枚の連）の地 | `rgba(255,255,255,.10)` | `rgba(58,49,81,.06)` |
| `tab.groupBg` | グループ（2 枚以上の連）の地の下敷き（上に `worktree.tint` を重ねる） | `rgba(255,255,255,.04)` | `rgba(58,49,81,.02)` |
| `worktree.bar[0…47]` | 連の左端の worktree 識別色（番号は basename のハッシュでテーマ共通・色はテーマごと。dark は暗い chrome の上で光るトーン、light は白い紙面の上で沈むトーン） | `WorktreePalette.dark` | `WorktreePalette.light` |
| `worktree.tint[0…47]` | グループの地に重ねる識別色の淡塗り | `WorktreePalette.dark` の各色 .12 | `WorktreePalette.light` の各色 .14 |
| `worktree.frame[0…47]` | グループの器の外側 1px 枠 | `WorktreePalette.dark` の各色 .38 | `WorktreePalette.light` の各色 .45 |
| `tab.divider` | グループ内セルの区切り線（識別色を敷いた地の上でも読める濃さ） | `rgba(255,255,255,.14)` | `rgba(58,49,81,.16)` |
| `tab.activeText` | 選択セグメント（反転面）の文字 | `#1a1721` | `#f3f0fa` |
| `tab.activeBgInactive` | 窓が main でない間の選択セルの地（反転をやめた控えめな地。§5.1） | `rgba(255,255,255,.16)` | `rgba(58,49,81,.12)` |
| `face.editor` | エディター面のキー色（紙の白。引き手・焦点の印・位置ドット） | `#ece7f5` | `#352d4a` |
| `face.terminal` | 端末面のキー色（同上。dark / light とも `text.secondary` と偶然同値だが別トークン） | `#b8afc4` | `#5f5678` |
| `face.editorBright` / `face.terminalBright` | ホバー中の引き手のグリフ（キー色を明るくした色。light は紙面に向けて暗くする） | `#fffdff` / `#cfc7d9` | `#221c32` / `#4a435e` |
| `face.notchEditorHover` / `face.notchTerminalHover` | ホバー中の引き手の不透明な地（キー色 α .16 を `bg.base` の上で不透明にした色） | `#393642` / `#312d3a` | `#dcdae1` / `#e3e1e9` |
| `face.notchShadow` | ホバー中の引き手の影 | `rgba(0,0,0,.35)` | `rgba(90,70,150,.14)` |
| `editor.ghost` | エディター面の空状態の ◐（沈んだ塗り） | `#3d3752` | `#d9d3e6` |
| `editor.icon` | エディター面のアイコン・kbd の文字（dark / light とも `kbKeyText` と偶然同値だが別トークン） | `#a99fb8` | `#766e8d` |
| `editor.text` | エディター面の 2 段目の文字——コードの素文字・ファイル名・タブ題・パンくずの末尾（dark / light とも `statusText` と偶然同値だが別トークン） | `#cdc7e2` | `#4d4368` |
| `editor.tertiary` | エディター面の三次の文字——レールの非選択・パンくずの区切り（`text.tertiary` は `text.muted` の別名なので別値） | `#6d667a` | `#aca4bd` |
| `editor.caution` | 注意の黄——外部変更で衝突中のタブのドット・検索の一致の地・diff タブの種類の注記と選択の上縁（dark は `conflict` と偶然同値だが light が違い、git 競合でもない） | `#e2cd6d` | `#a07f0c` |
| `diff.added` | git の追加（青）——ガター・A / U のバッジと名前・印・diff の記号と行の地の基 | `#5ea8ff` | `#0969da` |
| `diff.removed` | git の削除（オレンジ）——ガターの三角・印・diff の記号と行の地の基 | `#f0883e` | `#bc4c00` |
| `diff.modified` | git の変更（黄）——ガター・M のバッジと名前・印 | `#e2cd6d` | `#a07f0c` |
| `editor.tabCloseHover` | ファイルタブの × にポインタがあるときの枠の地（VS Code `toolbar.hoverBackground` の役。§5 File tabs） | `rgba(255,255,255,.10)` | `rgba(58,49,81,.10)` |
| `editor.previewHatch` | 仮のタブの地の斜線の基色（view 側で `opacity.editorPreviewHatch*` を掛ける。§5 File tabs） | `#a99fb8` | `#3a3151` |
| `editor.hue.{orange,blue,yellow,sky,violet,cyan,red,green,teal}` | 種別チップの色相（文字と α .16 の地）。種別 → 色相の表は `FileChip` が持つ | `DesignTokens+Editor.swift` の `editorHue*`（`tokens.json` の `editor.hue.*`） | 同 |
| `surfaceInk` | カード・面の基色（view 側で α を掛ける。HelpCard・MenuBar、エディター面の hover 地 .045 / 選択地 .04・.045 / kbd 地 .05） | `#ffffff` | `#3a3151` |
| `sunkInk` | 沈み面の基色（dark は scrim と同じ暗幕の基色）。view 側で α を掛ける（レール .22・サイドバー .45・エディターのタブ行 .22。light は ×0.3） | `#0a080e` | `#3a3151` |
| `editor.lineNumber` | 行番号（`text.muted` の α .55） | `rgba(139,131,151,.55)` | `rgba(141,133,163,.55)` |
| `editor.whitespace` | 見せる空白の丸点（`text.muted` の α .55） | `rgba(139,131,151,.55)` | `rgba(141,133,163,.55)` |
| `editor.selection` | 本文の選択の地・ミニマップの選択 | `#264f78` | `#add6ff` |
| `editor.selectionInactive` | 焦点の無い面の選択の地 | `#3a3d41` | `#e5ebf1` |
| `editor.findMatch` | 検索の一致の地・ミニマップの一致 | `rgba(234,92,0,.33)` | `rgba(234,92,0,.33)` |
| `editor.findMatchCurrent` | 現在の一致の地（不透明・選択の地の上） | `#9e6a03` | `#a8ac94` |
| `editor.findLine` | 現在の一致の行全体の地 | `rgba(255,255,255,.043)` | `rgba(253,255,0,.2)` |
| `editor.selectionOccurrence` | 選択文字列の他の出現の地（面に焦点が無いとき α 半分）・ミニマップの語の出現 | `rgba(173,214,255,.15)` | `rgba(173,214,255,.5)` |
| `editor.wordOccurrence` | キャレットの語の出現の地 | `rgba(87,87,87,.72)` | `rgba(87,87,87,.25)` |
| `editor.minimapSlider` / `Hover` / `Active` | ミニマップの帯（普段・帯の上・ドラッグ中） | `rgba(121,121,121,.2)` / `rgba(100,100,100,.35)` / `rgba(191,191,191,.2)` | `rgba(100,100,100,.2)` / `rgba(100,100,100,.35)` / `rgba(0,0,0,.3)` |
| `editor.scrollbarSlider` / `Hover` / `Active` | スクロールバーのつまみ（普段・つまみの上・ドラッグ中） | `rgba(121,121,121,.4)` / `rgba(100,100,100,.7)` / `rgba(191,191,191,.4)` | `rgba(100,100,100,.4)` / `rgba(100,100,100,.7)` / `rgba(0,0,0,.6)` |
| `editor.rulerFind` | スクロールバーの印——検索の一致 | `rgba(209,134,22,.49)` | 同 |
| `editor.rulerOccurrence` | スクロールバーの印——語の出現 | `rgba(160,160,160,.8)` | 同 |
| `editor.scrollShadow` | 先頭の行が上へ隠れている間の本文の上端の影 | `#000000` | `#dddddd` |
| `editor.minimapShadow` | 本文が右に続くときのミニマップ左端の影 | `rgba(0,0,0,.08)` | 同 |
| `syntax.keyword` | 構文: キーワード | `#569cd6` | `#2f63c9` |
| `syntax.keywordControl` | 構文: 制御の流れ（return / if / for / import …） | `#c586c0` | `#a03a98` |
| `syntax.type` | 構文: 型 | `#4ec9b0` | `#178a72` |
| `syntax.function` | 構文: 関数 | `#dcdcaa` | `#8a7a12` |
| `syntax.string` | 構文: 文字列 | `#ce9178` | `#b0562a` |
| `syntax.comment` | 構文: コメント | `#7a7387` | `#8d87a0` |
| `syntax.variable` | 構文: 変数・引数・プロパティ | `#9cdcfe` | `#2a7bbd` |
| `syntax.punctuation` | 構文: 記号・演算子・区切り | `#d4d4d4` | `#4a4658` |

**意図的な同値収束（事故ではない）**: Orbe の配色は色階層が少なく、複数の semantic 名が同一値へ収束する。SSOT では別名で表現している。
`accent.focus` ＝ `accent.primary`／ `text.tertiary` ＝ `text.muted`／
`state.dormant` ＝ `text.muted`／ `surface.0` ＝ `bg.sunken`。
**値だけが一致する独立トークン**: `face.terminal` ＝ `text.secondary`／ `text.mutedInactive` ＝ `kbKeyMutedText`／ `editor.icon` ＝ `kbKeyText`／ `editor.text` ＝ `statusText`／ `editor.caution` ＝ `diff.modified` ＝ `editor.hue.yellow`／ `editor.whitespace` ＝ `editor.lineNumber`／ `editor.hue.sky` ＝ `syntax.variable`（上の収束と違い SSOT でも互いを参照せず、片方の値が動いてももう片方は追随しない）。`syntax.*` の dark は VSCode Dark Modern の実在トークン色で、5 色が端末の ANSI（§8）と偶然同値だが、端末色は別レイヤーなので参照しない。選択・俯瞰・強調の `editor.*`（selection〜minimapShadow）は VS Code Dark Modern / Light Modern の値（上書きの無いものは VS Code の既定）で、エディターの使い勝手を VS Code に揃えるために借りる。同じ意味の Orbe トークンがあるもの（git の印・キャレット・縁）はそれを使い、git の印とキャレットには VS Code の α を掛ける。
`state.done`（完了・緑）と `success`（green）、`state.waiting`（要応答・黄）と `conflict`（ANSI黄）は**別トークンとして分離**（light では偶々同値だが dark では異なる。SSOT は状態色を `StateHue`、ANSI 系を端末アンカーから別々に導く）。
**反転色（`state.*Inverse`）は対テーマの状態色**＝dark/light の値を入れ替えただけ（選択タブの反転面上でコントラストを確保する仕組み）。
**light の `tab.activeText` `#f3f0fa` は `bg.base` `#fcfbfe` と別値**（on.accent の流用不可）。

### 2.2 状態の塗り・tint（事前 alpha 済み・per-theme）
選択・hover は `accent.primary` の淡塗り（テーマごとの accent 基調に α を掛けた事前合成値）。状態別 tint は件数ピル・バッジの淡塗り（各テーマの状態色の 12–14%）。

| token | dark | light | 用途 |
|---|---|---|---|
| `selectionFill` | `rgba(144,104,240,.14)` | `rgba(109,67,216,.14)` | 選択行・選択候補（タブは反転であり使わない） |
| `hoverFill` | `rgba(144,104,240,.10)` | `rgba(109,67,216,.10)` | hover |
| `tint.working` | `rgba(133,173,255,.12)` | `rgba(31,102,201,.12)` | working 件数ピル |
| `tint.waiting` | `rgba(238,194,90,.12)` | `rgba(177,123,0,.12)` | waiting |
| `tint.done` | `rgba(130,216,148,.12)` | `rgba(39,154,77,.12)` | done |
| `tint.success` | `rgba(129,184,139,.12)` | `rgba(39,154,77,.12)` | 成功の緑チップ地（clean の merged PR 等。文字が `success` なので地も同軸） |
| `tint.red` | `rgba(209,105,105,.14)` | `rgba(224,45,51,.14)` | エラー |
| `smallPillFill` | `rgba(255,255,255,.04)` | `rgba(58,49,81,.06)` | ⌘⇧S 等のキーバッジ地 |
| `plainPillFill` | `rgba(255,255,255,.06)` | `rgba(58,49,81,.08)` | 事実だけを述べる無色チップ地（clean の `[gone]` / `prunable`） |
| `scrim` | `rgba(10,8,14,.35)` | `rgba(58,49,81,.18)` | Workspace 等の通常暗幕 |
| `scrimStrong` | `rgba(10,8,14,.40)` | `rgba(58,49,81,.22)` | 設定等の強い暗幕 |

### 2.3 タイポ — サイズ＋色で階層、書体で役割
**UI 本文・プローズ＝システムサンセリフ / ターミナル・ラベル・コード・ステータス語＝monospace。** webfont なし（システムフォントのみ）。
階層はサイズと色で。weight は見出し・選択の弁別に効く箇所だけ維持する。

| token | size / weight / family | 用途 |
|---|---|---|
| `type.display` | 26 / regular / sans | ページタイトル |
| `type.title` | 14 / regular / mono | パレットのクエリ・見出し |
| `type.body` | 12.5 / regular / sans | 本文・プローズ・設定行 |
| `type.code` | 12.5 / regular / mono | コード・入力・ターミナル |
| `type.chrome` | 11 / regular / mono | TopBar・タブ・ストリップ |
| `type.workspaceName` | 12 / regular / mono | Workspace 名・パレット行の主名 |
| `type.codeSmall` | 11 / regular / mono | 版番号・補足の mono11 |
| `type.codeCompact` | 11.5 / regular / mono | 補完候補行 |
| `type.bodySmall` | 10.5 / regular / sans | 小さな補助本文 |
| `type.label` | 12.5 / medium / mono | パレット行・主ラベル |
| `type.labelStrong` | 12.5 / semibold / mono | 選択ラベル |
| `type.caption` | 11 / medium / mono | 件数・小バッジ・小ボタン |
| `type.captionDigit` | 11 / medium / mono-digit | 件数（`monospacedDigit`） |
| `type.meta` | 10 / regular / mono | 行番号・メタ・ヒント・path |
| `type.sectionLabel` | 9.5 / regular / mono | 大文字セクション見出し（uppercase は使用側 `textCase`） |
| `type.editorLead` | 13 / regular / sans | エディター面・ボードの空状態の一文 |
| `type.editorHint` | 12 / regular / mono | エディター面のショートカット行・kbd |
| `type.editorCode` | 12 / regular / mono | コード本体 |
| `type.editorLineNumber` | 11 / regular / mono | 行番号 |
| `type.editorPanelTitle` | 11 / regular / sans | サイドバーのパネルヘッダーの題（tracking 0.5） |
| `type.editorRootLabel` | 11 / bold / sans | エクスプローラーのルート行（tracking 0.8） |
| `type.editorTreeRow` | 12.5 / regular / sans | ツリー行の名前 |
| `type.editorBadge` | 11 / regular / mono | ツリー行の git バッジ |
| `type.editorFileTab` | 12 / regular / sans | ファイルタブの題 |
| `type.editorBreadcrumb` | 11 / regular / sans | パンくず |
| `type.editorSearchField` | 12 / regular / mono | 検索パネルの入力欄 |
| `type.editorSearchOption` | 10 / regular / sans | 入力欄の右の Aa / ab / .* |
| `type.editorSearchFile` | 12 / regular / sans | 検索結果のまとまりの見出しのファイル名 |
| `type.editorSearchDirectory` | 10.5 / regular / sans | 見出しのディレクトリ |
| `type.editorSearchCount` | 9.5 / regular / sans | 見出しの件数バッジ |
| `type.editorSearchMatch` | 11 / regular / mono | 一致の行 |
| `type.editorSearchNote` | 11 / regular / sans | 件数・打ち切り・0 件・エラーの文 |
| `type.editorRailBadge` | 9 / bold / sans | レールの件数バッジ |
| `type.editorScmSection` | 11 / bold / sans | ソース管理の区分見出し |
| `type.editorScmCount` | 9.5 / regular / sans | 区分見出しの件数バッジ |
| `type.editorScmFile` / `editorScmDirectory` | 13・11 / regular / sans | ソース管理のファイル行の名前・ディレクトリ |
| `type.editorScmMessage` | 12 / regular / sans | コミットメッセージ欄 |
| `type.editorScmButton` | 12 / semibold / sans | コミットボタン |
| `type.editorScmCommit` | 12 / regular / sans | グラフのコミットの題 |
| `type.editorScmRef` / `editorScmBranch` | 9・11 / regular / mono | グラフの ref の札・ブランチの器 |
| `type.editorScmMore` | 11.5 / regular / sans | グラフの「さらに表示」 |
| `type.editorScmNote` | 11 / regular / sans | 失敗の文・git 管理外の一文 |
| `type.editorScmBandName` / `editorScmBandProgress` / `editorScmStop` | 12 sans・10.5 mono・11 sans | 実行中の帯の操作名・進捗の行・止める |
| `type.editorChip` | 16 で 10 / 9 / 8 / bold / mono | 種別チップのグリフ（字数で決め、14 / 12 へは比例して丸める） |

**tracking / line-height スカラ**（NSFont では表せず、使用側で `.tracking()` / lineSpacing 換算）:
`tracking.label` 1（大文字セクション見出し）／ `tracking.status` 0.3（ステータスストリップ）／ `tracking.key` 1（⌘H バッジ・キーバッジ・チップのキー表記）／ `tracking.panelTitle` 0.5（サイドバーのパネルヘッダーの題）／ `tracking.rootLabel` 0.8（エクスプローラーのルート行）／ `line.body` 1.6（本文）／ `line.terminal` 1.55（ターミナル本文）／ `line.editorCode` 18pt（コード本体。倍率ではなく固定値）。倍率の行高は CSS の line-height と同じく、1 行目の上と最終行の下にも差の半分ずつを置く。

### 2.4 余白・角丸・線
- **spacing（2/4pt グリッド・穴なし）**: `hair 2 / tick 4 / note 6 / step 8 / beat 12 / bar 16 / span 20 / phrase 24`
- **radius**: `xs 3`（単独タブの器・＋ボタン）/ `sm 4`（バッジ・キーヒント・タブグループの器）/ `row 8`（リスト行・小コントロール）/ `md 10`（入力・小パネル）/ `card 12`（カード・設定行）/ `lg 16`（パネル・オーバーレイ）/ `pill 999`（カウントピル・トグル）。エディター面: `editorTabClose 6`（ファイルタブの × の枠）
- **stroke**: `hairline 1`（罫線・枠）/ `focusRing 2`（フォーカスリング）
- **layout（エディター面の骨）**: `editorRail 36` / `editorRailGlyph 20`（レールのアイコン）/ `editorSidebar 240`（既定。ドラッグで可変）/ `editorSidebarMinWidth 160` / `editorBodyMinWidth 160`（サイドバーの幅の上限と、狭い列で表示幅を切り詰める規則）/ `editorSidebarHandle 4`（境の当たり）/ `editorFileTabs 28` / `editorTabClose 20`（ファイルタブの × の枠。押せる範囲）/ `editorTabCloseGlyph 12`（その中の ×）/ `editorFileTabTrailing 6`（タブの右の余白）/ `editorBreadcrumb 20`（レール・サイドバーの右、エディターのタブ行の下の hairline 1 はこれらの外側に足す） / `editorPanelHeader 28` / `editorRow 20` / `editorChip 14` / `editorChipSmall 12`（パンくずの末尾）/ `editorChevron 16` / `editorLineNumberGutter 50`（行番号の列。桁が増えれば広がる最小幅）/ `editorMarkGutter 19`（git の印の列）/ `editorScrollbar 14`（本体の右端の縦スクロールバー）/ `editorHorizontalScrollbar 12`（本文の区画の下端の横スクロールバー）/ `editorSidebarScrollbar 10`（サイドバーの一覧——エクスプローラーのツリー・検索結果——の縦のつまみ）/ `editorMinimapMaxWidth 120`（その左のミニマップの幅の上限。幅は本文の幅から計算する）。検索パネル: `editorSearchField 28`（入力欄）/ `editorSearchOption 20`（オプションの角）/ `editorSearchRow 20`（結果の行。まとまりの見出しも一致も同じ）/ `editorSearchMatchIndent 40`（一致の行の左）/ `editorSearchCountWidth 18`・`editorSearchCountHeight 16`（件数バッジ）/ `editorSearchChevron 10`（見出しのシェブロン）/ `editorProgressLine 2`（検索中・ソース管理の実行中の線）。レールの件数バッジ: `editorRailBadge 15`（最小の幅と高さ）/ `editorRailBadgeOffset 8×4`（アイコンの右下からのはみ出し）。ソース管理パネル: `editorScmRow 22`（区分見出し・ファイル行・コミット・さらに表示）/ `editorScmChip 16` / `editorScmRowButton 18`（行のボタン）/ `editorScmGlyph 13`（ボタンの印）/ `editorScmTool 20`（見出しのツール）/ `editorScmGraphGap 8`（グラフ見出しの上の空き）/ `editorScmBranch 24`・`editorScmBranchGap 6`（ブランチの器とその下の空き）/ `editorScmMessage 26`（メッセージ欄の 1 行の高さ）/ `editorScmCommitButton 26`・`editorScmCommitCaret 24`（コミットボタンと ▾）/ `editorScmRef 15`（ref の札）/ `editorScmDot 7`・`editorScmDotColumn 16`（コミットの点とその列）/ `editorScmBand 28`・`editorScmStop 20`（実行中の帯と止める）。面の取っ手: `faceHandle 12`（引き手と継ぎ目の幅）/ `faceNotchHeight 48`（縁にいる引き手の高さ）/ `radius.faceNotch 6`（引き手の縁と反対側の角）/ `faceNotchGlyph 9` / `faceSeamBar 2×22`（継ぎ目の縦棒。`radius.faceSeamBar 1`）/ 影のずれ `faceNotchShadowOffset 2`・半径 `faceNotchShadowRadius 5`。見本の半透明面の light 換算は `opacity.editorSunkLight 0.3` / `editorFillLight 0.6` / `editorHairlineLight 1.4`。仮のタブの斜線は `layout.editorPreviewHatchPeriod 6`（線に直交する向きの周期）/ `stroke.editorPreviewHatch 1`（線の太さ）/ `opacity.editorPreviewHatchActive .06`・`editorPreviewHatchInactive .039`（見ているとき／見ていないとき。後者は前者の 0.65 倍）。
- elevation（面の影）は `DesignTokens+Glass.swift` が所有。本書・`tokens.json` は再定義しない。

### 2.5 モーション（拍）
遷移は **3 段＋instant** に固定。標準イージング `cubic-bezier(0.2, 0, 0, 1)`（ease-out 寄り）。
ループ3種は状態表現の定常アニメ。

| token | 値 | 曲線 / 用途 |
|---|---|---|
| `instant` | 0 | 矢印ナビ・パレット表示（一瞬） |
| `quick` | 120ms | hover・下線・フォーカスリング |
| `base` | 180ms | パネルのスライド |
| `slow` | 240ms | バッジフェード |
| `spin` | 1.6s | working スピナー（linear infinite・rotate360） |
| `float` | 2.6s | waiting 浮遊（ease-in-out infinite・translateY `floatOffset` -1） |
| `blink` | 1.1s | 点滅（0–55% 表示 / 56–100% 非表示） |
| `facePositionSpring` | 硬さ 320・減衰比 1.0 | 境の位置を行き先へ運ぶばね（⌘E・取っ手を押す・閉じる着地）。時間は固定せず、収束で止まる |
| `faceShapeSpring` | 硬さ 420・減衰比 .85 | 取っ手の形（引き手 ⇄ 継ぎ目）が位置の決める目標を追うばね |
| `faceDot` | 240ms | 位置ドットの幅・色 |
| `editorSliderFadeIn` | 100ms | ミニマップの帯が現れる・消える、スクロールバーのつまみが現れる（linear） |
| `editorScrollbarFadeOut` | 800ms | つまみが消える（linear）。スクロールが止まって `editorScrollbarHideDelay` 500ms 後に始まる |

> リズム規律: 同種の遷移に別々の時間を使わない。面の動きはばねで、時間を固定しない（投げた勢いを引き継ぎ、途中で掴めるようにするため）。`reduce motion` 環境では遷移は `instant`・ループは停止（スピナーは静的な 3/4 円弧のまま残り、形で working と判別できる）。

---

## 3. アクセシビリティ契約（全コンポーネント共通・最優先）

**色だけに意味を持たせない。** 意味は必ず 形・記号・位置・文字 のいずれかでも伝え、色は補強に回す。

- **成功＝green（`success`）＋ `✓`／エラー＝red（`danger`）＋ `⚠`。**
- **git の色は赤と緑に頼らない**: 追加＝青（`diff.added`）・削除＝オレンジ（`diff.removed`）・変更＝黄（`diff.modified`）。赤と緑を見分けにくい人でも区別できるため。ガター・diff・バッジは形（記号 ＋ / −・削除の三角・バッジの字）でも区別する。例外として、俯瞰（ミニマップ・スクロールバー）の git の印は 3 種とも同じ形で、色だけで分ける——俯瞰は変化のある位置を示す補助で、種類は本文の横のガター（削除は三角）で読めるから。
  - 見本の色名からの訳し方: 見本の `diffAdd` / `diffDel` は、git の変化の種類（ガター・バッジ・diff の行・印・件数）なら `diff.*`、成否・CI・PR の状態・診断なら `success` / `danger`。見本の `modified` は、git の M とガターの変更なら `diff.modified`、それ以外は `editor.caution`。見本の `diffText`（diff の行の字の色）は訳さない——Orbe は diff の字に専用の色を持たず、どの行も普通のファイルと同じ構文色で描き、追加・削除は行の地と先頭の ＋ / − で見分ける（VS Code と同じ）。
- **エージェント状態はグリフ形＋動きが一次情報。** 4状態すべてが固有の形（円弧・吹き出し・チェック・zzz）を持ち、色情報を除いても判別できる。横断ロールアップは常に件数（数字）を併記。
- **コントラスト**: テキスト階層は背景に対し WCAG AA（本文 4.5:1 / 大字 3:1）。`text.muted` は補助情報専用、本文に使わない。
- **例外**: 窓が main でない間の退いた姿の chrome の文字（§5.1）は AA を下回ってよい——裏にあるときは読みやすさより退くことを優先する。前面に戻れば即座に前面の姿に戻る。

---

## 4. エージェント状態の言語

確定配色の温度分け——自分の出番=電紫 accent、waiting=黄、done=green、idle/dormant=無彩グレー。working=青（accent と別色相に分離）。
グリフは自作アイコン（形状の正は `Sources/Orbe/DesignSystem/StatusGlyph.swift`）。ここでは色・形・意味を規定する。

| 状態 | 色 | 形 | 意味 / 出方 |
|---|---|---|---|
| working | `state.working`（青） | 3/4 円弧・`spin` スピナー | 実行中。タブにグリフ、ストリップに件数 |
| waiting | `state.waiting`（黄） | 吹き出し・`float` 浮遊 | ユーザー入力待ち。最優先で気づかせる |
| done | `state.done`（green） | チェック入り角丸四角（rect 8×8 rx1.5 塗り＋check 線 `checkStroke`・width 1.3・round・opacity .7）・静止 | 完了。見ているタブでは idle へ消費 |
| idle | `state.idle`（グレー） | zzz（大/中/小 3 本の折れ線 z・stroke 1.1/0.9/0.75・round）・静止 | 休止。タブでは非表示・ストリップと一覧にのみ計上 |
| dormant | `state.dormant`（muted） | zzz（idle と同形） | 休眠 agent。減光（`Opacity.dormant`） |

**ステータスストリップ（TopBar 右端の横断ロールアップ）**: mono 11・tracking 0.3。
項目＝グリフ(10px 状態色)＋gap 5＋件数（`statusText`・opacity .95）。**ラベル文字は持たない（グリフ＋数字のみ）**。
項目間 gap 10、項目の間に区切り線（幅1×高10 の `stripDivider`）。件数 0 の状態は非表示。

---

## 5. コンポーネント契約（色と意味のレベル）

本書は color と意味の契約＋主要寸法に留める（実装の画素は各コンポーネントが持つ）。

- **選択の示し方**: リスト行の選択は **tint 背景**（`selectionFill`）。タブの選択のみ**前景色反転**（§5.1）。**選択を左バーで示すのはエディター面のレールだけ（次項）。chrome ではどこでもしない**（Completion も例外にしない）。下線・太字による選択弁別も持たない（タブ行の左 3px バーは選択ではなく worktree の識別色で、意味が別）。
- **エディター面の例外**（見本 `Rail.tsx`・`CodeView.tsx` の値をそのまま持つ）: レールの選択項目は左 2px の `accent.primary` の縦線 ＋ 地 `surfaceInk` .04（light ×0.6）、ファイルタブの選択は上縁 1.5px の `accent.primary` ＋ 地 `surfaceInk` .045、diff タブの選択は上縁 1.5px の `editor.caution`（見本 modified。git の変化の種類ではないので §3 の訳し方で `editor.caution`）＋ 地 `surfaceInk` .045。どれも chrome の反転や tint とは別の、面の中に閉じた見せ方で、この 3 か所以外へ広げない。エクスプローラーのツリー行の選択は通常どおり `selectionFill`。
- **Tab（セグメント）**: タブ行（高さ 28・padding 上下 3・左右 5（＝gap）・gap 5・地 `tab.rowBg`）の中の器。**面を持つのはグループ（同じ worktree のタブ 2 枚以上の連）だけ**——地 `tab.groupBg` に `worktree.tint` を重ね・radius 4・クリップ、器の**外側**に 1px の `worktree.frame` の枠（幅の取り分に含まれず gap に重なる）、左端に識別色バー 3px（縦いっぱい）、各セルの左に hairline `tab.divider` の区切り線（先頭セルを含む・選択セルでも残る）。1 枚の連は単独タブの器で、地 `tab.segBg`・radius 3 だけを持ち、枠・バー・区切り線を持たない。
- **Tab のセル**: padding 横8・グリフとタイトルの間 6・幅は床40〜上限140（超える名前は末尾省略）。非選択＝地なし（器の地が透ける）・文字 `text.secondary`（idle/dormant/なしも同じ）・状態グリフ 12px（working は stroke 1.6。idle は非表示）。**選択＝地 `text.primary`（前景色反転。区切り線を持つセルでは左 1px を空けて線を残す）・文字 `tab.activeText`・グリフ＝`state.*Inverse`（対テーマ状態色）**、done の check 線のみ `text.primary`。タブ背景を状態色で塗らない。窓が main でない間は反転しない（§5.1）。
- **Palette row**: default＝`text.secondary`（workspace 行の名前＝最優先状態の色）。hover＝`hoverFill`＋`text.primary`。selected＝`selectionFill` 地。dormant＝`Opacity.dormant`。タスク画面の表だけは、選んでいる行も減光する（減光は行の中身だけに掛け、選択の地は満の濃さのまま）——space で完了にした結果を、選んだまま確かめるため。情報行＝`text.muted`・選択不可。そのうち直前の操作が失敗した理由を述べる行だけ `danger`（§3）——中立な補足と同じ弱さで出さない。行= padding 5×10・radius 8。workspace 行の右詰め＝状態別カウントピル（padding 1×7・radius pill・地 tint .12・文字 状態色・グリフ 9px）。
- **Button**: primary（主 CTA）＝塗り `accent.primary`・文字 `on.accent`・radius `md`。secondary＝塗りなし・文字 `accent.primary`・枠 1px `surface.1`・hover で `hoverFill`。disabled＝`Opacity.disabled`。
- **Search field**: 外枠＝`bg.sunken`＋1px `surface.1`＋radius `md`。focus＝リング `accent.focus`。no-match＝`danger`。件数＝`captionDigit`。
- **Focus / active tab**: アクティブタブの端末は 2px 内側リング `accent.focus`。カーソル点滅と併走。
- **Onboarding**: waiting＝`text.muted`。installing＝スピナー（`accent.primary`）。done＝`✓` `success`。failed＝`✗` `danger`＋再試行 secondary。skipped＝`text.muted`・取り消し線。
- **Code view**（エディター面の文書）: 見本 `CodeView.tsx` の値をそのまま持つ。ただし俯瞰（ミニマップ・スクロールバー・上端の影）と強調の地は見本から外れ、寸法は VS Code の既定、色は VS Code Dark Modern / Light Modern の値（§2.1）。本文 `type.editorCode`・行高 `line.editorCode` 18・上余白 4・素の文字 `editor.text`・役割ごとに `syntax.*`。行番号ガター幅 50・右寄せ・右余白 8・`type.editorLineNumber`・`editor.lineNumber`、その右に git ガター 19、本文は 2 つの右端（最小 69。行番号の桁が増えれば広がる）から始まる。キャレット `accent.bright` 1.5×14。テキスト選択の地は `editor.selection`（焦点が無ければ `editor.selectionInactive`）。地は面の veil（`bg.base` × 実効不透明度）。
  - **git ガター**: 追加の行に `diff.added`、変更の行に `diff.modified` の 3px バー（列の左から 2・radius 1・α .85。続く行のバーは 1 本に繋がる）。削除はその境に `diff.removed`（α .85）の右向き三角 6×6 を中央合わせ（先頭行の上は上端から）。**追加と変更は色だけの区別**（形が同じ）——§3 の例外で、本文そのものが一次情報でガターは補助だから。削除は形も違う。
  - **空白の丸点**: 直径 2・`editor.whitespace`。行頭・行末・2 個以上の連続スペースだけ。選択の地・強調の地の上、字の下に描く（URL 下線も同じ層）。
  - **URL 下線**: ⌘ を押して URL の上にポインタがある間だけ、その URL に 1px・文字と同色・ベースラインの 3 下。指カーソルも同じ間だけ。⌘クリックで既定ブラウザ。
  - **ミニマップ**（スクロールバーの左。幅は VS Code の式で本文の幅から計算し、最大 `layout.editorMinimapMaxWidth` 120）: 1 行 2pt・1 字 1pt・行の間に隙間なし。字は本文フォントを太字の trait にした字形（システムの等幅では Semibold）を 1×2（1x）/ 2×4（2x）デバイス px に縮めたものを構文の色（役割の無い字は `editor.text`）で描き、明るさの係数 dark 12/15・light 50/60。字は左 8 デバイス px から。字と装飾（git の印・一致・語の出現・選択）の全体に不透明度 .9。git の印は x 2 デバイス px・幅 2 デバイス px に `diff.added` / `diff.modified` / `diff.removed`（3 種とも同じ形で色だけの区別。§3 の例外）。検索の一致は `editor.findMatch`、語の出現は `editor.selectionOccurrence`（範囲とその行の α 半分の地）、選択は `editor.selection`。帯は `editor.minimapSlider`（帯の上 `Hover`・ドラッグ中 `Active`）でミニマップの全幅、普段は隠れホバーで現れる。本文が右に続くときは左端の外にぼかし 6 の影（`editor.minimapShadow`）。
  - **横スクロールバー**（本文の区画の下端に重なる、高さ `layout.editorHorizontalScrollbar` 12、行番号の列の右からミニマップの左まで）: 横に続く本文があるときだけ出る。つまみは縦と同じ `editor.scrollbarSlider`（上 `Hover`・ドラッグ中 `Active`）で最小の長さ 20、現れ方と消え方も縦と同じ。印は持たない。
  - **スクロールバー**（本体の右端、幅 `layout.editorScrollbar` 14）: つまみ `editor.scrollbarSlider`（つまみの上 `Hover`・ドラッグ中 `Active`）、最小の長さ 20。下に印——左 1 デバイス px と上 1 デバイス px の縁（`borderInk` .07・light ×1.4）、残りを 3 レーン: 左に git（`diff.*` α .6）、中央に検索の一致 `editor.rulerFind` と語の出現 `editor.rulerOccurrence`、全幅にキャレット（`accent.bright` α .7・高 2）。印の最小の高さ 6。つまみは印の上に重なる。git の 3 種は同じレーン・同じ形で色だけの区別（§3 の例外）。
  - **上端の影**: 先頭の行が上へ隠れている間、本文の上端（本文の幅。ミニマップには掛けない）に `editor.scrollShadow` の内側の影（CSS の `0 6px 6px -6px inset`）。
  - **強調の地**: 行の高さいっぱい・角なし、選択の地の上・文字の下。下から 現在の一致の行全体 `editor.findLine` → 選択文字列の出現 `editor.selectionOccurrence` → 語の出現 `editor.wordOccurrence` → 検索の一致 `editor.findMatch` → 現在の一致 `editor.findMatchCurrent`（不透明）。一致が 1000 件を超えると検索の一致は現在の一致の行の直上へ回る。バーは Search field（§5）そのもので、本文の右上（上・右 12、ミニマップの左）。
- **引き手と継ぎ目**（面の器の取っ手。1 つの物）: 境の位置 hx（0 = 端末だけ…MAX = 器の幅 − 12 = エディターだけ）と、左右の縁から離れた度合い sL・sR（目標は `clamp(hx / 56)`・`clamp((MAX − hx) / 56)`、形のばねで追う）だけで見た目が決まる。形の進み t = min(sL, sR)（0〜1 に収める）が 0 なら縁の**引き手**、1 なら全高の**継ぎ目**。引き手は 12×48 で、縁側の 2 角は直角・反対側は半径 `6·(1 − t)`、グリフ 9px（エディターはファイル形・端末は窓と ❯_〔線端と角は丸〕、見本のグリフ viewBox 18・stroke 1.8 を写す）。t につれて、高さは 48 から全高へ t に比例して（弾ませない）、塗りはキー色 α .16 から継ぎ目の地へ RGBA の線形補間で移り、枠（1px、キー色 α .4、縁側の辺には引かない）は `1 − t` で薄れ、グリフは t = 0.5 までに消え、縦棒（2×22・角 1・`face.terminal` α .55）は t = 0.5 から現れる。不透明度は普段 .45・ホバーで 1 で、t につれて 1 へ。ホバーの進み h（`quick` の速さ、0→1）で、縁にいるときだけ地が不透明な `face.notch*Hover`・枠が α .65・グリフが `face.*Bright` へ補間され、縁から離れる向きにずれ 2・ぼかし 10 の影（`face.notchShadow`、強さ h）が付く。ホバーの的はポインタが乗っているか、掴んでいる間。**継ぎ目の地**は veil（`bg.base` × 透過の実効不透明度）に `face.terminal` α .07 を重ねた色で、透過設定に追従する。エディターの右端は `hx + 12·(1 − sR)`、端末の左端は `hx + 12·sL` で、両面の間（縁の近くでは 0〜12）はこの地で埋め、取っ手の上下から窓の奥が透けない。重なるのは縁の近くの取っ手だけで、縦中央 48 の範囲で、端末の左余白と 1 桁目の左端（左余白 8 に対し取っ手は継ぎ目と揃えた幅 12 なので 4 はみ出す）か、エディターのスクロールバーを覆い、そこではクリックとポインタの形は取っ手が持つ。カーソルは縁にいるとき指、それ以外と引いている間は左右矢印。見本の値は dark の引き手と継ぎ目と紙の白（`#ece7f5`）で、light と dark の端末の引き手は規則で導いた値（紙の白の light は、dark の紙の白と `text.primary` の差〔OKLCH の明度・彩度の比〕を light の `text.primary` から濃い側へ当てた値。ホバーの地は「キー色 α .16 を `bg.base` の上で不透明に」、ホバーのグリフはキー色との差〔OKLCH の明度 ±0.074・彩度 ×0.81〕を dark は明るい側・light は紙面に向けて暗い側へ、影は elevation の藤の影色を dark の約 0.4 倍の濃さで）。
- **Rail**（エディター面の左端 36）: 地 `sunkInk` .22・右 1px `borderInk` .07（light ×1.4）。項目は「ファイル」「検索」「ソース管理」の 3 つで 36 角・グリフ 20px stroke 1.5（検索は 1.6。見本 SearchIcon）。選択は上の例外（サイドバーを閉じている間は無い）、非選択の文字は `editor.tertiary`。「ソース管理」は変更があればグリフの右下（右 8・下 4 はみ出す）に件数バッジ: 最小 15×15 capsule・地 `accent.primary`・`type.editorRailBadge` `tab.activeText`・padding 0 3、1000 以上は「999+」。幅は字に沿い、右端を据えたまま左へ伸びる（「999+」でも字は地に収まり、右端はレールの縁で止まる）。git の変化の種類の色ではなく件数の印なので accent。
- **Explorer**（サイドバー。既定 240・ドラッグで可変）: 地 `sunkInk` .45・右 1px `borderInk` .07。ぼかしは持たない（面内の in-flow 面は窓のブラーに委ねる。§1-6）。パネルヘッダー 28（題 `type.editorPanelTitle`・`text.muted`、右端に 22 角のアイコンボタン: radius 4・hover 地 `surfaceInk` .08 ＋ 文字 `editor.text`、既定の文字 `text.muted`）。ルート行 20（`type.editorRootLabel`・`editor.text`・根の basename を大文字）。ツリー行 20・`type.editorTreeRow`・深さぶんのガイド（幅 8 ＋ 右 1px `borderInk` .08）・ディレクトリはシェブロン 16（`editor.icon`）、ファイルは種別チップ 14。名前の色は git バッジに従う（M `diff.modified` / A・U `diff.added` / C `conflict`、無印は `editor.text`）。バッジは右端 `type.editorBadge`。hover 地 `surfaceInk` .045、選択 `selectionFill`。ディレクトリ行はバッジを持たない。ツリーが溢れたときのつまみ: 右端・幅 `layout.editorSidebarScrollbar` 10・角なしの矩形・`editor.scrollbarSlider`（つまみの上 `Hover`・ドラッグ中 `Active`）・最小の長さ 20・トラックの地と枠なし。一覧の上にポインタがある間・スクロール中・ドラッグ中だけ見え、出方は本体のスクロールバーと同じ（`editorSliderFadeIn` / `editorScrollbarHideDelay` / `editorScrollbarFadeOut`）。ツリーの末尾（最後の行の下）に行 1 つ分（`layout.editorRow` 20）の空き。
- **Search panel**（サイドバーのもう 1 つのパネル。器とパネルヘッダーは Explorer と同じ部品）: ヘッダーの右端に 更新（2 秒を超えた検索では停止）・クリア・すべて折りたたむ／すべて展開。検索中はヘッダーの下端に `accent.primary` の細い帯が左から右へ流れる。入力欄 28（外側 padding 0 12 10、内側 padding 0 8・`type.editorSearchField`・地 `sunkInk` .35・枠 1px `borderInk` .10 radius 3、焦点で枠 `accent.primary` .55 radius 5、プレースホルダ `editor.tertiary`）。右端のオプション 20 角 radius 3・`type.editorSearchOption`・`text.muted`（ab は下線）、hover 地 `surfaceInk` .08、有効は地 `accent.primary` .25・枠 `accent.primary` .55・文字 `accent.bright`。エラーの文は入力欄の下に `danger`。まとまりの見出し 20（padding 0 12・gap 6: シェブロン 10 `text.muted`〔畳むと右向き〕・種別チップ 14・名前 `type.editorSearchFile` `text.primary`・ディレクトリ `type.editorSearchDirectory` `editor.tertiary`〔長ければ頭を省略〕・右端の件数バッジ 最小 18×16 capsule・地 `surfaceInk` .10・`type.editorSearchCount` `text.secondary`）。一致の行 20（左 40・右 12・`type.editorSearchMatch`: 前 `editor.tertiary`・一致は地 `editor.caution` .30 radius 2 ＋ `text.primary`・後ろ `text.muted`。狭ければ後ろ → 前の頭 → 一致の順に省略し、前と後ろには省略記号 1 つぶんを残す——見本は行全体の末尾を省略するだけ）。選択は `selectionFill`。結果の列は、見えている行だけを持って使い回す自前の列（AppKit）で描く——行は最大 2 万になり、行の数が変わっても手間が行の総数に依らないようにするため（行の少ないエクスプローラーのツリーは SwiftUI のまま）。行の高さは見出しも一致も 1 つ（VS Code の検索の結果と同じ）。結果の列のつまみと末尾の 1 行分の空きは Explorer と同じ。件数の文はパネルの下に固定（padding 10 12・`type.editorSearchNote`・`editor.tertiary`）。寸法は見本 SearchPanel を u4 で詰めた比率（12.5→12・チップ 16→14・ディレクトリ 11→10.5、一致の行 21→20・mono 11.5→11・左 44→40）で、見出しの高さは見本の 24 から一致の行と同じ 20 にそろえる。
- **Source control panel**（サイドバーの 3 つ目のパネル。器とパネルヘッダーは Explorer と同じ部品。寸法は見本 ScmPanel の値そのまま——Search panel のように詰めない）: ヘッダーは題だけ。実行中の帯 28（0.3 秒を超えて走る操作があるときだけ。地 `surfaceInk` .035・上下 1px `borderInk` .07・上端に Search panel と同じ流れる線・padding 0 8 0 18・gap 8: 操作名 `type.editorScmBandName` `editor.text`／進捗の行 `type.editorScmBandProgress` `text.muted` 末尾省略／止める 20・padding 0 8・radius 3・地 `surfaceInk` .08・四角の印 9 ＋ `type.editorScmStop` `editor.text`）。区分見出し 22（padding 0 12 0 4、区分「ソース管理」とグラフは 0 8 0 4・シェブロン 16 `editor.icon`・`type.editorScmSection` `editor.text`・hover 地 `surfaceInk` .04）。右端のツール 20 角 radius 4・印 13・`text.muted`、hover 地 `surfaceInk` .08 ＋ `editor.text`、押せない姿は不透明度 .35。区分の件数バッジは最小 18×16 capsule・地 `accent.primary` .35・`type.editorScmCount` `text.primary`、一括操作のボタンはその左（間 4）。欄とボタンの箱 padding 2 12 8・gap 6。メッセージ欄は 1 行 26（padding 0 5 0 8・`type.editorScmMessage` `text.primary`・プレースホルダ `editor.tertiary`・地 `sunkInk` .35・枠 1px `borderInk` .10 radius 3、焦点で枠 `accent.primary` .55 radius 5）、10 行まで伸びる。コミットボタン 26（radius 3・地 `accent.primary`・`type.editorScmButton` `tab.activeText`・印 13 と字の間 6・縦線 1px `bg.base` .25・▾ 24）、主の働きが押せない間は働きの側を不透明度 .5（▾ は押せる）。失敗の文はボタンの下に `type.editorScmNote` `danger`・行高 1.5・padding 0 2（地・枠・× は無し）。ファイル行 22（padding 0 12 0 20・gap 6: 種別チップ 16・名前 `type.editorScmFile`〔色は Explorer と同じく印に従う〕・ディレクトリ `type.editorScmDirectory` `editor.tertiary` 末尾省略〔右のボタンとの間は伸びる余白の両側の gap で 12〕・右端に行のボタン 18〔間 2・radius 3・印 13 `editor.text`・hover 地 `surfaceInk` .10・押せない姿は `editor.text` .3〕と印 `type.editorBadge`）。行のボタンはポインタに依らず全部の行に出す。hover 地 `surfaceInk` .045、選択 `selectionFill`。グラフ: 見出しの上に 8 の空き、ブランチの器 24（外側 padding 0 12 6・radius 3・地 `sunkInk` .35・枠 1px `borderInk` .10・padding 0 8・gap 6: ブランチの印 9 `accent.bright`・名前と先行/遅れ `type.editorScmBranch`〔名前 `editor.text`・数 `editor.tertiary`〕）。コミットの行 22（padding 0 12 0 20・gap 6: 点の列 16〔未 push は 7 の塗り `accent.bright` と 2 の輪 `bg.base`、push 済みは 7 の中抜き 1.5 `editor.tertiary`〕・縦の線 1px `borderInk` .12〔左 27、先頭と末尾の行は端を 8 空ける〕・題 `type.editorScmCommit`〔未 push `editor.text`・push 済み `text.muted`。札との間は伸びる余白の両側の gap で 12、札が無ければ右端の padding との間 6〕・右端に ref の札 15〔radius 3・padding 0 5・枠 1px・ブランチの印 8 と間 3・`type.editorScmRef`、local は字 `accent.bright`・地 `accent.primary` .18・枠 `accent.primary` .4、remote は字 `text.muted`・地 `surfaceInk` .06・枠 `borderInk` .14。札どうしの間 4〕）。コミットの行は hover の地を持たない（押せない）。「さらに表示」22（左 42・`type.editorScmMore` `text.muted`、hover で `editor.text`）。列は Search panel と同じ自前の列（AppKit）で、行の高さは同じ高さの続く区間の表で持つ。列のつまみと末尾の 1 行分の空きは Explorer と同じ。git 管理外の一文は `type.editorScmNote` `editor.tertiary`・padding 8 18。
- **File tabs**（列の頭 28）: 地 `sunkInk` .22・下 1px `borderInk` .07。タブは padding 左 10 右 6・gap 6・`type.editorFileTab`・右 1px `borderInk` .07。チップ 14 ＋ 名前 ＋ 右端の枠 20 角（radius 6。押せる範囲で、幅は常に確保）。枠の中は × 12（`editor.icon`）か未保存ドット 8（`text.primary`。外部変更で衝突中は `editor.caution`）: アクティブは × を常に、非アクティブはタブ hover のときだけ出し、未保存は × 自体の hover のときのほかは × の代わりにドット（タブに乗っただけではドットのまま）。× の hover で枠に地 `editor.tabCloseHover` が付き、× は `text.primary` へ上がる。選択は上の例外・文字 `text.primary`、非選択は `text.muted`。溢れは横スクロール（スクローラー非表示）。枠の寸法・角・出し分けは VS Code 1.140 のタブに揃える（`multieditortabscontrol.css` の tab-actions の action-label: 16 ＋ padding 2 で 20 角・未保存は `.action-label:not(:hover)` の間だけドット、`actionbar.css` の角 `cornerRadius.medium` 6）。hover の地は VS Code の `toolbar.hoverBackground`（dark `#5a5d5e50` / light `#b8b8b850`）の中立の灰を、Orbe の hover 地と同じ面の基色（dark 白・light `#3a3151`、`surfaceInk` と同じ）の α .10 に置き換える——温かい炭・藤紙の上に中立の灰を置くと面から浮くため。地との明度差は VS Code と同程度に保つ。**仮のタブ**（→ [editor/shell](../spec/editor/shell.md)）は名前を斜体にし、地に 135° の斜線（線 1・周期 6・`editor.previewHatch` の α .06／見ていないとき .039）を敷く。見ているときは普通のアクティブの地の上に重ね、上縁の accent・右の境の線・チップ・× と未保存の枠は普通のタブと同じ。斜線はタブの左上から数えるので、タブの幅に依らず揃い、横スクロールでタブと一緒に動く。VS Code の preview editor は斜体だけで普通のタブと見分けにくく、日本語名・絵文字では斜体が効かない字もあるので、斜線を足す（デザインキャンバス『7 · 斜線の地』）。light の基色は面の基色（`surfaceInk` と同じ紫の墨）で、地との明度差（L*）が dark に近い（dark の 8〜9 割）——dark の基色はアイコンの色相（`editor.icon` と同値）。
- **Diff tabs**（ファイルタブと同じ列・同じ器。→ [editor/diff](../spec/editor/diff.md)）: 名前の後に種類の注記（「（作業ツリー）」/「（ステージ済み）」。`type.editorDiffNote` 11・`editor.caution`）を gap 6 で続ける。選択は上の例外。仮のタブ・× と未保存の枠はファイルタブと同じ。焦点が diff タブのときだけ、タブ行の右端に**見せ方の切り替え**「インライン / 並列」——帯の左右 padding 10・項目の間 2、項目は padding 2×10・radius 3（`radius.editorDiffSegment`）・`type.editorDiffSegment` 10.5 mono。選んでいる項目は地 `text.primary`・字 `tab.activeText`（前景色反転）、選んでいない項目は地 `surfaceInk` .08（light ×0.6）・字 `text.secondary`。
- **Diff body**（→ [editor/diff](../spec/editor/diff.md)）: 本体はコードビューと同じ字・行高 18・上 4・地なし（chrome の veil を透かす）。行番号の字はコードビューと同じ `editor.lineNumber`。番号の列 1 つは最小 44（`layout.editorDiffNumber`。収まらなければ広がる）で、番号の右の余白はインライン 6・並列 8。インラインは 旧番号｜新番号｜記号の列 18（＋ `diff.added` / − `diff.removed`）｜本文、並列は各側 番号 1 列｜本文で、2 面の境は 1px `borderInk` .07（light ×1.4）。行の地は追加 `diff.added`・削除 `diff.removed` の α `opacity.editorDiffRow`（.12）、詰め物は `surfaceInk` .02（light ×0.6）で、行番号の列の左端から面の右端（縦スクロールバーの列の下）まで。**字は全部の行を普通のファイルと同じ構文色**——見本の `diffText`（文脈 muted・追加 / 削除の専用色）は訳さない（§3）。空白の点も普通のファイルと同じ。ミニマップ・git の印の列・スクロールバーの git の印は持たない。表示できないときの一文は空状態の一文と同じ（`type.editorLead`・`text.muted`・中央）。
- **Breadcrumb**（列の頭 20。文書のタブと diff のタブの両方で出し、タブ行の高さとともに切り替えで本文の上端を動かさない）: padding 左 16 右 12・`type.editorBreadcrumb`・`text.muted`・gap 4。区切りはシェブロン 10（`editor.tertiary`）。ディレクトリは hover で `editor.text`。末尾はチップ 12（radius 2）＋ ファイル名 `editor.text`。
- **Board（自動化の部品）**（見本『Home 自動化』の値をそのまま持つ。寸法はボードのビューが持ち、字は一般の段、色は semantic 名）: 地は面の veil。上から依頼の欄の帯・左の一覧と右の欄・フッター。字の太さは段の字から作る（`monospacedWeight`）。**依頼の欄の帯**: padding 12×16・下 1px `surface.1`。欄は枠の内側の高さ 36・padding 横 14・gap 10・radius `row`・地 `inputWash`・枠 1px（欄に焦点があれば `accent.primary` .5、なければ `inputBorder`。切り替えは `quick` の linear）。頭に ❯（`type.title` `accent.primary`）、入力とプレースホルダは `type.code`（プレースホルダ `text.muted`）、右端に「↵ 依頼する」`type.codeSmall`（焦点があれば `text.secondary`、なければ `text.muted`）。**一覧**: 幅 360・地 `surfaceInk` .02・右 1px `surface.1`。頭は高さ 32・padding 横 16・「自動化」`type.caption` semibold `text.secondary`＋間 8 に件数 `type.codeSmall` `text.muted`。行は器の padding 横 6 の中で高さ 46・padding 横 10・gap 10・radius 6、選択は `selectionFill`（hover の塗りは持たない）。点 6（前回が失敗 `danger`／止めている `text.muted`／ほか `accent.bright`）。上段は行箱 18 で名前 `type.code`（止めていれば `text.muted`、ほか `text.primary`・末尾省略）と、間 8 に右端 `type.codeSmall`（実行中 `accent.bright`／停止中・まだ回っていない `text.muted`／失敗 `danger`／ほか `text.secondary`）。その 2 下に行箱 16 で出力先の種類（`kbKeyText`）と間 12 にいつ（`text.muted`）、どちらも `type.codeSmall`。**右の欄（詳細）**: padding 20×32・縦にスクロール。見出しは名前 `type.title` semibold `text.primary`（行箱 21）、4 下に前回 `type.codeSmall` `text.muted`（行箱 17）、右に次回か停止中 `type.codeSmall` `text.secondary`（行箱 20）。見出しの 22 下に流れ（伸びる）と、間 40 に実行履歴（幅 300）。右の欄の内側の幅が 760 に満たなければ実行履歴を流れの下（間 22）へ回す。欄の見出しは `type.caption` semibold `text.secondary`（行箱 17）、右に添え物、その 10 下に 1px `borderInk` .06。**流れ**: 見出しの右に「前回の件数」`type.codeSmall` `text.muted`（件数の列を出すときだけ）、罫線の 14 下から段。段は点の列 14・本文・件数の列 132 を間 14 で並べる。点は上 6 から 9 の輪（`accent.primary` 1px）、Orbe の段は 7 の破線の輪（`kbKeyMutedText`）、出力先は塗り（`accent.primary`）。点の 4 下から段の下端まで 1px `borderInk` .14 の線（最後の段は描かない）。本文の頭の行は最小 20・ベースライン揃え・間 10 で役割（幅 44・`type.codeSmall` `text.muted`）・名前（`type.code` `text.primary`。Orbe の段は `type.codeSmall` `text.muted`）・手段の札（高さ 18 以上・padding 横 7・radius `sm`・`type.meta`。モデルは地 `accent.primary` .16・字 `accent.bright`、コマンドと使えるツールは地 `plainPillFill`・字 `text.secondary`。札の中の字は切らずに折り返す）。その下は役割の幅＋間（54）だけ下げて間 6 で、原文の箱（padding 6×10・最大幅 640・地 `inputWash`・枠 1px `inputBorder`・radius 6・`type.codeCompact` `text.primary` `line.body`）、使えるツールの札（間 4 で折り返す）、作業ディレクトリの注記（`type.codeSmall` `text.muted`）。出力先がタスク候補なら、出力先の段の下に同じ注記で「これまでに採用 N件 / 見送り N件」（数と単位は詰め、「·」で区切らない）。段の下の間はトリガー 20・Orbe 16・ほか 18・最後の段 0。件数の列は行箱 20 の右寄せで、棒（高さ 6・最大 96・capsule・`accent.primary` .55、Orbe の段は `borderInk` .18）と間 10 に数（幅 26 右寄せ・`type.workspaceName` `text.primary`、Orbe の段は `text.muted`）。**実行履歴**: 見出しの右に帯（4×10・radius 1・間 2。出した `accent.primary`／何も出さなかった `editorGhost`／失敗 `danger`）、罫線の 8 下から 1 行 24 の行。時刻の列は中身の幅（`type.codeSmall` `text.secondary`）、間 14 に結果 `type.codeSmall`（出した `text.primary`／何も出さなかった `text.muted`／失敗 `danger`）。失敗の行は理由を、報告の行は報告の全文を省かず、行の間隔 24 のまま折り返す。**欄を選んでいる間の右の欄**: padding 28×32・最大幅 760・間 18。案内 `type.code` `text.primary` 行高 1.7、「入力例」`type.codeSmall` `text.muted`、その下に間 6 で例（❯ `kbKeyMutedText` と間 10 に文 `type.workspaceName` `text.primary` `line.body`）。**フッター**: 高さ 28（上 1px `surface.1` の下）・padding 横 16・間 16・`type.codeSmall` `text.muted`、キーは `kbKeyText`、キーと名前の間は 1 字。右端に断り（`danger`。色だけでなく文言でも言う）。行箱の値（21・17・19 など）は見本の描画の、日本語の字の行箱。見本からずらした点: 札の 10.5 は `type.meta`（10）、❯ の 13 は `type.title`（14）に寄せる——一般の段に 10.5・13 の等幅が無いため。モデルの札の字（見本 `#c9b3ff`）は `accent.bright` に写す——無い値のトークンを増やさない。件数の数の幅は見本の 20 ではなく 26——3 桁の数を切らないため。実行履歴の幅は見本『一番単純な例』の 330 ではなく『段の多い例』の 300 にそろえ、時刻の列は中身の幅で決める（見本どうしの差は仮の時刻の文の長さから来ている）。
- **Empty state**: 中央・`type.body`・`text.muted` の一文＋必要なら `type.meta` ヒント。装飾なし。**エディター面**の空状態は見本の値をそのまま持つ: ◐（`OrbeMarkGlyph` 44・`editor.ghost`）・その 18 下に `type.editorLead`・`text.muted` の一文・22 下にショートカット行（gap 8。ラベル `type.editorHint`・`text.muted`・幅 170 右寄せ ＋ gap 12 ＋ kbd）。kbd＝`type.editorHint`・文字 `editor.icon`・枠 hairline `borderInk` .14（light ×1.4）・radius `sm`・padding 1×7・地 `surfaceInk` .05（light ×0.6）。**ボード**の空状態は一文だけで、字種と色はエディター面の一文と同じ（`type.editorLead`・`text.muted`）。

### 5.1 chrome（2 段 28+28・TopBar＋TabBar）

- **TopBar（上段 28px）**: 背景透明（最背面の chromeBg＋ambient が見える）・**罫線なし**。左 padding 16＋信号機の柱 80px。縦位置は信号機 close ボタン中央へ整列。空白は窓ドラッグ面。
  - 左: `workspace名`（mono 11・`text.primary`）。build-id・現在地は名前の後に後置（→§9）。現在地は焦点の面のもので、トーン付きの断片列——端末焦点は cwd 1 本（`text.muted`）、エディター焦点は根（`text.muted`）＋ 相対パス（`statusText`）、根の外の文書は絶対パス 1 本（`statusText`）、空状態は根だけ。
  - 右: ステータスストリップ（§4 の書式）・右 padding 16。
- **窓が main でない間（退いた姿）**: chrome だけが退き、端末・エディターの本文の濃さは変えない。切り替えは即時（アニメーションなし）。
  - グロー（BackgroundGlow のラジアル 2 枚）を描かない。不透明時の `bg.base` の地は残す。
  - workspace 名 `text.muted`。現在地は 2 トーンの強弱を保って一段沈める——弱い断片 `text.mutedInactive`・強い断片 `text.muted`。ストリップの件数 `text.muted`（idle の減光は残す）。
  - 選択セル＝地 `tab.activeBgInactive`・文字と家のアイコン `text.primary`・グリフは通常の状態色（done の check 線も既定の `checkStroke`）。改名中の入力欄の文字も `text.primary`。非選択セルの文字 `text.muted`。
  - 状態グリフの色・build-id・＋・位置ドット・連の地／枠／識別バー・区切り線・挿入キャレットは変えない。
- **TabBar（下段 28px・全幅セグメント行）**: 地 `tab.rowBg`・padding 上下 3・左右 5・セグメント間 gap 5（行の端の隙間はセグメント間と同じリズム）。器とセルは §5 Tab 契約。行に収まらないときは**行内の全セル**が幅に比例して縮み（床 40・器ではなく行が再配分の単位）、それ以下は横スクロール。＋ボタンはセグメント様式（地 `tab.segBg`・radius 3）で末尾に置く（→§9）。並び替えのドラッグ中は挿入先に幅 2 の縦キャレット `accent.bright`（識別色の地の上に立つ）。

---

## 6. Swift 実装

`Sources/Orbe/DesignSystem/DesignTokens.swift` が値の SSOT。`NSColor(name:dynamicProvider:)` で dark/light を自動出し分け、`.xcassets` 不要。

```swift
label.font = Theme.Typography.label
label.textColor = Theme.Color.textSecondary
rowView.layer?.backgroundColor = Theme.Color.selectionFill.cgColor   // 選択行
```

SwiftUI は `Color.theme.x` / `Font.theme.x`（`DesignTokens+SwiftUI.swift` のミラー）。余白・角丸・線・モーションは CGFloat/Double なので `Theme.Space.bar` / `Theme.Motion.spin` 等を直接使う。

---

## 7. 命名・バージョニング

- token id は `domain.role`（`text.secondary`）。Swift は `Theme.<Domain>.<roleCamel>`（`Theme.Color.textSecondary`）。`tokens.json` と1対1。
- appearances は `dark` / `light`。新トークンは semantic（役割）で足し、生 hex を component に書かない。原始パレットを増やすときは、識別色は `OrbePalette.swift`・chrome は `DesignTokens.swift` に定義を足し、本書と `tokens.json` へ反映する。
- バージョンは `docs/design/tokens.json` の `$meta.version`（semver）。0.x の間は役割の追加/削除も minor、値変更は patch。1.0 は役割集合の安定を宣言するときに上げる。本書冒頭の日付も更新する。

---

## 8. ターミナル本体（Ghostty）

中央ターミナル（Ghostty が描く Metal レイヤー）も chrome の外観に寄せる。色は chrome のトークンとは別レイヤー（Ghostty の named theme）で持ち、`theme = light:OrbeLight,dark:OrbeDark`（バンドル `Contents/Resources/ghostty/themes/` はこの2枚のみ・出所 `app/themes/`）に固定。

- **配色**: ANSI 16 色＋端末 bg/fg/cursor/selection は識別色 SSOT `OrbePalette.swift` が持ち、`renderConf` が conf 2枚（`app/themes/OrbeDark` / `OrbeLight`）を生成する（手写しの転写なし）。16 色は確定配色値。dark は **VS Code Dark+ のシンタックストークン色**を ANSI スロットへ再配置したもの（VS Code の `terminal.ansi*` とは別物）、light は無彩色ランプ 0/7/15 が **Catppuccin Latte** 由来（8 のみ AA 是正）で有彩色 1–6 は light 背景向けに決めた値。chrome と共有するアンカーは 背景 `chromeBg`（`#171420`/light `#fcfbfe`）・前景 `chromeText`（`#e6e1f0`/`#3a3151`）・カーソル `accent`（`#9068f0`/`#6d43d8`）・赤 `danger`（1・9）・緑 `success`（2・10）・黄 `conflict`（3・11）で、dark/light とも端末 ink と同値。light の bright 赤/緑/黄（9–14）は normal（1–6）のミラー。ink スロット {1-6,8-14} は原則 各モードの背景に対し WCAG AA 4.5 以上（構造色 0/7/15 は最暗/最明淡色として ANSI 慣習で対象外）。ただし確定値の一部は 4.5 に満たず、人が承認済みの確定値を優先してゲートから除外する（`OrbePalette.aaExemptDark/Light`＝dark 8・light 1/2/3/9/10/11）。`swift test`（`OrbePaletteTests`）が除外外の ink のコントラストと conf の drift（SSOT からの再生成＝コミット済み）を検証し、回帰と転写ドリフトをコミット不能にする。
- **テーマ選択**: ユーザーが選べるのは **Auto / Dark / Light の外観スイッチ**（`ThemeMode`・`NSApp.appearance` 経由で chrome とターミナルが揃って切替）だけで、ターミナル配色自体は選べない。gui.conf が上記 theme 行を常時吐き、`~/.config/ghostty` の theme 指定を無効化する。
- **カーソル**: 電紫のブロック（`cursor-style = block`＋テーマの `cursor-color`＝accent）＋点滅 ON/OFF は設定パレット。点滅周期は Ghostty ハードコードの標準 600ms（chrome の `blink` 1.1s（§2.5）とは周期が異なるが、エンジンを fork しない方針で受容）。
- **背景透過**: 既定 `background-opacity = 0.9`。半透明の端末越しに AppShell 最背面の accent＋working glow が中央へ滲む。ユーザーが設定パレットで不透明度を明示すると層3（`gui.conf`）が後勝ちする。

---

## 9. 設計判断（機能維持のための上乗せ）

「装飾は最小」（§1）を貫くと落ちてしまうが、実運用に要る要素。削らず、Orbe の様式に沿った形で吸収している。

- **cwd / build-id**（TopBar 左・workspace 名の後に muted）
- **＋ボタン**（タブ行末尾・セグメント様式）
- **タブの横スクロール**（min-width 0 まで潰さず min 40 で止め、溢れは横スクロール——可読性を優先）
- **補完のグループ見出し・フッターヒント・スクロールつまみ**（候補パネルの基本形は素のリスト）
- **パレットの drillIn・breadcrumb・フッターヒント**
- **設定パレット**（独立した Settings 画面は持たず、パレット形式のまま寸法・様式だけを揃える。テーマの選択肢は Auto / Dark / Light の 3 択）
