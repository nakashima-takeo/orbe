# Orbe デザインシステム

> ステータス: v0.4.0 · 2026-07-11
> 値の正（SSOT）: chrome/semantic は `Sources/Orbe/DesignSystem/DesignTokens.swift`（機械可読ミラー `docs/tokens.json`）／ 識別色（端末 ANSI 16 色・chrome 共有アンカー）は `Sources/Orbe/DesignSystem/OrbePalette.swift`（端末 conf を生成し、chrome アンカーへ定数を供給）。
> ガラス質感・elevation・glow は `Sources/Orbe/DesignSystem/DesignTokens+Glass.swift` が所有（本書は再定義しない）。
> 本書は思想・契約を記す自由記述ドキュメントで、**思想・契約の正は本書、値の正は上記 Swift**。Orbe の外観の**正**はこのリポジトリの中で閉じている。ただしコード中の一部コメントは、値が決まった経緯の記録として設計見本（リポジトリ外）を引用する——それは出所の記録であって、正ではない。

Orbe は AI コーディングエージェントのためのネイティブ macOS ターミナル。外観は
**dark = 温かい炭＋フロストガラス**（既定）、**light = 藤紙×電紫**（藤紙＋ガラス）。chrome（StatusRow・タブ・パレット・EditorPane・検索・オンボーディング）をこの semantic トークンで統一し、ターミナルと外側を一体にする。

---

## 1. 原則

1. **温かく、落ち着いて、密に。** 地は温かい炭／藤紙。装飾は最小、情報は密。
2. **色は状態と自分の出番に。** 無彩に近い土台の上で、色は **エージェントの状態（確定配色の温度分け）** と **自分の出番（電紫 accent＝選択・プロンプト）** にだけ使う。
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
| `text.primary` | 本文・選択ラベル・タブ反転面の地 | `#eaddc7` | `#3a3151` |
| `text.secondary` | 通常ラベル・非選択タブ文字 | `#b8afc4` | `#5f5678` |
| `text.tertiary` | 三次 | `#8b8397` | `#8d85a3` |
| `text.muted` | 非アクティブ・補助・ヒント | `#8b8397` | `#8d85a3` |
| `accent.primary` | 選択・自分の出番・プロンプト | `#9068f0` | `#6d43d8` |
| `accent.focus` | フォーカス | `#9068f0` | `#6d43d8` |
| `on.accent` | accent 塗り上のインク＝地色 | `#1a1721` | `#fcfbfe` |
| `diff.added` / `success` | 追加・成功（green） | `#81b88b` | `#279a4d` |
| `diff.removed` / `danger` | 削除・エラー（red） | `#d16969` | `#e02d33` |
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
| `tab.rowBg` | タブ行全幅の地 | `rgba(0,0,0,.28)` | `rgba(58,49,81,.08)` |
| `tab.segBg` | 非選択セグメントの地 | `rgba(255,255,255,.10)` | `rgba(58,49,81,.06)` |
| `tab.activeText` | 選択セグメント（反転面）の文字 | `#1a1721` | `#f3f0fa` |

**意図的な同値収束（事故ではない）**: Orbe の配色は色階層が少なく、複数の semantic 名が同一値へ収束する。SSOT では別名で表現している。
`accent.focus` ＝ `accent.primary`／ `text.tertiary` ＝ `text.muted`／
`success` ＝ `diff.added`（green）／ `danger` ＝ `diff.removed`（red）／
`state.dormant` ＝ `text.muted`／ `surface.0` ＝ `bg.sunken`。
`state.done`（完了・緑）と `diff.added`（green）、`state.waiting`（要応答・黄）と `conflict`（ANSI黄）は**別トークンとして分離**（light では偶々同値だが dark では異なる。SSOT は状態色を `StateHue`、ANSI 系を端末アンカーから別々に導く）。
**反転色（`state.*Inverse`）は対テーマの状態色**＝dark/light の値を入れ替えただけ（選択タブの反転面上でコントラストを確保する仕組み）。
**light の `tab.activeText` `#f3f0fa` は `bg.base` `#fcfbfe` と別値**（on.accent の流用不可）。

