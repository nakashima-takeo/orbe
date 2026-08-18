# Issue #131: workspace / tab activation lifecycle

## 概要

- 対象: GitHub Issue #131。背景 workspace で materialize した agent を Attention・通知・palette・control API が見失わず、同時に未 materialize の復元 tab を休眠のまま正確に保持する。
- 基準 commit: `394024c fix(workspace): derive activation from live tabs`
- テスト対象: `Workspace`、`TerminalController`、`SessionStore`、`WindowController`、永続復元、control / CLI 投影。
- 基本モデル:
  - `tab.activated` は、その tab の materialization が開始済みであることを表す現在状態。
  - `workspace.activated` は保存された履歴フラグではなく、常に `workspace.tabs.contains(where: \.activated)` から導出する。
  - `active workspace`、`workspace.activated`、`lastUsedAt` は互いに独立した事実である。
  - 復元 tab の休眠 agent 数は、各 pane の `holdsDormantRestoredAgent` から tab 単位に集計する。
  - 通常の workspace 前面化では、選択 tab を同期 materialize し、残る tab を順次 materialize する。
  - 背景 workspace への新規 tab 作成では、新しい tab だけを materialize し、既存復元 tab は休眠のままにする。
  - 公開 API に tab 単位の休眠・起床操作は追加しない。

## 根拠

| 根拠 | 確定している契約 |
| --- | --- |
| `docs/spec/platform/workspace.md` | workspace activation は配下 tab の現在状態から導出する。0 tab / 全 dormant は false。背景 materialize は MRU を動かさない。tab close の MRU は、前面で残存 tab を再選択・表示する列だけが foreground use として MRU を進める。 |
| `docs/spec/control/api.md` | `list_workspaces.activated` は live tab の有無。0 tab workspace は `active: true, activated: false` を取り得る。背景作成は新規 tab だけを起こす。 |
| `docs/spec/palette/workspace.md` | live tab が 0 の workspace を減光し、最後の live tab が失われれば dormant 表示へ戻す。 |
| `Sources/Orbe/Features/Workspace/Workspace.swift` | `Workspace.activated` は `tabs.contains(where: \.activated)` の computed property。 |
| `Sources/Orbe/App/Layout/TerminalController.swift` | tab materialization 開始時に tab を activated とし、配下 pane の dormant-restored provenance を解消する。 |
| `Sources/Orbe/Features/Workspace/SessionStore.swift` | owner 検証後に tab activation、workspace use、selection を記録する。tab close は配列からの除去により workspace の導出値へ直ちに反映する。 |
| `Sources/Orbe/App/Layout/WindowController.swift` | 前面化時は選択 tab を同期 mount し、残りを main queue で順次 mount する。0 tab 前面化は workspace use だけを記録する。 |
| `Sources/Orbe/App/Layout/WindowController+OpenTab.swift` | 背景作成は新しい tab だけを off-screen materialize する。 |

## テストレベル

- L1: `Workspace` と `SessionStore` の純粋な導出・owner 検証・close 行列。
- L2: 実 `WindowController` / Ghostty surface を使う前面化、背景 materialize、順次 mount、close 後の host 側収束、永続復元、control 投影。
- L4: 実 `orb` プロセスを使う背景 agent spawn の非前面化・継続利用可能性。既存プロセステストを lifecycle 契約まで拡張する。

## 仕様一覧

### 1. Workspace activation は tab の現在状態からだけ導出する

**分類**: 現状挙動  
**種類**: 状態遷移 / プロパティベース  
**テストレベル**: L1

**不変条件**:

```text
workspace.activated == workspace.tabs.contains { $0.activated }
```

| # | Given | When | Then |
| --- | --- | --- | --- |
| 1.1 | tab が 0 枚の workspace | `activated` を読む | `false`。workspace が current / active でも変わらない |
| 1.2 | 1 枚または複数枚の tab がすべて dormant | `activated` を読む | `false` |
| 1.3 | dormant tab 群のうち 1 枚だけ materialize 済み | `activated` を読む | `true` |
| 1.4 | 2 枚以上の tab が materialize 済み | その一部だけが残る任意の並び替え・削除を行う | live tab が 1 枚以上ある間は `true` |
| 1.5 | live tab が存在する workspace | 最後の live tab を除去し、0 枚または dormant tab だけにする | 保存フラグの手動更新なしで直ちに `false` |

