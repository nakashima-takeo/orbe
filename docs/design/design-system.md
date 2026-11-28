---
title: Orbe デザインシステム
description: 外観の思想・契約を記す自由記述ドキュメント。値の正は DesignSystem/ の Swift、思想・契約の正は本書
updated: 2026-11-28
---

# Orbe デザインシステム

> ステータス: v0.17.0 · 2026-11-19
> 値の正（SSOT）: chrome/semantic は `Sources/Orbe/DesignSystem/DesignTokens.swift`（機械可読ミラー `docs/design/tokens.json`）／ 識別色（端末 ANSI 16 色・chrome 共有アンカー）は `Sources/Orbe/DesignSystem/OrbePalette.swift`（端末 conf を生成し、chrome アンカーへ定数を供給）／ worktree 識別色 48 色（24 色相 × 2 トーン）を dark / light 別に持つ表は `Sources/Orbe/DesignSystem/WorktreePalette.swift`（`scripts/gen-worktree-palette.py` が oklch から生成・手で編集しない）。
> ガラス質感・elevation・glow は `Sources/Orbe/DesignSystem/DesignTokens+Glass.swift` が所有（本書は再定義しない）。
> エディター面のトークン（`editor.*` / `diff.*` / `syntax.*` / `type.editor*` / `layout.editor*` / `opacity.editor*` / `stroke.editor*` / `editorSlider*` `editorScrollbar*`）は `Sources/Orbe/DesignSystem/DesignTokens+Editor.swift` が所有。ただし PR のパネルと PR のコメントの色・字・寸法（§5 の PR panel・PR comments が使うものと、§3 の type の `editorPr…` の行）は `Sources/Orbe/DesignSystem/DesignTokens+PullRequest.swift` が所有。上のバーの共通の部品（§5 の Editor bar の札・アイコンのボタン・右端の主な操作のボタン）のトークンは `Sources/Orbe/DesignSystem/DesignTokens+EditorBar.swift`、上のバーの右下の置き場（§5 の Editor dock）のトークンは `Sources/Orbe/DesignSystem/DesignTokens+EditorDock.swift`、1 行の入力欄の枠（§5 の Field frame）のトークンは `Sources/Orbe/DesignSystem/DesignTokens+EditorField.swift`、面の中の確認（§5 の Editor confirm）の字と寸法は `Sources/Orbe/DesignSystem/DesignTokens+EditorConfirm.swift` が所有（幕の色 `editor.confirmVeil` は `DesignTokens+Editor.swift`）。
> 本書は思想・契約を記す自由記述ドキュメントで、**思想・契約の正は本書、値の正は上記 Swift**。Orbe の外観の**正**はこのリポジトリの中で閉じている。ただしコード中の一部コメントは、値が決まった経緯の記録として設計見本（リポジトリ外）を引用する——それは出所の記録であって、正ではない。

Orbe は AI コーディングエージェントのためのネイティブ macOS ターミナル。外観は
**dark = 温かい炭＋フロストガラス**（既定）、**light = 藤紙×電紫**（藤紙＋ガラス）。chrome（StatusRow・タブ・パレット・検索・オンボーディング）をこの semantic トークンで統一し、ターミナルと外側を一体にする。

---

## 1. 原則

1. **温かく、落ち着いて、密に。** 地は温かい炭／藤紙。装飾は最小、情報は密。
2. **色は状態と自分の出番に。** 無彩に近い土台の上で、色は **エージェントの状態（確定配色の温度分け）** と **自分の出番（電紫 accent＝選択・プロンプト）** にだけ使う。
3. **状態は3チャンネルで冗長に。** 動き=working／吹き出し=waiting／チェック=done／zzz=idle。色・形・動きのどれを失っても判別できる（→ §3・§4）。
4. **選択は tint 塗り、タブだけ反転。** リスト行の選択は `selectionFill` の淡塗り。タブの選択のみ前景色を背景にした**反転表示**（背景を状態色で塗らない）。左 3px バー・下線・太字による選択弁別は使わない。
5. **ラベルはターミナル語。** UI 本文・プローズはシステムサンセリフ、ターミナル・ラベル・コード・ステータス語は monospace。
6. **ガラスは Glass に委任。** フロストガラスの面・ぼかし・影・温度 glow は `DesignTokens+Glass.swift`（別ファイル）が持つ。本書のトークンは非ガラスの色・字・余白・角丸・モーション。
7. **トークンだけを参照する。** コンポーネントは semantic 名（`Theme.Color.textSecondary` 等）だけを使い、生 hex・`NSColor.systemXxx`・直書き `ofSize:` を書かない。
8. **記号・マークは基本的にすべて手作りする。** 成否・状態・受け皿・外へ開く矢印などの印は、自前の図形（SwiftUI の `Path`。`StatusGlyph.swift`・`MarkGlyph.swift`）で描く。文字コードの記号（✓・×・↗ など）やシステムのアイコンを印に使わない——字形がフォントで変わり、無いこともあるため。品質の高い印のセットを使うことは否定しない。

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
| `editor.ghost` | 沈んだ塗り（アバターの地など） | `#3d3752` | `#d9d3e6` |
| `editor.icon` | エディター面のアイコン・kbd の文字（dark / light とも `kbKeyText` と偶然同値だが別トークン） | `#a99fb8` | `#766e8d` |
| `editor.text` | エディター面の 2 段目の文字——コードの素文字・ファイル名（dark / light とも `statusText` と偶然同値だが別トークン） | `#cdc7e2` | `#4d4368` |
| `editor.tertiary` | エディター面の三次の文字（`text.tertiary` は `text.muted` の別名なので別値） | `#6d667a` | `#aca4bd` |
| `editor.prose` | 説明文の段——PR の説明（`editor.text` と `text.muted` の間） | `#a9a2b5` | `#6d647f` |
| `editor.caution` | 注意の黄——検索の一致の地・PR のパネルの手元とのずれの帯など（dark は `conflict` と偶然同値だが light が違い、git 競合でもない） | `#e2cd6d` | `#a07f0c` |
| `diff.added` | git の追加（青）——ガター・A / U のバッジと名前・印・diff の記号と行の地の基 | `#5ea8ff` | `#0969da` |
| `diff.removed` | git の削除（オレンジ）——ガターの三角・印・diff の記号と行の地の基 | `#f0883e` | `#bc4c00` |
| `diff.modified` | git の変更（黄）——ガター・M のバッジと名前・印 | `#e2cd6d` | `#a07f0c` |
| `editor.onDanger` | danger の地の上の字（§5 Large button の「破棄」） | `#ffffff` | `#ffffff` |
| `editor.barGroove` | 上のバーの画面の切り替えの溝の地（§5 Editor bar） | `rgba(8,6,12,.32)` | `rgba(58,49,81,.05)` |
| `editor.barInset` | 上のバーの溝の内側の影と、選んだ項目の下に落とす影の色（§5 Editor bar） | `rgba(0,0,0,.40)` | `rgba(58,49,81,.14)` |
| `editor.confirmVeil` | 面の中の確認の幕（§5 Editor confirm） | `rgba(0,0,0,.42)` | `rgba(58,49,81,.20)` |
| `editor.hue.{orange,blue,yellow,sky,violet,cyan,red,green,teal}` | 種別チップの色相（文字と α .16 の地）。種別 → 色相の表は `FileChip` が持つ | `DesignTokens+Editor.swift` の `editorHue*`（`tokens.json` の `editor.hue.*`） | 同 |
| `surfaceInk` | カード・面の基色（view 側で α を掛ける。HelpCard・MenuBar、エディター面の hover 地 .045 / 上のバーの押された姿 .08・選んだ項目 .11 / キーの札 .07） | `#ffffff` | `#3a3151` |
| `sunkInk` | 沈み面の基色（dark は scrim と同じ暗幕の基色）。view 側で α を掛ける（エディター面の左の列 .45 など。light は ×0.3） | `#0a080e` | `#3a3151` |
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
**値だけが一致する独立トークン**: `text.mutedInactive` ＝ `kbKeyMutedText`／ `editor.icon` ＝ `kbKeyText`／ `editor.text` ＝ `statusText`／ `editor.caution` ＝ `diff.modified` ＝ `editor.hue.yellow`／ `editor.whitespace` ＝ `editor.lineNumber`／ `editor.hue.sky` ＝ `syntax.variable`（上の収束と違い SSOT でも互いを参照せず、片方の値が動いてももう片方は追随しない）。`syntax.*` の dark は VSCode Dark Modern の実在トークン色で、5 色が端末の ANSI（§8）と偶然同値だが、端末色は別レイヤーなので参照しない。選択・俯瞰・強調の `editor.*`（selection〜minimapShadow）は VS Code Dark Modern / Light Modern の値（上書きの無いものは VS Code の既定）で、エディターの使い勝手を VS Code に揃えるために借りる。同じ意味の Orbe トークンがあるもの（git の印・キャレット・縁）はそれを使い、git の印とキャレットには VS Code の α を掛ける。
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
| `type.editorLead` | 13 / regular / sans | 表示できない diff の理由の一文・ボードの空状態の一文 |
| `type.editorEmptyTitle` / `editorEmptyText` | 14 / medium・12.5 / regular / sans | 本体の空・使えないときの表示の見出し・案内の一文とショートカットの行と主でないボタン |
| `type.editorEmptyButton` | 12.5 / semibold / sans | 同じ表示の主のボタン |
| `type.editorKeyCap` | 10.5 / semibold / sans | キーの札の字 |
| `type.editorTextButton` | 11.5 / regular / sans | 字のボタンの字 |
| `type.editorBarChip` / `editorBarChipFilled` | 12 / regular / mono・12 / regular / sans | 上のバーの中ほどの札・その地つきの変種（同期） |
| `type.editorBarAction` | 12 / semibold / sans | 上のバーの右端の主な操作のボタンの名前 |
| `type.editorBarFind` / `editorBarFindCount` | 12 / regular / mono・11 / regular / mono | 上のバーのファイル内検索の欄の入力・件数 |
| `type.editorDockCard` | 12 / regular / sans | 上のバーの右下の置き場の札の文（失敗の札・実行中の札の操作名）・コミットのポップアップの赤い行の文（行高 1.55） |
| `type.editorRunningProgress` | 11 / regular / mono | 実行中の札の git の進捗の行 |
| `type.editorConfirmTitle` / `editorConfirmMessage` | 14 / semibold / sans・12.5 / regular / sans | 面の中の確認の題（行高 1.45）・本文（行高 1.6） |
| `type.editorSyncCount` | 11.5 / regular / mono | Changes の上のバーの同期の先行・遅れの数 |
| `type.editorCommitPrompt` / `editorCommitMessage` | 13 / semibold / mono・12.5 / regular / sans | コミットのポップアップの記号「❯」・メッセージ欄（行の高さ 20） |
| `type.editorDiffHeaderPath` / `editorDiffHeaderName` / `editorDiffHeaderBadge` | 12 / regular・12 / semibold・10.5 / semibold / mono | 差分のファイルの見出しのパス・ファイル名・状態の字 |
| `type.editorItemButtonPath` / `editorItemButtonName` | 12 / regular・12 / semibold / mono | 上のバーの今の項目のボタンの親のパス・名前 |
| `type.editorTag` | 10.5 / regular / sans | 状態を示す札（Tag）の字 |
| `type.editorItemListHeading` / `editorItemListCount` | 10.5 / semibold / sans・10.5 / medium / mono | 一覧の器の見出しの題・数 |
| `type.editorItemListName` / `editorItemListDirectory` / `editorItemListBadge` | 12.5 / medium / sans・11 / regular / mono・10.5 / semibold / mono | 一覧の器のファイルの行の名前・ディレクトリ・状態の字 |
| `type.editorItemListAction` / `editorItemListHint` | 12.5 / regular / sans・11 / regular / sans | 一覧の器の操作の行・下の案内 |
| `type.editorSidebarNote` | 12 / regular / sans | 左の列の、出すものが無い・表示できないときの一言 |
| `type.editorBarSwitch` | 12.5 / medium / sans | 上のバーの画面の切り替えの項目 |
| `type.editorBarCount` / `editorBarHint` | 10.5 / medium・11 / regular / mono | 上のバーの切り替えの添え字（件数・PR の番号）・「⌥ 端末を表示」 |
| `type.editorCode` | 12 / regular / mono | コード本体 |
| `type.editorLineNumber` | 11 / regular / mono | 行番号 |
| `type.editorPanelTitle` | 11 / regular / sans | 左の列のパネルヘッダーの題（tracking 0.5） |
| `type.editorTreeRow` | 12.5 / regular / sans | ツリー行のファイルの名前 |
| `type.editorTreeFolder` | 11.5 / regular / mono | ツリー行のフォルダの名前 |
| `type.editorTreeBadge` | 10.5 / semibold / mono | ツリー行の git の字 |
| `type.editorTreeFilter` | 12 / regular / sans | ツリーの絞り込みの欄 |
| `type.editorBadge` | 11 / regular / mono | ソース管理・PR のパネルの行の git の字 |
| `type.editorSearchTitle` | 12.5 / semibold / sans | 検索パネルの見出しの題 |
| `type.editorSearchField` | 12 / regular / mono | 検索パネルの入力欄 |
| `type.editorSearchOption` | 10 / regular / sans | 入力欄の右の Aa / ab / .* |
| `type.editorSearchFile` | 12 / regular / sans | 検索結果のまとまりの見出しのファイル名 |
| `type.editorSearchDirectory` | 10.5 / regular / sans | 見出しのディレクトリ |
| `type.editorSearchCount` | 9.5 / regular / sans | 見出しの件数バッジ |
| `type.editorSearchMatch` | 11 / regular / mono | 一致の行 |
| `type.editorSearchNote` | 11 / regular / sans | 件数・打ち切り・0 件・エラーの文 |
| `type.editorScmSection` | 11 / bold / sans | ソース管理の親・子の区分・グラフの枠の見出し |
| `type.editorScmCount` | 9.5 / regular / sans | 区分見出しの件数バッジ |
| `type.editorScmFile` / `editorScmDirectory` | 13・11 / regular / sans | ソース管理のファイル行の名前・ディレクトリ |
| `type.editorScmCommit` | 12 / regular / sans | グラフのコミットの題 |
| `type.editorScmRef` / `editorScmBranch` | 9・11 / regular / mono | グラフの ref の札・ブランチの行 |
| `type.editorScmMore` | 11.5 / regular / sans | グラフの「さらに表示」 |
| `type.editorPrTitle` / `editorPrDescription` | 13・11.5 / regular / sans | PR のパネルの頭の題（行高 1.4）・説明の本文（行高 1.6） |
| `type.editorPrMeta` / `editorPrCount` | 10.5 / regular / mono | PR のパネルの作者と `head → base`・コミットの sha と「N/M 確認済み」と「済/全」 |
| `type.editorPrBand` | 11 / regular / sans | PR のパネルの帯 |
| `type.editorPrThreadHead` / `editorPrThreadBody` / `editorPrReplyField` | 11・12・12 / regular / sans | スレッドの頭とメタの行と失敗の文・本文（行高 1.6）・返信欄（行 16） |
| `type.editorPrThreadAuthor` / `editorPrThreadAvatar` / `editorPrThreadBadge` | 11・10・10 / semibold・semibold・regular / sans | 書いた人・アバターの頭文字・未送信の札 |
| `type.editorPrThreadStatus` / `editorPrThreadCode` | 10.5・12 / regular / mono | 頭の状態・インラインコードとコードブロック |
| `type.editorPrThreadButton` / `editorPrThreadPrimaryButton` | 11.5 / regular・semibold / sans | 返信の行のボタン（「レビューに追加」は semibold） |
| `type.editorPrPopupHeading` | 10.5 / semibold / sans | レビューのポップアップの区分の見出し（数を含む） |
| `type.editorPrPopupField` | 12.5 / regular / sans（1 行の高さ 20） | レビューのポップアップの全体へのコメント欄 |
| `type.editorPrPopupRow` / `editorPrPopupRef` | 12・11.5 / regular / sans・mono | 未送信のコメントの行の本文とその場所の札 |
| `type.editorPrPopupEvent` / `editorPrPopupEventSelected` | 12 / regular・semibold / sans | 種類（選んだ種類は semibold） |
| `type.editorChip` | 16 で 10 / 9 / 8 / bold / mono | 種別チップのグリフ（字数で決め、14 / 12 へは比例して丸める） |