### 2.2 状態の塗り・tint（事前 alpha 済み・per-theme）
選択・hover は `accent.primary` の淡塗り（テーマごとの accent 基調に α を掛けた事前合成値）。状態別 tint は件数ピル・バッジの淡塗り（各テーマの状態色の 12–14%）。

| token | dark | light | 用途 |
|---|---|---|---|
| `selectionFill` | `rgba(144,104,240,.14)` | `rgba(109,67,216,.14)` | 選択行・選択候補（タブは反転であり使わない） |
| `diffSelectionFill` | `rgba(144,104,240,.10)` | `rgba(109,67,216,.10)` | Diff ファイル選択行 |
| `hoverFill` | `rgba(144,104,240,.10)` | `rgba(109,67,216,.10)` | hover |
| `tint.working` | `rgba(133,173,255,.12)` | `rgba(31,102,201,.12)` | working 件数ピル |
| `tint.waiting` | `rgba(238,194,90,.12)` | `rgba(177,123,0,.12)` | waiting |
| `tint.done` | `rgba(130,216,148,.12)` | `rgba(39,154,77,.12)` | done |
| `tint.red` | `rgba(209,105,105,.14)` | `rgba(224,45,51,.14)` | エラー・削除件数 |
| `smallPillFill` | `rgba(255,255,255,.04)` | `rgba(58,49,81,.06)` | ⌘⇧S 等のキーバッジ地 |
| `scrim` | `rgba(10,8,14,.35)` | `rgba(58,49,81,.18)` | Workspace 等の通常暗幕 |
| `scrimStrong` | `rgba(10,8,14,.40)` | `rgba(58,49,81,.22)` | 設定等の強い暗幕 |

diff 行の地色は α .10（tint とは別・`DiffBodyView` が直値で持つ）。

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
| `type.diffHeader` | 12 / regular / mono | Diff ヘッダ |
| `type.diffStat` | 11 / regular / mono-digit | Diff 統計 |
| `type.codeSmall` | 11 / regular / mono | 差分本文・パネル内 mono11 |
| `type.codeCompact` | 11.5 / regular / mono | 補完候補行 |
| `type.bodySmall` | 10.5 / regular / sans | 小さな補助本文 |
| `type.label` | 12.5 / medium / mono | パレット行・主ラベル |
| `type.labelStrong` | 12.5 / semibold / mono | 選択ラベル |
| `type.caption` | 11 / medium / mono | 件数・小バッジ・小ボタン |
| `type.captionDigit` | 11 / medium / mono-digit | 件数（`monospacedDigit`） |
| `type.meta` | 10 / regular / mono | 行番号・メタ・ヒント・path |
| `type.sectionLabel` | 9.5 / regular / mono | 大文字セクション見出し（uppercase は使用側 `textCase`） |

**tracking / line-height スカラ**（NSFont では表せず、使用側で `.tracking()` / lineSpacing 換算）:
`tracking.label` 1（大文字セクション見出し）／ `tracking.status` 0.3（ステータスストリップ）／ `line.body` 1.6（本文）／ `line.terminal` 1.55（ターミナル本文）。

### 2.4 余白・角丸・線
- **spacing（2/4pt グリッド・穴なし）**: `hair 2 / tick 4 / note 6 / step 8 / beat 12 / bar 16 / span 20 / phrase 24`
- **radius**: `xs 3`（タブセグメント）/ `sm 4`（バッジ・キーヒント）/ `row 8`（リスト行・小コントロール）/ `md 10`（入力・小パネル）/ `card 12`（カード・設定行）/ `lg 16`（パネル・オーバーレイ）/ `pill 999`（カウントピル・トグル）
- **stroke**: `hairline 1`（罫線・枠）/ `marker 3`（引用・スパインの左バー。**選択には使わない**）/ `focusRing 2`（フォーカスリング）
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