**検証方法**:

- tab 数 0、all false、one true、multiple true の代表例に加え、tab 配列と activation bit 列を小さく全列挙して式との同値を確認する。
- `Workspace.activated` を直接代入する fixture は禁止する。computed property が単一の正であることをコンパイル時にも守る。

### 2. Materialization 記録は owner を検証し、tab だけを遷移させる

**分類**: 現状挙動  
**種類**: 状態遷移 / 所有境界  
**テストレベル**: L1

| # | Given | When | Then |
| --- | --- | --- | --- |
| 2.1 | store が所有する workspace と、その workspace が所有する dormant tab | `recordMaterialization(of:in:)` | `true`、対象 tab は activated、workspace は導出で true |
| 2.2 | 2.1 の完了後 | 同じ記録を再実行 | `true` のまま冪等。ほかの tab、active index、MRU は変化しない |
| 2.3 | store 外の workspace とその tab | materialization を記録 | `false`。tab / workspace / MRU に変化なし |
| 2.4 | store 所有 workspace A と、別 workspace B 所有の tab | A の tab として materialization を記録 | `false`。A / B / tab のいずれにも変化なし |
| 2.5 | 復元 agent を持つ複数 pane の dormant tab | materialization を記録 | tab は activated になり、その tab 配下だけ `holdsDormantRestoredAgent` が false。別 tab の provenance は保持 |
| 2.6 | 新規 tab または通常 shell pane | materialization を記録 | activated になるが dormant-restored count を負にせず、0 のまま |
| 2.7 | all-dormant workspace | 有効な selection 記録だけを行い、mount はまだ始めない | active tab index と MRU は更新され得るが、tab / workspace activation は変わらない |

**owner 検証の観測点**:

- 戻り値だけでなく、target / non-target の tab activation、workspace の導出値、各 pane の dormant provenance、`lastUsedAt` を前後比較する。
- ID の一致ではなくオブジェクト所有関係を検証する現行 contract を固定する。

### 3. Foreground use と activation / MRU は独立している

**分類**: 現状挙動  
**種類**: 状態遷移 / 時刻境界  
**テストレベル**: L1 + L2

| # | Given | When | Then |
| --- | --- | --- | --- |
| 3.1 | 0 tab workspace が背景にあり、古い `lastUsedAt` を持つ | workspace を前面化 | その workspace が active、`activated == false`、tab / pane は 0、`lastUsedAt` だけが新しくなる |
| 3.2 | 起動時に保存済み active workspace が 0 tab | WindowController を復元 | 同じく active / activated false / empty content。`lastUsedAt` は復元時の foreground use として更新 |
| 3.3 | all-dormant かつ非空の workspace | 前面化し選択 tab を mount | `lastUsedAt` が更新され、選択 tab が activated、workspace は導出で true |
| 3.4 | foreground workspace | foreground で新規 tab を作成・選択 | 選択という workspace use により MRU が更新され、新規 tab が activated |
| 3.5 | dormant な背景 workspace | 新規 tab を off-screen materialize | workspace は activated になるが `lastUsedAt` は完全一致で不変 |
| 3.6 | store 外 workspace | `recordWorkspaceUse` | `false`、`lastUsedAt` と activation は不変 |

**時刻検証**:

- 更新有無を wall-clock の厳密値で比較しない。更新前後を固定 clock にできない現状では、古い十分な値からの単調増加または完全一致を確認する。
- `lastUsedAt == nil` からの更新も境界値として含める。

### 4. Tab close 後の MRU は、前面利用・tab選択が新たに成立したかで決まる

**分類**: 現状挙動  
**種類**: 状態遷移 / イベント意味  
**テストレベル**: L1 + L2

| # | Given | When | Then |
| --- | --- | --- | --- |
| 4.1 | live / dormant の任意構成を持つ背景 workspace | tab を close | `lastUsedAt` は不変 |
| 4.2 | 1 枚だけの active workspace | 最後の tab を close | workspace は active のまま 0 tab / activated false、`lastUsedAt` は不変 |
| 4.3 | 2 枚以上を持つ active workspace | tab を close し、残る tab を実際に再選択・前面表示 | foreground use / tab selection が成立するため `lastUsedAt` は更新される |