**tracking / line-height スカラ**（NSFont では表せず、使用側で `.tracking()` / lineSpacing 換算）:
`tracking.label` 1（大文字セクション見出し）／ `tracking.status` 0.3（ステータスストリップ）／ `tracking.key` 1（⌘H バッジ・キーバッジ・チップのキー表記）／ `tracking.panelTitle` 0.5（左の列のパネルヘッダーの題）／ `line.body` 1.6（本文）／ `line.terminal` 1.55（ターミナル本文）／ `line.editorCode` 18pt（コード本体。倍率ではなく固定値）。倍率の行高は CSS の line-height と同じく、1 行目の上と最終行の下にも差の半分ずつを置く。

### 2.4 余白・角丸・線
- **spacing（2/4pt グリッド・穴なし）**: `hair 2 / tick 4 / note 6 / step 8 / beat 12 / bar 16 / span 20 / phrase 24`
- **radius**: `xs 3`（単独タブの器・＋ボタン）/ `sm 4`（バッジ・キーヒント・タブグループの器）/ `row 8`（リスト行・小コントロール）/ `md 10`（入力・小パネル）/ `card 12`（カード・設定行）/ `lg 16`（パネル・オーバーレイ）/ `pill 999`（カウントピル・トグル）
- **stroke**: `hairline 1`（罫線・枠）/ `focusRing 2`（フォーカスリング）
- **layout（エディター面の骨）**: `editorBar 36`（上のバー。下端の hairline 1 を含む）/ `editorSidebar 263`（左の列の既定の幅。ドラッグで可変。右の hairline 1 はこの外側に足し、合わせて 264）/ `editorSidebarMinWidth 160` / `editorBodyMinWidth 160`（左の列の幅の上限と、狭い面で表示幅を切り詰める規則）/ `editorSidebarHandle 4`（境の当たり）/ `editorKeyCap 18`・`editorKeyCapPadX 4`・`editorKeyCapRadius 5`・`editorKeyCapGlyph 12`（キーの札の高さと最小幅・左右の余白・角丸・中の印）/ `editorTextButton 22`・`editorTextButtonPadX 7`・`editorTextButtonRadius 6`・`editorTextButtonGlyph 14`・`editorTextButtonGap 5`・`editorTextButtonKeyGap 11`（字のボタンの高さ・左右の余白・角丸・印・印と字の間・字とキーの札の間）/ `editorItemButton 26`・`editorItemButtonPadX 8`・`editorItemButtonRadius 7`・`editorItemButtonGap 6`・`editorItemButtonCaret 14`（今の項目のボタンの高さ・左右の余白・角丸・中の間・▾）/ `editorItemDot 7`（未保存・ディスクが変わったの丸）/ `editorFieldRadius 7`・`editorFieldPadLeading 8`・`editorFieldPadTrailing 4`・`editorFieldGap 6`・`editorFieldGlyph 14`・`editorFieldFocusStroke 1.5`（入力欄の枠の角丸・左右の余白・中の間・虫眼鏡・フォーカスの枠）/ `editorTagPadX 6`・`editorTagPadY 1`・`editorTagRadius 4`（Tag の余白と角丸）/ `editorItemListWidth 420`・`editorItemListRow 26`・`editorItemListPad 5`・`editorItemListRowRadius 6`・`editorItemListRowPadX 8`・`editorItemListRowGap 8`・`editorItemListActionPadX 10`・`editorItemListMark 16`・`editorItemListMarkGlyph 10`・`editorItemListBadge 12`・`editorItemListFooter 34`・`editorItemListHintGap 14`・`editorItemListBottom 12`（一覧の器の幅・行・内側の余白・選択とホバーの角丸・行の余白と間・操作の行の余白・右の印の枠と ×・状態の字の列・下の案内の高さと間・面の下に残す余白）/ `editorPanelHeader 28` / `editorRow 24`（ツリーの行）・`editorTreeTopPad 8`・`editorTreeField 26`・`editorTreeFieldGap 4`・`editorTreeInset 6`・`editorTreeRowRadius 6`・`editorTreeRowPadX 8`・`editorTreeRowGroundInset 1`・`editorTreeGuide 14`・`editorTreeChevron 14`・`editorTreeNameGap 4`・`editorTreeChipGap 6`・`editorTreeBadge 12`（エクスプローラーの上の行の余白と絞り込みの欄・欄とツールの間・一覧の左右の内側・行の角丸と左右の余白・選択と開いている行の地の上下の空き・字下げ 1 段・シェブロン・フォルダの名前の左・種別チップの右・git の字の列）/ `editorChip 14` / `editorChevron 16` / `editorLineNumberGutter 50`（行番号の列。桁が増えれば広がる最小幅）/ `editorMarkGutter 19`（git の印の列）/ `editorScrollbar 14`（本体の右端の縦スクロールバー）/ `editorHorizontalScrollbar 12`（本文の区画の下端の横スクロールバー）/ `editorSidebarScrollbar 10`（左の列の一覧——エクスプローラーのツリー・検索結果・ソース管理の列——の縦のつまみ）/ `editorMinimapMaxWidth 120`（その左のミニマップの幅の上限。幅は本文の幅から計算する）。検索パネル: `editorSearchHeader 38`・`editorSearchHeaderLeading 12`・`editorSearchHeaderTrailing 8`・`editorSearchHeaderGap 6`（見出しの高さ・左右の余白・部品の間）/ `editorSearchField 28`（入力欄）・`editorSearchFieldBottom 6`（入力欄の下）・`editorSearchSummaryTop 4`（件数の文の上）/ `editorSearchOption 20`（オプションの角）/ `editorSearchRow 20`（結果の行。まとまりの見出しも一致も同じ）/ `editorSearchMatchIndent 40`（一致の行の左）/ `editorSearchCountWidth 18`・`editorSearchCountHeight 16`（件数バッジ）/ `editorSearchChevron 10`（見出しのシェブロン）/ `editorProgressLine 2`（検索中・ソース管理の実行中の札の線）。ソース管理パネル: `editorScmRow 22`（見出し・ファイル行・ブランチの行・コミット・さらに表示）/ `editorScmChip 16` / `editorScmRowButton 18`（行のボタン）/ `editorScmGlyph 13`（ボタンの印）/ `editorScmTool 20`（見出しのツール）/ `editorScmToolGap 1`（見出しのツールどうし・一括操作のボタンどうしの間）/ `editorScmIndent 8`（子の区分の字下げ）/ `editorScmRef 15`（ref の札）/ `editorScmDot 7`・`editorScmDotColumn 16`（コミットの点とその列）/ `editorScmGraph 198`・`editorScmGraphMin 88`（グラフの枠の高さの既定〔見出し＋8 行〕と下限〔見出し＋3 行〕）。エディター面の半透明面の light 換算は `opacity.editorSunkLight 0.3` / `editorFillLight 0.6` / `editorHairlineLight 1.4`。差分のファイルの見出しは `opacity.editorDiffHeaderGround 0.035`（`surfaceInk` の α）・`editorDiffHeaderLine 0.07`・`editorDiffHeaderDivider 0.15`（hairline の α）。キーの札の地は `opacity.editorKeyCap 0.07`、字のボタンの地は `opacity.editorTextButtonFill 0.08`・`editorTextButtonFillHover 0.12`、今の項目のボタンの地と枠は `opacity.editorItemButtonFill 0.06`・`editorItemButtonBorder 0.05`・`editorItemButtonOpen 0.11`、Tag の枠は `opacity.editorTag 0.2`、入力欄の枠の地は `opacity.editorFieldFill 0.055`、ツリーの開いている行の地と枠は `opacity.editorTreeOpen 0.06`・`editorTreeOpenBorder 0.05`（どれも `surfaceInk` の α）。入力欄の枠のフォーカスの枠は `opacity.editorFieldFocus 0.55`（`accent.primary` の α）。ツリーの行のホバーの地は `opacity.editorTreeHover 0.045`（塗りの α。light ×0.6）、字下げの線は `opacity.editorTreeGuide 0.15`（hairline の α）。一覧の器の行のホバーの地と右の印の枠のホバーの地は `opacity.editorItemListHover 0.045`・`editorItemListMarkHover 0.10`（塗りの α。light ×0.6）。上のバーの共通の部品・大きい字のボタン・置き場・面の中の確認の寸法と α は §5 の Editor bar・Large button・Editor dock・Editor confirm に書く（`layout.editorBar…`・`editorLargeButton…`・`editorDock…`・`editorPopup…`・`editorCard…`・`editorRunning…`・`editorConfirm…`、`opacity.editorBar…`・`editorLargeButtonKeyCap`・`editorPopupTint…`・`editorFailureBorder`・`editorCardCloseHover`）。
- elevation（面の影）は `DesignTokens+Glass.swift` が所有。本書・`tokens.json` は再定義しない。