> リズム規律: 同種の遷移に別々の時間を使わない。`reduce motion` 環境では遷移は `instant`・ループは停止（スピナーは静的な 3/4 円弧のまま残り、形で working と判別できる）。

---

## 3. アクセシビリティ契約（全コンポーネント共通・最優先）

**色だけに意味を持たせない。** 意味は必ず 形・記号・位置・文字 のいずれかでも伝え、色は補強に回す。

- **diff**: 追加＝green（`diff.added`）/ 削除＝red（`diff.removed`）。さらに gutter の `+ / −` マーカーと削除語の取り消し線で二重符号化。
- **成功＝green（`success`）＋ `✓`／エラー＝red（`danger`）＋ `⚠`。**
- **conflict は文字バッジ `C`（黄）＋note「競合 — ターミナルで解決」で伝える。** 色だけに頼らない。
- **エージェント状態はグリフ形＋動きが一次情報。** 4状態すべてが固有の形（円弧・吹き出し・チェック・zzz）を持ち、色情報を除いても判別できる。横断ロールアップは常に件数（数字）を併記。
- **ファイルバッジは文字（M/A/D/C）が本体。** staged/unstaged は StageBox の3状態（staged／partial／none）＋位置で符号化し、色に依存しない。
- **コントラスト**: テキスト階層は背景に対し WCAG AA（本文 4.5:1 / 大字 3:1）。`text.muted` は補助情報専用、本文に使わない。

---

## 4. エージェント状態の言語

確定配色の温度分け——自分の出番=電紫 accent、waiting=黄、done=green、idle/dormant=無彩グレー。working=青（accent と別色相に分離）。
グリフは自作アイコン（形状の正は `Sources/Orbe/Agent/StatusGlyph.swift`）。ここでは色・形・意味を規定する。

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

- **選択の示し方**: リスト行の選択は **tint 背景**（`selectionFill`）。タブの選択のみ**前景色反転**（§5.1）。左 3px バーは**どこでも使わない**（Completion も例外にしない）。下線・太字による選択弁別も持たない。
- **Tab（セグメント）**: タブ行（高さ28・padding 3・gap 2・地 `tab.rowBg`）の中のセグメント。radius 3・padding 横8・max幅 140・末尾省略。非選択＝地 `tab.segBg`・文字 `text.secondary`（idle/dormant/なしも同じ）・状態グリフ 9px（working は stroke 1.6。idle は非表示）。**選択＝地 `text.primary`（前景色反転）・文字 `tab.activeText`・グリフ＝`state.*Inverse`（対テーマ状態色）**、done の check 線のみ `text.primary`。タブ背景を状態色で塗らない。
- **Palette row**: default＝`text.secondary`（workspace 行の名前＝最優先状態の色）。hover＝`hoverFill`＋`text.primary`。selected＝`selectionFill` 地。dormant＝`Opacity.dormant`。情報行＝`text.muted`・選択不可。行= padding 5×10・radius 8。workspace 行の右詰め＝状態別カウントピル（padding 1×7・radius pill・地 tint .12・文字 状態色・グリフ 9px）。
- **Button**: primary（主 CTA）＝塗り `accent.primary`・文字 `on.accent`・radius `md`。secondary＝塗りなし・文字 `accent.primary`・枠 1px `surface.1`・hover で `hoverFill`。disabled＝`Opacity.disabled`。
- **File badge**: EditorPane のレール行では背景なしの色付き `M / A / D / C`（M=accent・A=green・D=red・C=黄）。ビューアヘッダ・CommitDetail では同色の淡塗り角丸バッジ（`StatusBadgeView`・13×13・radius 3）。
- **Search field**: 外枠＝`bg.sunken`＋1px `surface.1`＋radius `md`。focus＝リング `accent.focus`。no-match＝`danger`。件数＝`captionDigit`。
- **Focus / active pane**: アクティブペインは 2px 内側リング `accent.focus`。カーソル点滅と併走。
- **EditorPane**: ターミナル右隣の Git ワークベンチペイン。寸法・色はペイン専用トークン——実寸タイポ（`pane*`/`prose*`）と、`surfaceInk`/`borderInk` に view 側で opacity を掛けた面・罫線——で組む。conflict ファイルは変更レールのバッジ＋「競合 — ターミナルで解決」note のみ（解決 UI は持たない）。
- **Onboarding**: waiting＝`text.muted`。installing＝スピナー（`accent.primary`）。done＝`✓` `success`。failed＝`✗` `danger`＋再試行 secondary。skipped＝`text.muted`・取り消し線。
- **Empty state**: 中央・`type.body`・`text.muted` の一文＋必要なら `type.meta` ヒント。装飾なし。