**イベント境界**:

- `SessionStore.removeTab` 自体は MRU を変更しない。
- active かつ非空の close は `WindowController.closeTab` が `.reselectActive` を `select` に渡し、`select` が `recordSelection` を介して `lastUsedAt` を更新する。これは内部cleanupだけではなく、残存tabを実際に前面表示し続ける利用イベントなので正当である。
- 背景closeはreselectせず、前面の最後のtabを閉じた0tab化も次tabを選択しない。どちらもstampを維持する。「closeは常に不変」「closeは常に更新」のいずれにも畳まない。

### 5. 通常の workspace 前面化は配下 tab を順次 materialize する

**分類**: 現状挙動  
**種類**: 非同期 / 状態遷移  
**テストレベル**: L2

| # | Given | When | Then |
| --- | --- | --- | --- |
| 5.1 | 複数 dormant tab の workspace | 前面化 | 選択 tab は同期 mount 前に activated。workspace は直ちに true |
| 5.2 | 5.1 の直後 | main queue を 1 tick 進める | hidden tab は同時一括ではなく 1 枚だけ追加で activated |
| 5.3 | hidden mount が完了するまで queue を進める | 処理完了 | workspace 配下の全 tab が activated。復元 agent provenance は各 tab の materialization 時に解消 |
| 5.4 | hidden mount の予約中 | 別 workspace へ切り替える | 古い workspace の残ジョブは中断し、未処理 tab は dormant のまま |
| 5.5 | 5.4 の workspace を再度前面化 | queue を完了まで進める | 既に live な tab を再生成せず、残る dormant tab だけを順次 materialize |
| 5.6 | 0 tab workspace | 前面化 | mount job を作らず、activated false のまま。MRU 契約は 3.1 に従う |

**非同期テストの注意**:

- 固定 sleep や「queue を N 回 drain すれば 1 tab だけ進む」という仮定を使わない。`scheduleHiddenMounts` の最初のジョブを予約した直後に main queue sentinel を積み、再帰予約された次ジョブより先に sentinel から activated tab 集合を観測する。各段で sentinel を挟めば 1 tab ずつ進む契約を決定的に検証できる。
- surface pointer の生成数だけに依存せず、tab activation と dormant provenance の両方を確認する。

### 6. 背景 workspace の新規 tab 作成は mixed state を正確に作る

**分類**: 現状挙動  
**種類**: 状態遷移 / E2E  
**テストレベル**: L2 + L4

| # | Given | When | Then |
| --- | --- | --- | --- |
| 6.1 | 復元 agent を持つ dormant tab が複数ある背景 workspace | 新規 shell tab を背景作成 | 新規 tab だけ activated。既存 tab と各 dormant provenance は不変。workspace は true |
| 6.2 | 6.1 と同じ | agent spawn / agent resume を背景作成 | 新規 agent tab だけ activated。既存復元 agent は起床しない |
| 6.3 | 0 tab の背景 workspace | 新規 tab を背景作成 | 新規 1 tab が activated、workspace は true、dormant agent count は 0 |
| 6.4 | 既に mixed な背景 workspace | もう 1 枚背景作成 | live tab が 2 枚になり、既存 dormant tab は dormant のまま |
| 6.5 | 別 workspace が foreground / focused pane を持つ | 背景作成 | foreground workspace、selected tab、focused pane、window focus は変わらない |
| 6.6 | 背景 workspace が既存 `lastUsedAt` を持つ | 背景作成 | MRU は不変。`activated` だけが tab 集合から true になる |
| 6.7 | mixed workspace の control 投影 | `list_workspaces` と関連一覧を読む | `activated: true`。live agent 集計と dormant restored agent 集計が独立して正確。見た目が同じ zzz でも意味を混同しない |
| 6.8 | 実 `orb agent spawn --workspace B` | `list_workspaces`、read / input / size を利用 | foreground を奪わず新規 pane は利用可能で、B は `activated: true`。Attention 系の状態投影は同じ実装経路を L2 で固定する別仕様に委ね、L4 に重複搭載しない |