### 2.5 モーション（拍）
遷移は **3 段＋instant** に固定。標準イージング `cubic-bezier(0.2, 0, 0, 1)`（ease-out 寄り）。
ループ3種は状態表現の定常アニメ。

| token | 値 | 曲線 / 用途 |
|---|---|---|
| `instant` | 0 | 矢印ナビ・パレット表示（一瞬） |
| `quick` | 120ms | hover・下線・フォーカスリング・エディター面の透かしの出入り |
| `base` | 180ms | パネルのスライド・エディター面の開閉のフェード |
| `slow` | 240ms | バッジフェード |
| `spin` | 1.6s | working スピナー（linear infinite・rotate360） |
| `float` | 2.6s | waiting 浮遊（ease-in-out infinite・translateY `floatOffset` -1） |
| `blink` | 1.1s | 点滅（0–55% 表示 / 56–100% 非表示） |
| `editorSliderFadeIn` | 100ms | ミニマップの帯が現れる・消える、スクロールバーのつまみが現れる（linear） |
| `editorScrollbarFadeOut` | 800ms | つまみが消える（linear）。スクロールが止まって `editorScrollbarHideDelay` 500ms 後に始まる |

> リズム規律: 同種の遷移に別々の時間を使わない。`reduce motion` 環境では遷移は `instant`・ループは停止（スピナーは静的な 3/4 円弧のまま残り、形で working と判別できる）。

---

## 3. アクセシビリティ契約（全コンポーネント共通・最優先）

**色だけに意味を持たせない。** 意味は必ず 形・記号・位置・文字 のいずれかでも伝え、色は補強に回す。

- **成功＝green（`success`）＋ `✓`／エラー＝red（`danger`）＋ `⚠`。**
- **git の色は赤と緑に頼らない**: 追加＝青（`diff.added`）・削除＝オレンジ（`diff.removed`）・変更＝黄（`diff.modified`）。赤と緑を見分けにくい人でも区別できるため。ガター・diff・バッジは形（記号 ＋ / −・削除の三角・バッジの字）でも区別する。例外として、ガターの追加と変更（同じバー）と、俯瞰（ミニマップ・スクロールバー）の git の印 3 種は、同じ形で色だけで分ける——どちらも変化のある位置を示す補助で、一次情報は本文そのものだから（ガターの削除は三角で形も違う）。
  - 使い分け: git の変化の種類（ガター・バッジ・diff の行・印・件数）は `diff.*`、成否・CI・PR の状態・診断は `success` / `danger`、git 以外の注意の黄は `editor.caution` を使う。diff の字に専用の色は持たず、どの行も普通のファイルと同じ構文色で描き、追加・削除は行の地と先頭の ＋ / − で見分ける（VS Code と同じ）。
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

- **選択の示し方**: リスト行の選択は **tint 背景**（`selectionFill`）。タブの選択のみ**前景色反転**（§5.1）。**選択を左バーで示さない**（Completion も例外にしない）。下線・太字による選択弁別も持たない（タブ行の左 3px バーは選択ではなく worktree の識別色で、意味が別）。
- **Tab（セグメント）**: タブ行（高さ 28・padding 上下 3・左右 5（＝gap）・gap 5・地 `tab.rowBg`）の中の器。**面を持つのはグループ（同じ worktree のタブ 2 枚以上の連）だけ**——地 `tab.groupBg` に `worktree.tint` を重ね・radius 4・クリップ、器の**外側**に 1px の `worktree.frame` の枠（幅の取り分に含まれず gap に重なる）、左端に識別色バー 3px（縦いっぱい）、各セルの左に hairline `tab.divider` の区切り線（先頭セルを含む・選択セルでも残る）。1 枚の連は単独タブの器で、地 `tab.segBg`・radius 3 だけを持ち、枠・バー・区切り線を持たない。
- **Tab のセル**: padding 横8・グリフとタイトルの間 6・幅は床40〜上限140（超える名前は末尾省略）。非選択＝地なし（器の地が透ける）・文字 `text.secondary`（idle/dormant/なしも同じ）・状態グリフ 12px（working は stroke 1.6。idle は非表示）。**選択＝地 `text.primary`（前景色反転。区切り線を持つセルでは左 1px を空けて線を残す）・文字 `tab.activeText`・グリフ＝`state.*Inverse`（対テーマ状態色）**、done の check 線のみ `text.primary`。タブ背景を状態色で塗らない。窓が main でない間は反転しない（§5.1）。
- **Palette row**: default＝`text.secondary`（workspace 行の名前＝最優先状態の色）。hover＝`hoverFill`＋`text.primary`。selected＝`selectionFill` 地。dormant＝`Opacity.dormant`。タスク画面の表だけは、選んでいる行も減光する（減光は行の中身だけに掛け、選択の地は満の濃さのまま）——space で完了にした結果を、選んだまま確かめるため。情報行＝`text.muted`・選択不可。そのうち直前の操作が失敗した理由を述べる行だけ `danger`（§3）——中立な補足と同じ弱さで出さない。行= padding 5×10・radius 8。workspace 行の右詰め＝状態別カウントピル（padding 1×7・radius pill・地 tint .12・文字 状態色・グリフ 9px）。
- **Button**: primary（主 CTA）＝塗り `accent.primary`・文字 `on.accent`・radius `md`。secondary＝塗りなし・文字 `accent.primary`・枠 1px `surface.1`・hover で `hoverFill`。disabled＝`Opacity.disabled`。
- **Search field**（端末のスクロールバック検索のバー）: 外枠＝`bg.sunken`＋1px `surface.1`＋radius `md`。focus＝リング `accent.focus`。no-match＝`danger`。件数＝`captionDigit`。
- **Field frame**（エディター面の 1 行の入力欄の枠。ツリーの絞り込みの欄・上のバーのファイル内検索の欄・検索パネルの入力欄が使う）: 左から虫眼鏡（`layout.editorFieldGlyph` 14・stroke 1.4・`text.muted`）・中身・右の添え物（件数やオプションのボタン。無くてよい）を間 `layout.editorFieldGap` 6 で並べ、padding 0 `layout.editorFieldPadTrailing` 4 0 `layout.editorFieldPadLeading` 8。高さは使う側が決める（26 か 28）。地 `surfaceInk` `opacity.editorFieldFill` .055・radius `layout.editorFieldRadius` 7。フォーカスがある間は内側に `accent.primary` `opacity.editorFieldFocus` .55 の枠（`layout.editorFieldFocusStroke` 1.5）。入力・フォーカスの持ち方・キーは使う側が持つ。
- **Focus / active tab**: アクティブタブの端末は 2px 内側リング `accent.focus`。カーソル点滅と併走。
- **Onboarding**: waiting＝`text.muted`。installing＝スピナー（`accent.primary`）。done＝`✓` `success`。failed＝`✗` `danger`＋再試行 secondary。skipped＝`text.muted`・取り消し線。
- **Code view**（エディター面の文書）: 俯瞰（ミニマップ・スクロールバー・上端の影）と強調の地は、寸法を VS Code の既定、色を VS Code Dark Modern / Light Modern の値（§2.1）に揃える。本文 `type.editorCode`・行高 `line.editorCode` 18・上余白 4・素の文字 `editor.text`・役割ごとに `syntax.*`。行番号ガター幅 50・右寄せ・右余白 8・`type.editorLineNumber`・`editor.lineNumber`、その右に git ガター 19、本文は 2 つの右端（最小 69。行番号の桁が増えれば広がる）から始まる。キャレット `accent.bright` 1.5×14。テキスト選択の地は `editor.selection`（焦点が無ければ `editor.selectionInactive`）。地は面の veil（`bg.base` × 実効不透明度）。
  - **git ガター**: 追加の行に `diff.added`、変更の行に `diff.modified` の 3px バー（列の左から 2・radius 1・α .85。続く行のバーは 1 本に繋がる）。削除はその境に `diff.removed`（α .85）の右向き三角 6×6 を中央合わせ（先頭行の上は上端から）。**追加と変更は色だけの区別**（形が同じ）——§3 の例外で、本文そのものが一次情報でガターは補助だから。削除は形も違う。
  - **空白の丸点**: 直径 2・`editor.whitespace`。行頭・行末・2 個以上の連続スペースだけ。選択の地・強調の地の上、字の下に描く（URL 下線も同じ層）。
  - **URL 下線**: ⌘ を押して URL の上にポインタがある間だけ、その URL に 1px・文字と同色・ベースラインの 3 下。指カーソルも同じ間だけ。⌘クリックで既定ブラウザ。
  - **ミニマップ**（スクロールバーの左。幅は VS Code の式で本文の幅から計算し、最大 `layout.editorMinimapMaxWidth` 120）: 1 行 2pt・1 字 1pt・行の間に隙間なし。字は本文フォントを太字の trait にした字形（システムの等幅では Semibold）を 1×2（1x）/ 2×4（2x）デバイス px に縮めたものを構文の色（役割の無い字は `editor.text`）で描き、明るさの係数 dark 12/15・light 50/60。字は左 8 デバイス px から。字と装飾（git の印・一致・語の出現・選択）の全体に不透明度 .9。git の印は x 2 デバイス px・幅 2 デバイス px に `diff.added` / `diff.modified` / `diff.removed`（3 種とも同じ形で色だけの区別。§3 の例外）。検索の一致は `editor.findMatch`、語の出現は `editor.selectionOccurrence`（範囲とその行の α 半分の地）、選択は `editor.selection`。帯は `editor.minimapSlider`（帯の上 `Hover`・ドラッグ中 `Active`）でミニマップの全幅、普段は隠れホバーで現れる。本文が右に続くときは左端の外にぼかし 6 の影（`editor.minimapShadow`）。
  - **横スクロールバー**（本文の区画の下端に重なる、高さ `layout.editorHorizontalScrollbar` 12、行番号の列の右からミニマップの左まで）: 横に続く本文があるときだけ出る。つまみは縦と同じ `editor.scrollbarSlider`（上 `Hover`・ドラッグ中 `Active`）で最小の長さ 20、現れ方と消え方も縦と同じ。印は持たない。
  - **スクロールバー**（本体の右端、幅 `layout.editorScrollbar` 14）: つまみ `editor.scrollbarSlider`（つまみの上 `Hover`・ドラッグ中 `Active`）、最小の長さ 20。下に印——左 1 デバイス px と上 1 デバイス px の縁（`borderInk` .07・light ×1.4）、残りを 3 レーン: 左に git（`diff.*` α .6）、中央に検索の一致 `editor.rulerFind` と語の出現 `editor.rulerOccurrence`、全幅にキャレット（`accent.bright` α .7・高 2）。印の最小の高さ 6。つまみは印の上に重なる。git の 3 種は同じレーン・同じ形で色だけの区別（§3 の例外）。
  - **上端の影**: 先頭の行が上へ隠れている間、本文の上端（本文の幅。ミニマップには掛けない）に `editor.scrollShadow` の内側の影（CSS の `0 6px 6px -6px inset`）。
  - **強調の地**: 行の高さいっぱい・角なし、選択の地の上・文字の下。下から 現在の一致の行全体 `editor.findLine` → 選択文字列の出現 `editor.selectionOccurrence` → 語の出現 `editor.wordOccurrence` → 検索の一致 `editor.findMatch` → 現在の一致 `editor.findMatchCurrent`（不透明）。一致が 1000 件を超えると検索の一致は現在の一致の行の直上へ回る。ファイル内検索の欄は上のバーに置く（Editor bar）。