### 5.1 chrome（2 段 26+28・TopBar＋TabBar）

- **TopBar（上段 26px）**: 背景透明（最背面の chromeBg＋ambient が見える）・**罫線なし**。左 padding 16＋信号機の柱 80px。縦位置は信号機 close ボタン中央へ整列。空白は窓ドラッグ面。
  - 左: `workspace名`（mono 11・`text.primary`）。cwd・build-id は名前の後に muted で後置（→§9）。
  - 右: ステータスストリップ（§4 の書式）・右 padding 16。
- **TabBar（下段 28px・全幅セグメント行）**: 地 `tab.rowBg`・padding 3・セグメント間 gap 2。タブは §5 Tab 契約。行に収まらないときは全タブが縮み（min 40）、それ以下は横スクロール。＋ボタンはセグメント様式（地 `tab.segBg`・radius 3）で末尾に置く（→§9）。

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
- バージョンは `docs/tokens.json` の `$meta.version`（semver）。値変更は minor、役割の追加/削除は major 目安。本書冒頭の日付も更新する。

---

## 8. ターミナル本体（Ghostty）

中央ターミナル（Ghostty が描く Metal レイヤー）も chrome の外観に寄せる。色は chrome のトークンとは別レイヤー（Ghostty の named theme）で持ち、`theme = light:OrbeLight,dark:OrbeDark`（バンドル `Contents/Resources/ghostty/themes/` はこの2枚のみ・出所 `app/themes/`）に固定。

- **配色**: ANSI 16 色＋端末 bg/fg/cursor/selection は識別色 SSOT `OrbePalette.swift` が持ち、`renderConf` が conf 2枚（`app/themes/OrbeDark` / `OrbeLight`）を生成する（手写しの転写なし）。16 色は確定配色値。dark は **VS Code Dark+ のシンタックストークン色**を ANSI スロットへ再配置したもの（VS Code の `terminal.ansi*` とは別物）、light は無彩色ランプ 0/7/15 が **Catppuccin Latte** 由来（8 のみ AA 是正）で有彩色 1–6 は light 背景向けに決めた値。chrome と共有するアンカーは 背景 `chromeBg`（`#1a1721`/light `#fcfbfe`）・前景 `chromeText`（`#eaddc7`/`#3a3151`）・カーソル `accent`（`#9068f0`/`#6d43d8`）・赤 `diffDel`（1・9）・緑 `promptGreen`（2・10）・黄 `conflict`（3・11）で、dark/light とも端末 ink と同値。light の bright 赤/緑/黄（9–14）は normal（1–6）のミラー。ink スロット {1-6,8-14} は原則 各モードの背景に対し WCAG AA 4.5 以上（構造色 0/7/15 は最暗/最明淡色として ANSI 慣習で対象外）。ただし確定値の一部は 4.5 に満たず、人が承認済みの確定値を優先してゲートから除外する（`OrbePalette.aaExemptDark/Light`＝dark 8・light 1/2/3/9/10/11）。`swift test`（`OrbePaletteTests`）が除外外の ink のコントラストと conf の drift（SSOT からの再生成＝コミット済み）を検証し、回帰と転写ドリフトをコミット不能にする。
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