**公開面の境界**:

- `list_panes.tabActivated` や tab 単位 wake / sleep API は今回追加しない。
- 内部 `TerminalController.activated` を単一の正として保持し、将来の `list_panes` 投影や再休眠へ自然に拡張できることを壊さない。

### 7. Tab close の全組合せで導出値と host 側収束を区別する

**分類**: 現状挙動  
**種類**: 状態遷移 / 組合せ  
**テストレベル**: L1 + L2

#### L1: `SessionStore.removeTab` 直後の純粋な導出

| # | Workspace | Before | Close | After |
| --- | --- | --- | --- | --- |
| 7.1 | background | dormant × 2 | dormant 1 枚 | dormant × 1、activated false |
| 7.2 | background | live × 1 + dormant × 1 | dormant | live × 1、activated true |
| 7.3 | background | live × 2 + dormant × 1 | live 1 枚 | live × 1 + dormant × 1、activated true |
| 7.4 | background | live × 1 + dormant × 1 | 最後の live | dormant × 1、activated false |
| 7.5 | background | live × 1 | 最後の live | 0 tab、activated false |
| 7.6 | active | live × 1 + dormant × 1 | 最後の live | `removeTab` 直後は dormant × 1、activated false、outcome は `.reselectActive` |
| 7.7 | active | live × 1 | 最後の live | 0 tab、active workspace は維持、activated false、outcome は `.emptiedActive` |
| 7.8 | 任意 | 任意 | 非所有 tab | 配列、active index、activation、provenance、MRU の全て不変 |

#### L2: WindowController が close outcome を処理した後

| # | Given | When | Then |
| --- | --- | --- | --- |
| 7.9 | 7.6 の active workspace | `.reselectActive` を処理 | 残った選択 tab を同期 materialize するため、安定状態ではその tab と workspace は true。これは L1 の一時的 false と矛盾しない |
| 7.10 | active workspace に複数 remaining tab | close 後の hidden mount を完了 | 選択 tab から順に全 remaining tab が activated。残存tabの再選択時にMRUは4.3のとおり更新 |

**派生 UI / API の確認**:

- 7.4 / 7.5 では workspace palette が live 0 として減光し、`list_workspaces.activated == false`、dormant count は残存 pane provenance だけを数える。
- 7.3 では live tab が残るため減光せず、Attention / pill / sound の live agent 集計を落とさない。
- live tab を close した pane の dormant-restored count を過去値として残さない。count は現存 pane だけから導出する。

### 8. Activation は永続化せず、復元時の実 materialization から再構築する

**分類**: 現状挙動  
**種類**: 永続化 / 回帰 / テスト fixture 移行  
**テストレベル**: L1 + L2

| # | Given | When | Then |
| --- | --- | --- | --- |
| 8.1 | live / dormant が混在する複数 workspace | snapshot を保存 | workspace / tab activation bit は永続 schema に書かれない。既存 schema の workspace metadata、tab / pane 構造、cwd、agent command / session ID 等だけが保存対象 |
| 8.2 | 8.1 の snapshot | 再起動し、背景 workspace をまだ前面化しない | 背景 workspace の全 tab は dormant、workspace は false。復元 agent provenance と dormant count は pane ごとに復元 |
| 8.3 | 保存済み active workspace が非空 | WindowController 復元 | 選択 tab は同期 materialize され workspace true、hidden tab は順次 materialize |
| 8.4 | 保存済み active workspace が 0 tab | WindowController 復元 | active true / activated false / tab 0。`lastUsedAt` だけは foreground use として更新し、その他の永続 field は保持 |
| 8.5 | 復元後の dormant 背景 workspace | 新規 tab を背景 spawn | 6 の mixed state を作り、保存済み tab を自動 resume しない |
| 8.6 | `AttentionSnapshotTests` など、従来 `workspace.activated = ...` で状態を捏造した fixture | fixture を移行 | 純粋な投影テストでは対象 tab の `recordMaterializationStarted()`、所有境界も扱うテストでは `SessionStore.recordMaterialization(of:in:)`、統合テストでは実 mount で live 状態を作る。workspace の直接 setter は使わない |
| 8.7 | fixture が複数 workspace / tab の agent rows を検証 | live / dormant を組み立てる | 対象だけ materialize して期待集合を作る。件数 assert 後に安全な unwrap / collection comparison を使い、範囲 subscript による二次 crash を避ける |