- **Key cap**（キーの札。見本の kbd）: 高さと最小幅 `layout.editorKeyCap` 18・padding 0 `layout.editorKeyCapPadX` 4・radius `layout.editorKeyCapRadius` 5・地 `surfaceInk` `opacity.editorKeyCap` .07。中身は字（`type.editorKeyCap`）か印（`layout.editorKeyCapGlyph` 12）で、色は `text.secondary`。地と中身の色は使う側が替えてよい。AppKit の描画も同じトークンを読む。
- **Text button**（字のボタン。見本の `.gb`）: 高さ `layout.editorTextButton` 22・padding 0 `layout.editorTextButtonPadX` 7・radius `layout.editorTextButtonRadius` 6。字は `type.editorTextButton`。字の前に印（任意。`layout.editorTextButtonGlyph` 14・色は字と同じ・間 `layout.editorTextButtonGap` 5）、字の後ろに Key cap（任意。間 `layout.editorTextButtonKeyGap` 11。色は Key cap の既定）。幅は中身で決まり、縮まず・折り返さず・省略しない。素の姿は地なし・字 `text.secondary`、ホバーで地 `surfaceInk` `opacity.editorTextButtonFill` .08・字 `text.primary`。地つきの変種（見本の `.gb.s`）は地 .08・字 `text.primary`、ホバーで地 `opacity.editorTextButtonFillHover` .12。押せない姿は全体を `Opacity.disabled` に薄め、ホバーしても姿を変えない。押してもフォーカスを取らない。ツールチップと VoiceOver の名前は字（別の文言を渡したときはその文言）。
- **Large button**（大きい字のボタン。見本の `.gb.lg`・`.pb`）: 高さ `layout.editorLargeButton` 30・padding 0 `layout.editorLargeButtonPadX` 14・radius `layout.editorLargeButtonRadius` 8。地は 4 種類——accent（地 `accent.primary`・字 `type.editorEmptyButton` `on.accent`）・中立（地 `surfaceInk` `opacity.editorTextButtonFill` .08・字 `type.editorEmptyText` `text.primary`）・danger（地 `danger`・字 `type.editorEmptyButton` `editor.onDanger`）・色の指定（地はその色・字 `type.editorEmptyButton` `on.accent`）。字の後ろに Key cap（任意。間 `layout.editorTextButtonKeyGap` 11）。色の付いた地では、Key cap の地を黒 `opacity.editorLargeButtonKeyCap` .16・印を字と同じ色にする。押せない姿は全体を `Opacity.disabled` に薄める。押してもフォーカスを取らない。ツールチップと VoiceOver の名前は字（別の文言を渡したときはその文言）。本体の空のときの表示のボタンはこの部品。
- **Editor bar**（エディター面の上端・全幅 `layout.editorBar` 36。下端の 1px `borderInk` .07〔light ×1.4〕を含む。→ [editor/shell](../spec/editor/shell.md)）: 地は面の veil（バーの分とバーより下の分を別に塗る）。左 padding 8・右 12・gap 6 で、左から次を並べる。**左の列の開閉**は 26 角・radius 7・印 14（`M2.5 3.5h11v9h-11zM6 3.5v9`・stroke 1.4）で、開いている間は押された姿（地 `surfaceInk` .08・印 `text.primary`）、閉じている間は地なし・印 `text.secondary`。**画面の切り替え**は溝（padding 2・項目の間 2・radius 9・地 `editor.barGroove` に `editor.barInset` の内側の影〔ぼかし 1・下 1〕・枠 1px `surfaceInk` .05）に `Changes`・`PR`・`Files` の 3 項目（高さ 24・padding 0 11・radius 7・字と添え字の間 6）。字は `type.editorBarSwitch`、添え字（件数・`#番号`）は `type.editorBarCount`。選んでいる項目は地 `surfaceInk` .11 に上縁の明かり（`surfaceInk` .10 の内側の影・下 1）と下の影（`editor.barInset`・ぼかし 1・下 1）を付けて浮かせ、字 `text.primary`・添え字 `accent.bright`。選んでいない項目は地なし・字 `text.secondary`・添え字 `text.muted`。件数は 1000 以上で「999+」。**「⌥ 端末を表示」**は右寄せ・gap 7 で、⌥ の Key cap（印）と字 `type.editorBarHint` `text.muted`。押せない。透かしている間は、札を地 `accent.primary`・印 `on.accent`、字を `text.primary` にする（押している間の姿）。**今の項目のボタン**は画面の切り替えの右に、区切り線（1×16・`borderInk` .15〔light ×1.4〕・左右 6）の後に置く。高さ `layout.editorItemButton` 26・padding 0 `layout.editorItemButtonPadX` 8・radius `layout.editorItemButtonRadius` 7・中の間 `layout.editorItemButtonGap` 6・地 `surfaceInk` `opacity.editorItemButtonFill` .06・枠 1px `surfaceInk` `opacity.editorItemButtonBorder` .05、一覧を開いている間は地 `opacity.editorItemButtonOpen` .11。末尾に ▾（`M4 6.5L8 10l4-3.5`・`layout.editorItemButtonCaret` 14・`text.muted`）。Files の中身は種別チップ 14・親のパス `type.editorItemButtonPath` `text.muted`・名前 `type.editorItemButtonName` `text.primary`（仮の文書は斜体）・印の丸（`layout.editorItemDot` 7。未保存は `text.primary`、ディスクが変わったは `editor.caution`）。Changes・PR の中身は状態の字（`type.editorDiffHeaderBadge`・幅 `layout.editorDiffHeaderBadge` 12・色はエクスプローラーの git の字と同じ）と名前 `type.editorItemButtonName` `text.primary`。仮の文書のときは、ボタンの右に **Tag**「プレビュー」と、Text button の地つきの変種「開いたままにする」（検索結果の列に焦点がある間だけ、後ろに ↵ の Key cap）を置く。画面ごとの部品は、今の項目の後ろ（中ほど・左寄せ）と「⌥ 端末を表示」の後ろ（右端・右寄せ）に並べる。左寄せと右寄せの間は、幅 0 の伸びる隙間（隣とは gap 6 で離れる）。共通の部品は次のとおり。**中ほどの札**は高さ `layout.editorBarChip` 26・radius `layout.editorBarChipRadius` 7・padding 0 `layout.editorBarChipPadX` 8・中の間 `layout.editorBarChipGap` 6・字 `type.editorBarChip` `text.primary`・地なし。地つきの変種（同期）は地 `surfaceInk` `opacity.editorBarChipFill` .08・padding 0 `layout.editorBarChipFilledPadX` 9・中の間 `layout.editorBarChipFilledGap` 7・字 `type.editorBarChipFilled`。押せない姿は全体を `Opacity.disabled` に薄める。押す働きを持たない表示だけの札もあり、ボタンとしては読まれず、押下も受けない。**アイコンのボタン**は `layout.editorBarIconButton` 26 角・radius `layout.editorBarIconButtonRadius` 7・印 `layout.editorBarIconGlyph` 14・印 `text.secondary`。押された姿は地 `surfaceInk` `opacity.editorBarIconPressed` .08・印 `text.primary`（左の列の開閉はこの部品）。**右端の主な操作のボタン**は左に `layout.editorBarActionLead` 12 の空き、高さ `layout.editorBarAction` 26・radius `layout.editorBarActionRadius` 7・中の間 `layout.editorBarActionGap` 7・padding 0 `layout.editorBarActionPadTrailing` 6 0 `layout.editorBarActionPadLeading` 11・地 `accent.primary` `opacity.editorBarActionFill` .24・枠 1px `accent.primary` `opacity.editorBarActionBorder` .6・名前 `type.editorBarAction` `text.primary`・末尾の ▾ は `accent.bright`。開いている間は地 `opacity.editorBarActionOpen` .36、押せない姿は全体を `Opacity.disabled` に薄める。VoiceOver の名前は、ツールチップと別の文言を渡せる。名前の後ろに、いつも出す添え（レビューの未送信の数）と、幅が足りなければ出さない添え書き（コミットの「ステージ済み +125 −3」）を置ける。区切り線は、その後ろに続く部品の一部として、その部品の中に置く（部品が落ちれば一緒に落ちる）。Files の中ほどには、⌘F で出す**ファイル内検索の欄**を区切り線の後に置く: Field frame の高さ `layout.editorBarFind` 26、本来の幅 `layout.editorBarFindWidth` 290（狭ければ `layout.editorBarFindMinWidth` 180 まで縮む）。入力 `type.editorBarFind` `text.primary`・プレースホルダ「ファイル内を検索」`text.muted`（変換中は出さない）。右の添え物は件数 `type.editorBarFindCount` `text.muted`（一致なしは `danger`）・右に `layout.editorBarFindCountTrailing` 6。フォーカスが無い間は枠を付けない。