**既存テストの更新対象**:

- `AttentionSnapshotTests`: setter fixture を tab の lifecycle fixture へ置換する。純粋な snapshot builder のテストへ不要な `SessionStore` owner 条件は持ち込まない。
- `WindowControllerRestoreTests.testRoundTripKeepsEveryFieldWhenActiveWorkspaceIsDormant`: 0 tab active workspace の `lastUsedAt` だけは復元時に更新される期待へ変更し、それ以外の field の round-trip を維持する。
- `WindowControllerControlTests`: 0 tab の `activate_workspace` 後に `active: true, activated: false, dormantAgentCount: 0` を明示確認する。
- close 系テスト: background / active、0 / dormant / one-live / multiple-live の行列を追加し、背景close・0tab化はMRU不変、前面で残存tabを再選択するcloseはMRU更新と区別する。

## 横断的な観測契約

以下の同じ domain 状態に対し、各 surface が食い違わないことを確認する。

| Domain state | Workspace palette | `list_workspaces` | Attention / pill / sound |
| --- | --- | --- | --- |
| 0 tab または all dormant | 減光、live count 0、dormant count は provenance の合計 | `activated: false` | live state なし |
| one live + dormant | 非減光。live と dormant を別集計 | `activated: true`、dormant count は未 materialize pane 分 | live tab の reported state を表示・通知 |
| multiple live + dormant | 非減光。全 live を集計 | `activated: true`、dormant count は独立 | 全 live tab の reported state を集計 |
| 最後の live close、dormant 残存（background） | 減光へ戻る | `activated: false` | close 済み live state を除去 |

live `idle` と dormant-restored agent は、現状 UI で同じ zzz に見える場合があっても意味・集計上は独立した状態とする。将来、色・ラベル・並びを変更できるよう、期待値を表示文字列の偶然の一致に固定しない。

## 実装順序とゲート

1. L1 の computed-state と owner validation を追加し、直接 setter fixture を排除する。
2. close 行列の L1 を追加し、配列除去だけで activation と dormant count が追従することを固定する。
3. MRU の L1 / L2 を追加し、背景close・0tab化・前面で残存tabを再選択するcloseの3列を固定する。
4. L2 の foreground mount、background mixed state、0 tab、復元を追加する。
5. palette / control / Attention の横断投影を追加・更新する。
6. 既存 L4 agent spawn テストを lifecycle 契約まで拡張する。
7. `swift test` を非 parallel で全件実行する。

## 将来拡張に対する制約

- 現実装の `TerminalController` は true へ進める遷移だけを提供するが、命名・集計・fixture をその実装上の制約や履歴性に依存させない。
- 将来 tab 単位の再休眠が入った場合、tab の current state を false へ戻せば workspace computed state、palette、control、Attention が自然に再計算できる構造を維持する。
- `list_panes.tabActivated` は今回公開しないが、内部の単一の正を直接投影できる余地を残す。
- pane provenance は「復元 agent が現在休眠中か」を表し、単なる復元由来の履歴 bit にしない。materialize / close / 将来の再休眠で current state として更新できる責務に置く。

## シナリオ集計

| 分類 | 仕様数 | シナリオ数 |
| --- | ---: | ---: |
| 現状挙動 | 8 | 52 |
| あるべき仕様 | 0 | 0 |
| 未確定仕様 | 0 | 0 |
| **合計** | **8** | **52** |

## 残疑義

- 仕様上の未確定事項はない。
- 実装上の既知差分はない。
- L4 は lifecycle / foreground 非干渉 / pane 利用可能性を担い、Attention・pill・sound の詳細行列は live-attention 仕様の L2 が担う。この層分担を崩して同じ投影をプロセステストへ重複搭載しない。
- 7.6 の `removeTab` 直後に workspace が一時的に false となり、WindowController が残 tab を同期 materialize した後に true へ戻る遷移は、domain と host の観測時点の違いとしてテストを分離する。安定 UI 状態だけを見て「最後の live close 後は必ず false」と固定しない。