幅が足りなければ、部品は決まった順に譲る（まるごと出さないか、狭い姿に替わる）——先に譲るものから「⌥ 端末を表示」・ファイル内検索の欄の幅・右端のボタンの添え書き・中ほどの札の広い姿・今の項目のボタンの広い姿（親のパス、その次に名前の全体）・中ほどの札まるごと。ある部品が収まらなくても、ほかの部品は幅が余れば出る。そのため、中ほどの札まるごとが落ちると、空いた幅で、先に譲っていた部品が広い姿に戻ることがある。落とした部品は描かれず、押下も受けない。今の項目の名前は、幅が在る間は中ほどを省き（先頭と末尾が残る）、中ほどの札の名前（ブランチ名）は末尾を省き（先頭が残る）、どちらもそれより狭ければ先頭の字と「…」にする。今の項目のボタンの名前は、先頭の 1 字と「…」より狭くならない——中ほどの札が出ているのに、今の項目の名前が 1 字も読めない姿を作らないため（中ほどの札の名前〔ブランチ名〕は、先頭 `layout.editorBarChipReadablePrefix` 4 字と「…」より狭くならない）。開閉・切り替え・今の項目のボタン・Tag・「開いたままにする」・ファイル内検索の欄・右端の主な操作のボタンは落とさない。落とせない部品だけで幅を越えれば、右端が切れる。
- **Tag**（状態を示す札。見本の `.tg`）: 字 `type.editorTag` `text.secondary`・padding `layout.editorTagPadY` 1 `layout.editorTagPadX` 6・radius `layout.editorTagRadius` 4・枠 1px `surfaceInk` `opacity.editorTag` .2。上のバーの「プレビュー」と一覧の行の「現在」「プレビュー」。AppKit の描画も同じトークンを読む。
- **Item list**（今の項目のボタンに付いて浮く一覧。見本の `.ofl`。→ [editor/shell](../spec/editor/shell.md) の開いているファイルの一覧）: ボタンの左下（上端は上のバーの下端）に、幅 `layout.editorItemListWidth` 420（面が狭ければ面の幅）。地・枠・影は popup の段のガラス（`Glass.surface(.popup)`・`Glass.border(.popup)`・elevation popup・radius 10）。内側の padding `layout.editorItemListPad` 5。行は高さ `layout.editorItemListRow` 26・padding 0 `layout.editorItemListRowPadX` 8・間 `layout.editorItemListRowGap` 8 で、選択の地 `selectionFill`・ホバーの地 `surfaceInk` `opacity.editorItemListHover` .045〔light ×0.6〕、どちらも radius `layout.editorItemListRowRadius` 6。**見出しの行**は題 `type.editorItemListHeading` `text.muted`・間 6・数 `type.editorItemListCount` `text.muted`・右端に Key cap（字。開いているファイルの一覧だけ）。**ファイルの行**は種別チップ 14・名前 `type.editorItemListName` `text.primary`（仮の文書は斜体）・ディレクトリ `type.editorItemListDirectory` `text.muted`（頭から省く）・Tag・右に印の枠 `layout.editorItemListMark` 16（× は `layout.editorItemListMarkGlyph` 10・`text.muted`、枠のホバーで地 `opacity.editorItemListMarkHover` .10・radius 4・× は `editor.text`。丸は Editor bar と同じ色）と状態の字の列 `layout.editorItemListBadge` 12（`type.editorItemListBadge`・色はエクスプローラーの git の字と同じ）。変更ファイルの一覧の行は印を出さず（枠の幅は空けたまま）、PR の確認済みのファイルは名前を `text.muted` にする。**操作の行**は padding 0 `layout.editorItemListActionPadX` 10・字 `type.editorItemListAction` `text.primary`・右端に Key cap（任意。見出しの行の Key cap と同じ描き方で、題は Key cap の手前で省く）。選べない操作の行は、字と Key cap を `Opacity.disabled` に薄め、ホバーの地を付けない。**下の案内**は高さ `layout.editorItemListFooter` 34（上の空き 5・線 1px `borderInk` .07・上下 padding 7 3）に Key cap と字 `type.editorItemListHint` `text.muted`（札と字の間 5・案内の間 `layout.editorItemListHintGap` 14）。高さは行の数に合わせ、面の下端から `layout.editorItemListBottom` 12 を残して頭打ちにする。
- **Editor dock**（上のバーの右下の置き場。見本の `.cpd`・`.rvd`）: バーの下端から `layout.editorDockTop` 6・面の右端から `layout.editorDockTrailing` 12 の所に、上からポップアップと札を右寄せ・間 `layout.editorDockGap` 6 で縦に並べる。置き場の幅は `layout.editorDockWidth` 620（面が狭ければ面の幅 − 24）、高さは面の下端から `layout.editorDockBottom` 12 を残すまで。札は、本体の上端に帯（差分の見出し `layout.editorDiffHeader` 32）があれば、その下端から 6 の所より上には置かない（帯の文とボタンを覆わない。ポップアップはバーの下端から 6 のまま、開いている間は札がその下に並ぶ）。札は自分の高さを取り、ポップアップは残りの高さを上限に縮む。バーより下の層に置くので、⌥ の透かしで一緒に見えなくなる。**ポップアップの地**は幅 `layout.editorPopupWidth` 520（置き場が狭ければ置き場の幅）、popup の段のガラス・radius `layout.editorPopupRadius` 14。色を渡すと、縁 1px（色 `opacity.editorPopupTintBorder` .5）・上端から `layout.editorPopupTintHeight` 132 までの縦のグラデーション（色 `opacity.editorPopupTintTop` .17 → 0）・外の光（色 `opacity.editorPopupTintGlow` .13・radius `layout.editorPopupGlow` 22）が付く。**札の地**は popup の段のガラス・radius `layout.editorCardRadius` 10・最小の高さ `layout.editorCardMinHeight` 34。**失敗の札**は札の地に縁 1px `danger` `opacity.editorFailureBorder` .5、文は `type.editorDockCard` `danger`（行高 1.55・padding `layout.editorCardPadY` 8 `layout.editorCardPadX` 14・幅の上限 620 で折り返し、字を選択できる）、右上に ×（枠 `layout.editorCardClose` 20・印 `layout.editorCardCloseGlyph` 10・`text.muted`、周りの空き `layout.editorCardClosePad` 7。ホバーで地 `surfaceInk` `opacity.editorCardCloseHover` .10・radius `layout.editorCardCloseRadius` 4・印 `editor.text`）。**実行中の札**（Changes。見本の `.dks.run`）は札の地に、padding 0 `layout.editorRunningPadTrailing` 6 0 `layout.editorRunningPadLeading` 14・間 `layout.editorRunningGap` 10 で、操作名 `type.editorDockCard` `text.primary`、進捗の行 `type.editorRunningProgress` `text.muted`（列の幅 `layout.editorRunningProgressWidth` 420・末尾省略。リモートと話す段だけ）、Text button の地つきの変種「止める」。上端に Search panel と同じ流れる線（高さ `layout.editorProgressLine` 2・角丸に掛からないよう左右を `layout.editorCardRadius` 10 だけ空ける）。幅は、進捗の行が無ければ中身なり、在れば行の字数に依らず進捗の列を 420 に取った幅（届くたびに字数が変わる行で、右寄せの札の左端が揺れない）。置き場が狭ければ進捗の列から縮む。札はフォーカスを取らず、出入りに動きを付けない。置き場が押下を受けるのは、見えている物（ポップアップの地・札の地・中身が地の外に並べた物）の枠の中だけで、何も無い所の押下は下の本体へ届く。
- **Panel header**（左の列のパネルの頭。Source control panel・PR panel が使う）: 高さ `layout.editorPanelHeader` 28。題 `type.editorPanelTitle`・`text.muted`、右端にツール（Explorer の上の行と同じ 22 角のアイコンボタン・間 2）。
- **Changes bar parts**（Changes の画面の上のバーの部品。git 管理下と分かっている間だけ。→ [editor/source-control](../spec/editor/source-control.md)）: **ブランチ名の札**は表示だけの中ほどの札（素の姿。前に区切り線）に、ブランチの印 `layout.editorBranchGlyph` 12 `text.primary` と名前（末尾を省略し、先頭の `layout.editorBarChipReadablePrefix` 4 字と「…」より縮めない）。**同期のボタン**は中ほどの札の地つきの変種に「同期」と、先行・遅れの数（上向き・下向きの矢印 12 `text.secondary` と数 `type.editorSyncCount` `text.secondary`、矢印と数の間 `layout.editorSyncArrowGap` 1、↑ と ↓ の組の間 7。0 の側は出さない）、または「ブランチを公開」。ネット操作の間と、upstream がリモートに無い間（「同期」の字だけ）は押せない姿（disabled）。**「コミット」**は右端の主な操作のボタンで、譲る添え書きに「ステージ済み」（`type.editorItemListHint` `text.secondary`）と、間 6 で追加の数 `diff.added`・削除の数 `diff.removed`（どちらも `type.editorBarCount`。＋・− の記号でも区別する。0 の側は出さない）。押せない姿は使わない。
- **Commit popup**（Changes のコミットのポップアップ。見本の `.cpo`。置き場とポップアップの地は Editor dock）: 地は色なし。行（padding `layout.editorCommitRowPad` 8 8 8 `layout.editorCommitRowPadLeading` 14・間 `layout.editorCommitRowGap` 9・上揃え）に、記号「❯」（`type.editorCommitPrompt` `accent.bright`・高さ 30）、メッセージ欄（`type.editorCommitMessage` `text.primary`・行の高さ `layout.editorCommitMessageLine` 20・1 行のときの高さ `layout.editorCommitMessage` 30・左右の余白なし・地と枠なし・空のときの文「メッセージ」`editor.tertiary`。10 行まで伸び、その先は中でスクロール）、分割ボタン（高さ `layout.editorLargeButton` 30・radius `layout.editorLargeButtonRadius` 8・地 `accent.primary`。左「コミット」`type.editorEmptyButton` `on.accent` ＋ Key cap ↵〔地 黒 `opacity.editorLargeButtonKeyCap` .16・字 `on.accent`・字との間 `layout.editorTextButtonKeyGap` 11〕、padding 0 `layout.editorCommitButtonPadTrailing` 10 0 `layout.editorCommitButtonPadLeading` 12。区切り 1px 黒 `opacity.editorCommitDivider` .22。右 ▾ 14 `on.accent`・padding 0 `layout.editorCommitCaretPadX` 7）。「コミット」が押せない姿は、ボタン全体の地を `surfaceInk` `opacity.editorCommitNeutral` .09・区切りを `surfaceInk` `opacity.editorCommitNeutralDivider` .12・▾ を `text.primary` にし、左の字と Key cap を `Opacity.disabled`。**赤い行**（コミットの操作の失敗）: 上に 1px `danger` `opacity.editorCommitFailureLine` .3、地 `danger` `opacity.editorCommitFailureGround` .1（下の角だけ radius 14）、padding `layout.editorCommitFailurePadTop` 9 `layout.editorCommitFailurePadX` 14 `layout.editorCommitFailurePadBottom` 10・間 `layout.editorCommitFailureGap` 8 で、警告の印 14 `danger`（上 `layout.editorCommitFailureGlyphTop` 2）と文 `type.editorDockCard` `danger`（行高 1.55・字を選択できる）。**▾ のメニュー**は地のすぐ下（間 `layout.editorCommitMenuGap` 6）に右寄せ・幅 `layout.editorCommitMenuWidth` 250、popup の段のガラス・radius `layout.editorCommitMenuRadius` 10・padding `layout.editorItemListPad` 5 に、Item list の操作の行（高さ 26・ホバーと選択の地も Item list と同じ。見本の行 28・紫のホバーとは違う）。押せない項目は行の字と Key cap を `Opacity.disabled`。「コミットしてプッシュ」の右に Key cap「⌘↵」（見出しの行の Key cap と同じ描き方・右の余白は操作の行と同じ 10）。下の案内は出さない。
- **Editor confirm**（面の中の確認。破棄の確認。見本の `.veil`・`.sht`）: 面の全体（上のバーを含む）に幕 `editor.confirmVeil`。ダイアログは幅 `layout.editorConfirmWidth` 430（面が狭ければ左右に `layout.editorConfirmInset` 12 を残す）・左右の中央・面の上端から `layout.editorConfirmTop` 150、popup の段のガラス・radius `layout.editorConfirmRadius` 14、padding `layout.editorConfirmPadTop` 18 `layout.editorConfirmPadX` 18 `layout.editorConfirmPadBottom` 14。題 `type.editorConfirmTitle` `text.primary`（行高 1.45）、本文 `type.editorConfirmMessage` `text.secondary`（行高 1.6・上 `layout.editorConfirmMessageGap` 6）、ボタン列（上 `layout.editorConfirmButtonsGap` 16・右寄せ・間 `layout.editorConfirmButtonGap` 8）に Large button の中立「キャンセル」＋ Key cap「esc」と、danger の確定。行高の余りは、行の間と 1 行目の上・最後の行の下に半分ずつ置く。見本は幕を上のバーだけに掛けるが、後ろを押せるように見えるので面の全体に掛ける。⌥ の透かしの間は幕ごと見えなくなる。VoiceOver ではダイアログの名前（破棄なら「変更を破棄」）を読み、モーダルとして扱う——出ている間は、幕の裏（上のバー・本体・左の列）を VoiceOver から隠す。
- **Explorer**（Files の画面の左の列。既定 263 ＋右の 1px・ドラッグで可変）: 地 `sunkInk` .45・右 1px `borderInk` .07。ぼかしは持たない（面内の in-flow 面は窓のブラーに委ねる。§1-6）。題の行を持たず、上端は上の行（padding `layout.editorTreeTopPad` 8・高さ `layout.editorTreeField` 26）: 左に絞り込みの欄（Field frame の高さ 26・入力 `type.editorTreeFilter` `text.primary`・プレースホルダ「ファイルを絞り込む」`text.muted`。右のツールとの間 `layout.editorTreeFieldGap` 4）、右に 22 角のアイコンボタン 3 つ（間 2・radius 4・hover 地 `surfaceInk` .08 ＋ 文字 `editor.text`、既定の文字 `text.muted`）。結果を 0.3 秒より長く待つ間は、上の行の下端に Search panel と同じ流れる線。上の行の下に、絞り込みの文（`type.editorSearchNote` `editor.tertiary`・padding 0 12 8）。一覧は左右の内側 `layout.editorTreeInset` 6。ツリー行 `layout.editorRow` 24・padding 0 `layout.editorTreeRowPadX` 8: 深さぶんの字下げの線（1 段 `layout.editorTreeGuide` 14 の中央に 1px `borderInk` `opacity.editorTreeGuide` .15。選択の行とその祖先のフォルダの行は `accent.primary`）・ディレクトリはシェブロン `layout.editorTreeChevron` 14（`editor.icon`）と名前（左 `layout.editorTreeNameGap` 4・`type.editorTreeFolder`。連なりは前の段 `text.muted`・最後の段 `text.secondary`、頭から省略）、ファイルは種別チップ 14（右 `layout.editorTreeChipGap` 6）と名前（`type.editorTreeRow`。`text.secondary`、開いている行と選択の行は `text.primary`。git の状態で塗らない）。開いている文書の行は、名前の右に印の枠（16 角・右 6）: × は 10（`m4 4 8 8M12 4l-8 8`・stroke 1.4）`text.muted`（hover で枠に地 `surfaceInk` .10〔light ×0.6〕・× `text.primary`）、丸は `layout.editorItemDot` 7（未保存 `text.primary`・ディスクが変わった `editor.caution`。枠の hover で × に替わる）。右端に git の字（`type.editorTreeBadge`・幅 `layout.editorTreeBadge` 12・中央。M `diff.modified` / A・U `diff.added` / C `conflict`）。ディレクトリ行は字を持たない。行の地は上下 `layout.editorTreeRowGroundInset` 1 を空けた radius `layout.editorTreeRowRadius` 6: 選択 `selectionFill`、開いている行は `surfaceInk` `opacity.editorTreeOpen` .06 と 1px の枠 `surfaceInk` `opacity.editorTreeOpenBorder` .05、hover は `surfaceInk` `opacity.editorTreeHover` .045（light ×0.6）。ツリーが溢れたときのつまみ: 右端・幅 `layout.editorSidebarScrollbar` 10・角なしの矩形・`editor.scrollbarSlider`（つまみの上 `Hover`・ドラッグ中 `Active`）・最小の長さ 20・トラックの地と枠なし。一覧の上にポインタがある間・スクロール中・ドラッグ中だけ見え、出方は本体のスクロールバーと同じ（`editorSliderFadeIn` / `editorScrollbarHideDelay` / `editorScrollbarFadeOut`）。ツリーの末尾（最後の行の下）に行 1 つ分（`layout.editorRow` 24）の空き。
- **Search panel**（Files の画面の左の列のもう 1 つのパネル。器は Explorer と同じ部品、見出しは検索パネルのもの）: 見出し `layout.editorSearchHeader` 38（padding 0 `layout.editorSearchHeaderTrailing` 8 0 `layout.editorSearchHeaderLeading` 12・部品の間 `layout.editorSearchHeaderGap` 6）。左から、題 `type.editorSearchTitle` `text.primary`・伸びる余白・すべて折りたたむ／すべて展開（Explorer の上の行のツールと同じ 22 角のアイコンのボタン）・Text button「ツリーに戻る」＋ Key cap「esc」。2 秒を超えた検索の間は、Text button の字が「止める」に替わる。見出しは Text button の幅を 2 つの字の長い方に合わせて確保して Text button を右へ寄せ、字が替わっても Key cap と、すべて折りたたむ／すべて展開のボタンの位置を動かさない（「止める」の間は、そのボタンと字の間が広く空く）。幅が足りなければ Key cap を出さず、それでも足りなければ見出しの中身が右端から切れる。検索中は見出しの下端に `accent.primary` の細い帯が左から右へ流れる。入力欄は Field frame の高さ 28（外側 padding 0 8 `layout.editorSearchFieldBottom` 6・入力 `type.editorSearchField` `text.primary`・プレースホルダ `editor.tertiary`〔変換中は出さない〕）。右の添え物はオプション 3 つ（間 6）。オプション 20 角 radius 3・`type.editorSearchOption`・`text.muted`（ab は下線）、hover 地 `surfaceInk` .08、有効は地 `accent.primary` .25・枠 `accent.primary` .55・文字 `accent.bright`。エラーの文は入力欄の下に `danger`。件数の文はその下・結果の列の上（padding `layout.editorSearchSummaryTop` 4 12 8・`type.editorSearchNote`・`editor.tertiary`）。まとまりの見出し 20（padding 0 12・gap 6: シェブロン 10 `text.muted`〔畳むと右向き〕・種別チップ 14・名前 `type.editorSearchFile` `text.primary`・ディレクトリ `type.editorSearchDirectory` `editor.tertiary`〔長ければ頭を省略〕・右端の件数バッジ 最小 18×16 capsule・地 `surfaceInk` .10・`type.editorSearchCount` `text.secondary`）。一致の行 20（左 40・右 12・`type.editorSearchMatch`: 前 `editor.tertiary`・一致は地 `editor.caution` .30 radius 2 ＋ `text.primary`・後ろ `text.muted`。狭ければ後ろ → 前の頭 → 一致の順に省略し、前と後ろには省略記号 1 つぶんを残す）。選択は `selectionFill`。結果の列は、見えている行だけを持って使い回す自前の列（AppKit）で描く——行は最大 2 万になり、行の数が変わっても手間が行の総数に依らないようにするため（行の少ないエクスプローラーのツリーは SwiftUI のまま）。行の高さは見出しも一致も 1 つ（VS Code の検索の結果と同じ）。結果のどちらの列も、つまみと末尾の 1 行分の空きは Explorer と同じ。
- **Source control panel**（Changes の画面の左の列のパネル。器は Explorer と同じ部品、ヘッダーは Panel header）: ヘッダーは題だけ。見出し 22（親「ソース管理」とグラフの枠は padding 0 8 0 4、子の区分は `editorScmIndent` だけ字下げした 0 12 0 12・シェブロン 16 `editor.icon`・`type.editorScmSection` `editor.text`・hover 地 `surfaceInk` .04）。親の中に子の区分が入り、親を畳めば全部隠れる。変更が無ければ、子の区分の代わりに Empty state の左の列の一言「変更なし」。右端のツール 20 角 radius 4・間 `editorScmToolGap` 1（親「ソース管理」の … はプル / プッシュ / フェッチ の OS のメニュー）・印 13・`text.muted`、hover 地 `surfaceInk` .08 ＋ `editor.text`、押せない姿は不透明度 .35。子の区分の件数バッジは最小 18×16 capsule・地 `accent.primary` .35・`type.editorScmCount` `text.primary`、一括操作のボタンはその左（件数との間 4・ボタンどうしの間は右端のツールと同じ 1。姿は右端のツールと同じで、押せない姿も `text.muted` .35）。ファイル行 22（padding 0 12 0 28——子の区分の字下げぶん右で、種別チップが子の題の真下に揃う・gap 6: 種別チップ 16・名前 `type.editorScmFile`〔色は印に従う〕・ディレクトリ `type.editorScmDirectory` `editor.tertiary` 末尾省略〔右のボタンとの間は伸びる余白の両側の gap で 12〕・右端に行のボタン 18〔間 2・radius 3・印 13 `editor.text`・hover 地 `surfaceInk` .10・押せない姿は `editor.text` .3〕と印 `type.editorBadge`）。行のボタンはポインタに依らず全部の行に出す。hover 地 `surfaceInk` .045、選択 `selectionFill`。グラフの枠: 上端に幅いっぱいの区切り線 1px `borderInk` .07（見出しの上端に重ねる）、見出し「グラフ」（hover の地は見出しの 22 にだけ付き、選択の地は持たない）、グラフの列。親とグラフの枠の境目の当たりは 4（`editorSidebarHandle`。上下の矢印のポインタ）。ブランチの行 22（枠・地・hover を持たない。padding 0 12 0 20・gap 6: ブランチの印 9 `accent.bright` を点の列 16 の中央に・名前と先行/遅れ `type.editorScmBranch` をコミットの題の左端から〔名前 `editor.text`・数 `editor.tertiary`。狭ければ名前を優先し、数を末尾から省く〕）。コミットの行 22（padding 0 12 0 20・gap 6: 点の列 16〔未 push は 7 の塗り `accent.bright` と 2 の輪 `bg.base`、push 済みは 7 の中抜き 1.5 `editor.tertiary`〕・縦の線 1px `borderInk` .12〔左 27、先頭と末尾の行は端を 8 空ける〕・題 `type.editorScmCommit`〔未 push `editor.text`・push 済み `text.muted`。札との間は伸びる余白の両側の gap で 12、札が無ければ右端の padding との間 6〕・右端に ref の札 15〔radius 3・padding 0 5・枠 1px・ブランチの印 8 と間 3・`type.editorScmRef`、local は字 `accent.bright`・地 `accent.primary` .18・枠 `accent.primary` .4、remote は字 `text.muted`・地 `surfaceInk` .06・枠 `borderInk` .14。札どうしの間 4〕）。コミットの行は hover の地を持たない（押せない）。「さらに表示」22（左 42・`type.editorScmMore` `text.muted`、hover で `editor.text`）。変更の列とグラフの列は Search panel と同じ自前の列（AppKit）で、それぞれ別にスクロールする。行のボタン（＋・−・未追跡の破棄）を押した後、ポインタが列の上に居る間は次の行をポインタの下に留める。上へは列の先頭が見えるまでしか送らず（列の上に空きを作らない）、下は送りきれなければ一時の空きを足す（ポインタが出る・ホイール・つまみ・キーで動かすと消える）。ポインタが押したボタンの枠の中に居る間、その枠の中の押下は留めている行の同じボタンにだけ届く（列の外のものにも届かない）。どちらの列も、つまみと末尾の 1 行分の空きは Explorer と同じ。git 管理外の一言は Empty state の左の列の一言。
- **PR panel**（PR の画面の左の列のパネル。器は Explorer と同じ部品、ヘッダーは Panel header。→ [editor/pull-request-panel](../spec/editor/pull-request-panel.md)）: ヘッダーは題だけ。**頭**（padding 2 14 10・下 1px `borderInk` .07）: PR の印 15（`success`。ドラフトは `text.muted`）と題の間 8、題 `type.editorPrTitle` 13・行高 1.4・`text.primary` に番号 `text.muted` を続ける。その 5 下に 作者（`text.muted`）· `head → base`（`type.editorPrMeta` 10.5 mono・`editor.tertiary`・gap 6・末尾省略）。**帯**（頭の 10 下・1 行なら高さ `editorPrBand` 24・padding 0 8・radius 3・地は色の .10・`type.editorPrBand` 11・gap 6）: 一致はレ点 12 stroke 1.6 と `success`、未 push・未取得・数えない違いは `editor.caution`（成否の色は §3 の success に揃え、ずれは注意の黄にする）。文は省かず、幅に収まらなければ折り返して帯が伸び、レ点は 1 行目の高さの中央に揃える。収まらなければ末尾省略。**列**は Source control panel と同じ自前の列（AppKit）で、行 22。説明は列の頭（見出し 22 は区分の見出しと同じ・本文 padding 0 14 8 20・`type.editorPrDescription` 11.5・行高 1.6・`editor.prose`・3 行で末尾省略）。区分の見出しは Source control panel の親の見出しと同じ（padding 0 12 0 4・シェブロン 16・`type.editorScmSection`）。コミットの見出しの右端に件数のバッジ（最小 18×16 capsule・地 `surfaceInk` .10・`type.editorScmCount` `text.secondary`）、変更ファイルの見出しの右端に「N/M 確認済み」（`type.editorPrCount` 10.5 mono・`text.muted`）とツリー表示・リスト表示（`editorPrViewToggle` 18 角・間 1・radius 3・印 13。選んでいる側は地 `surfaceInk` .10・印 `text.primary`、そうでない側は `editor.tertiary` で hover に地）。コミットの行（padding 0 12 0 20・gap 6: 点の列 16 に 7 の塗り `accent.bright`・題 `type.editorScmCommit` `editor.text` 末尾省略・右端に短い sha `type.editorPrCount` `editor.tertiary`。hover の地を持たない）。「古いコミット N 件は表示していません」の行（左 20・`type.editorScmDirectory` `editor.tertiary`）。フォルダ・ファイルの行（padding 0 12・gap 6・hover 地 `surfaceInk` .045・選択 `selectionFill`）: 確認済みのチェック `editorPrCheckbox` 14（radius 3。付いた姿は地と枠 `accent.primary` にレ点 10 stroke 2.2 `accent.checkStroke`、一部は .7 に薄めて横線 6×2、空は地 `sunkInk` .25・枠 1px `borderInk` .22）・字下げの線（1 段 `editorPrGuide` 8 の右端に 1px `borderInk` .08、その後 `editorPrGuideGap` 6 と行の gap 6）・フォルダはシェブロン 16・名前 `type.editorScmFile` `editor.text`・右端に「済/全」`type.editorPrCount` `editor.tertiary`、ファイルは種別チップ 16・名前 `type.editorScmFile`（印の色）・リストならディレクトリ `type.editorScmDirectory` `editor.tertiary`・右端に印 `type.editorBadge`（追加 A `diff.added`・それ以外 M `diff.modified`）。確認済みのファイルの行と、配下が全部確認済みのフォルダの行は、中身を不透明度 .55 に薄める。選択の地はほかの列と同じ `selectionFill`。PR が無い・表示できない・中身の最初の読みが失敗したときは、Empty state の左の列の一言（作成と再読込のボタンは本体の Empty state に出す）。
- **PR comments**（PR の diff のスレッド。→ [editor/pull-request-comments](../spec/editor/pull-request-comments.md)）: **スレッドの箱**は本文の区画の左端から（右 16・上 4・下 8 の空き）、radius 6・地 `editor.prThreadGround`（パネル面の地 .85 の半透明塗り）・枠 1px `editor.prThreadBorder`（accent .35）・影 0 10 30 `editor.prThreadShadow`。**頭**は枠の内側に 26 と下縁 1px `borderInk` .08、地 `editor.prThreadHead`（accent .08）、上 2 角だけ radius 5、padding 0 12・gap 8・`type.editorPrThreadHead` 11——左に「行 N」`editor.text`、右から「折りたたむ / 展開」「解決 / 解決を取り消す」（`text.muted`、hover `editor.text`）と状態（未送信は点 6＋`type.editorPrThreadStatus` 10.5 mono `editor.caution`、解決済みは `text.muted` で点なし）。畳んだ姿は頭の帯だけで 4 角とも丸く、「行 N」の後に最初のコメントの書いた人と本文の先頭 1 行（`text.muted`・末尾省略）。**コメントの列**は padding 10 12・件の間 12: 頭文字の丸 20（地 `editor.ghost`・`type.editorPrThreadAvatar` 10 semibold `text.primary`）と中身の間 10、メタの行（11・行高 1.6・gap 6: 書いた人 `type.editorPrThreadAuthor` `text.primary`・相対時刻 `editor.tertiary`・未送信の札 字 10 `editor.caution`・枠 1px caution .4・radius 3）、本文 `type.editorPrThreadBody` 12・行高 1.6・`editor.text`（インラインコード mono 12 `accent.bright`・地 `editor.prInlineCode`（accent .12）・radius 3・左右 4／リンク `accent.bright`／コードブロック mono 12・地 `sunkInk` .35・radius 4・padding 8／箇条書き字下げ 16・印 `text.muted`（番号は右揃えで、本文との間 6。最も広い番号と間 6 が 16 を超える箇条書きは、その幅だけ字下げする）／引用は左に線 2 `borderInk` .12 と空き 8・字 `text.muted`／段の間 6）。**返信の行**は padding 0 12 10・gap 8: 返信欄 26（改行ごとに 16 伸びる・radius 4・地 `sunkInk` .35・枠 1px、焦点で `editor.prFieldFocus`（accent .55）、無ければ `borderInk` .10・プレースホルダ「返信」`editor.tertiary`）、「レビューに追加」26（padding 0 10・radius 4・地 `accent.primary`・`type.editorPrThreadPrimaryButton` 11.5 semibold `tab.activeText`）、「解決して返信」「取り消す」（同じ形の枠 1px `borderInk` .12・`type.editorPrThreadButton` 11.5 `editor.text`・hover 地 `surfaceInk` .06）。押せない姿（書き込みの最中・空の欄の「レビューに追加」）は色の α を `opacity.disabled` 倍。失敗の文は 11・`danger`・余白は返信の行と同じ。**スレッドのある行**の地は `editor.prThreadRow`（accent .14。範囲のスレッドは範囲の全部の行）。**コメントの入口**は、PR の diff の行番号の列の左端に足す頭の列 24（`layout.editorPrMarkColumn`）に描く——コメントできる行の左端に線 3（`layout.editorPrMarkLineWidth`・`editor.prMarkLine`（accent .55）。行の高さいっぱいで、続く行は繋がる）、ポインタを乗せた行に ＋ 16×16（`layout.editorPrMarkButton`・radius 4・地 `accent.primary`・中の ＋ 10 線 1.5 `accentCheckStroke`。列の左右の中央・行の縦の中央。＋ の上に乗せても見え方は変えない）。**書いている範囲**（引いている間と、開いている欄の範囲）の行は、地 `editor.prDraftRow`（accent .22。追加・削除の地の代わり、記号はそのまま）と線 `accent.bright`。**範囲の欄の頭**は、箱の中の最初の行 26 に「42〜43 行にコメント」（`type.editorPrThreadHead`・`accent.bright`。1 行の欄には出さない）。ファイルの行の印の左にコメントの数（印 11 線 1.4＋数 `type.editorPrCount`・間 3・`accent.bright`）。
- **PR bar parts**（PR の画面の上のバーの部品。→ [editor/shell](../spec/editor/shell.md#上のバー)）: 中ほどに、区切り線の後の PR の札（中ほどの札の素の姿。`#番号` `text.muted`・先頭のブランチ名 `text.primary`・→ 12 `text.muted`・ベースのブランチ名 `text.muted`。押せない。広い順に「→ ベースつき → ブランチ名だけ → ブランチ名を省略」）、26 角のアイコンのボタンの再読込（`refresh`）と「GitHub で開く」（`openFile`）。右端に、右端の主な操作のボタン「レビュー」と、未送信のコメントがあれば固定の添え（吹き出し 12・数 `type.editorBarCount`・間 3・`state.waiting`）。レビューのやりとりを読めるまでは押せない姿。
- **PR review popup**（レビューのポップアップ。見本の `.rpo`。→ [editor/pull-request-review](../spec/editor/pull-request-review.md)）: 地はポップアップの地の部品（幅・角丸・ガラス・影はポップアップの器）。承認を選べば `success`、変更を依頼を選べば `state.waiting` を地の色（縁・上側の色づけ・外の光）に渡す。区分（padding 12 12 0・段の間 6）: 見出し `type.editorPrPopupHeading` `text.muted`・左右 2。全体へのコメント欄の箱（padding 5 12・radius 9・地 `surfaceInk` .05・枠 1px `borderInk` .15）に、欄（`type.editorPrPopupField`・行の高さ 20・1 行のときの高さ `editorPrPopupFieldHeight` 30——上下 5。箱の余白と合わせて上下 10）。未送信のコメントの行（高さ 26・間 10・padding 0 8・radius 6・左右へ 6 はみ出す・hover の地 `surfaceInk` .05）: 場所の札（`type.editorPrPopupRef` `accent.bright`・地 `accent.primary` .2・radius 4・左右 6）と本文の先頭 1 行（`type.editorPrPopupRow` `text.secondary`・末尾省略）。置けない行は札も本文も `text.muted`（札の地は `surfaceInk` .2）。6 行を越えれば区分の中でスクロール。置けない未解決のスレッドの件数（`type.editorPrPopupRow` `text.muted`、hover `editor.text`）。下端（padding 12・上の空き 12・上に 1px `borderInk` .15・間 10・右寄せ）: 種類（高さ 30・padding 0 11 0 9・radius 8・間 6・`type.editorPrPopupEvent` `text.secondary`・枠 1px `borderInk` .15・印 13 `text.muted`。選んだ種類は `type.editorPrPopupEventSelected` `text.primary` に、中立は地 `surfaceInk` .1・枠 .3、承認は地 `success` .16・枠 .65・印 `success`、変更を依頼は地 `state.waiting` .14・枠 .6・印 `state.waiting`。選べない種類は `opacity.disabled`）と Large button「レビューを送信」＋ Key cap ⌘↵（地は種類の色、ほかは `accent.primary`。送れない間は押せない姿）。下端の帯（padding 9 14 10・地は色の .1・上に色の .3 の線・字は置き場の札と同じ 12・行高 1.55）: 送れない理由は `text.muted`、送信の失敗は `danger`。
- **PR failure cards**（PR の画面の失敗の札。→ [editor/pull-request-panel](../spec/editor/pull-request-panel.md#出せない理由と失敗)）: 置き場の失敗の札の部品そのまま（読めていない・確認済み・送信の 3 種、上からこの順）。
- **Diff file header**（差分のファイルの見出し。見本の `.fh`。→ [editor/diff](../spec/editor/diff.md#見出し)）: 本体が diff の間だけ本体の上端に置く帯。高さ `layout.editorDiffHeader` 32（下端の 1px hairline `opacity.editorDiffHeaderLine` .07 を含む）・地 `surfaceInk` `opacity.editorDiffHeaderGround` .035（Changes・PR とも同じ）・部品の間 `layout.editorDiffHeaderGap` 8・左の余白 `layout.editorDiffHeaderLeading` 12（PR は `editorDiffHeaderLeadingPullRequest` 18）・右の余白 `layout.editorDiffHeaderTrailing` 12。左から、（PR だけ）確認済みのチェック（PR panel の行のチェックと同じ姿・14 角）・パス（`type.editorDiffHeaderPath`。フォルダ `text.muted`・頭から省く、ファイル名 `type.editorDiffHeaderName` `text.primary`・省かない）・印の丸（`layout.editorDiffHeaderDot` 7 の円。未保存は `text.primary`、ディスクが変わったは `editor.caution`。ファイル名との間 6）・状態の字（`type.editorDiffHeaderBadge`・幅 `layout.editorDiffHeaderBadge` 12・中央。色は Explorer の git バッジと同じ）・区切り線（1×`layout.editorDiffHeaderDivider` 16・hairline `opacity.editorDiffHeaderDivider` .15・左右 `layout.editorDiffHeaderDividerInset` 6）・（PR だけ）Text button「確認済みにする」「確認済みを外す」＋ Key cap「v」・Text button「ファイルを開く」（印 `openFile`。押せないときは Text button の押せない姿）。帯の下に影（見本の `0 6px 14px -8px rgba(0,0,0,.55)`）を `layout.editorDiffHeaderShadow` 14 の縦の階調で落とし、diff の面の上端に重ねる（影の上の押下は面へ通す）。押してもフォーカスを取らない。
- **Diff body**（→ [editor/diff](../spec/editor/diff.md)）: 本体はコードビューと同じ字・行高 18・上 4・地なし（chrome の veil を透かす）。本体の幅が `layout.editorDiffSideWidth` 1000 以上なら並列、未満ならインライン（保存しない）。行番号の字はコードビューと同じ `editor.lineNumber`。番号の列 1 つは最小 44（`layout.editorDiffNumber`。収まらなければ広がる）で、番号の右の余白はインライン 6・並列 8。インラインは 旧番号｜新番号｜記号の列 18（＋ `diff.added` / − `diff.removed`）｜本文、並列は各側 番号 1 列｜本文で（PR の diff は、どちらも番号の左に頭の列 24 を足す → PR comments）、2 面の境は 1px `borderInk` .07（light ×1.4）。行の地は追加 `diff.added`・削除 `diff.removed` の α `opacity.editorDiffRow`（.12）、詰め物は `surfaceInk` .02（light ×0.6）で、行番号の列の左端から面の右端（縦スクロールバーの列の下）まで。**字は全部の行を普通のファイルと同じ構文色**で描く（§3）。空白の点も普通のファイルと同じ。ミニマップ・git の印の列・スクロールバーの git の印は持たない。表示できないときの一文は `type.editorLead`・`text.muted`・中央。
- **Board（自動化のウィジェット）**: 画面の構成と契約は [chrome/board](../spec/chrome/board.md) が持ち、寸法・トークンの値はボードのビュー（`Sources/Orbe/Features/Board/`）が持つ。
- **Empty state**: 中央・`type.body`・`text.muted` の一文＋必要なら `type.meta` ヒント。装飾なし。**エディター面**の空・使えないときの表示（→ [editor/faces](../spec/editor/faces.md)）: 本体は、下 60 を除いた範囲の中央に、見出し `type.editorEmptyTitle` `text.secondary`、その 6 下に案内の一文 `type.editorEmptyText` `text.muted`（中央揃え・左右 padding 16・折り返す）。ボタンは一文の 18 下（高さ 30・padding 0 14・radius 8。主は地 `accent.primary`・字 `type.editorEmptyButton` `on.accent`、主でないものは地 `surfaceInk` .08・字 `type.editorEmptyText` `text.primary`。押せない間は `Opacity.disabled`）。ショートカットの行は見出しの 14 下から行の間 6（案内 `type.editorEmptyText` `text.muted` と、8 右に Key cap（字））。左の列の一言は、パネルの題の行の下に `type.editorSidebarNote` `text.muted`・中央・padding 22 14。**ボード**の空状態は一文だけで、字種と色は表示できない diff の理由の一文と同じ（`type.editorLead`・`text.muted`）。

### 5.1 chrome（2 段 28+28・TopBar＋TabBar）

- **TopBar（上段 28px）**: 背景透明（最背面の chromeBg＋ambient が見える）・**罫線なし**。左 padding 16＋信号機の柱 80px。縦位置は信号機 close ボタン中央へ整列。空白は窓ドラッグ面。
  - 左: `workspace名`（mono 11・`text.primary`）。build-id・現在地は名前の後に後置（→§9）。現在地は見せているもの（端末で見せている／エディターで見せている。透かしはエディター）に従い、トーン付きの断片列——端末で見せていれば cwd 1 本（`text.muted`）、エディターで見せていれば、Files は根（`text.muted`）＋ 相対パス（`statusText`）、根の外の文書は絶対パス 1 本（`statusText`）、文書が無ければ根だけ、Changes は根だけ、PR は `PR #N`（`accent.bright`）＋ ` · `・根（`text.muted`）。
  - 右: ステータスストリップ（§4 の書式）・右 padding 16。
- **窓が main でない間（退いた姿）**: chrome だけが退き、端末・エディターの本文の濃さは変えない。切り替えは即時（アニメーションなし）。
  - グロー（BackgroundGlow のラジアル 2 枚）を描かない。不透明時の `bg.base` の地は残す。
  - workspace 名 `text.muted`。現在地は 2 トーンの強弱を保って一段沈める——弱い断片 `text.mutedInactive`・強い断片と `PR #N` は `text.muted`。ストリップの件数 `text.muted`（idle の減光は残す）。
  - 選択セル＝地 `tab.activeBgInactive`・文字と家のアイコン `text.primary`・グリフは通常の状態色（done の check 線も既定の `checkStroke`）。改名中の入力欄の文字も `text.primary`。非選択セルの文字 `text.muted`。
  - 状態グリフの色・build-id・＋・連の地／枠／識別バー・区切り線・挿入キャレットは変えない。
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
