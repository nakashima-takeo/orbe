# テスト仕様書: 休眠agent由来とmixed workspaceの投影

> plan-test が導出しながら書き、検分を経て implement-test に引き渡す文書。実装が完了したら、振る舞い単位で命名されたテスト自体を契約の正とする。

## 対象の概要

永続復元したagent付きleafを、タブがmaterializeされるまでpane単位の休眠agentとして保持し、現在残るpane treeから件数を導出する。workspace内でactivatedタブと未activatedタブが混在するとき、live状態とdormant件数を二重計上せずにworkspaceパレットと`list_workspaces`へ同時投影する。

主要な呼び手は`WindowController.reloadPalette()`、`controlListWorkspaces()`、TopBarの横断集計である。休眠数の正は`SurfaceView.holdsDormantRestoredAgent`と現在のpane tree、live数の正はactivatedタブ内の`agentState`である。`active`（現在前面か）、workspaceの`activated`（配下にactivatedタブが1枚以上あるかという現在値）、dormant件数（未activatedタブに残る復元agent数）、`lastUsedAt`（前面で利用したMRU）は独立した軸として扱う。

- 既存テスト資産・慣習の所在: `Tests/OrbeTests/WindowControllerWorkspaceTests.swift`（復元数・パレット結合）、`WindowControllerControlTests.swift`（`list_workspaces`）、`WindowControllerPaneTabControlTests.swift`（`close_pane`/`close_tab`とmain queue drain）、`AgentStateIconTests.swift`・`StatusGlyphTests.swift`（`dormant`の状態・字形）。L1は値を直接組み、L2は`OrbeTestCase`の隔離下で実`WindowController`・実NSWindow・実libghosttyを使う（`docs/testing/test-architecture.md`）。
- fixture規律: liveとして扱うタブは、必ず正規の`SessionStore.recordMaterialization(of:in:)`または実mount経路でactivatedにする。`Workspace.activated`はread-onlyの導出値なので直接代入しない。旧fixtureのsetter代入はコンパイル不能であり、新しい状態モデルを作るfixtureへ更新する。
- 公開JSONは追加フィールドを許容するopen-world契約として検査する。既存必須フィールドを確認するが、将来の`tabActivated`追加を妨げる「キー集合の完全一致」や「`tabActivated`が存在しないこと」のassertは置かない。

## 保証する仕様

### 復元agentの由来はmaterialize前だけ、現在残るpane単位で数えられる

- 分類と根拠: **現状挙動**。`TerminalController.buildView`は復元元`PaneNode.leaf`の`agent != nil`を、resume commandへ解決できる場合もできない場合も`holdsDormantRestoredAgent = true`として保持する。新規paneは既定false。`restoredAgentCount`は固定保存値でなく`controlAllPanes()`上のflagを数える（`Sources/Orbe/App/Layout/TerminalController.swift:58-62,116-130`、`Sources/Orbe/Core/Terminal/SurfaceView.swift:73-76`）。計画書「状態モデルと唯一の遷移規則」と`docs/spec/palette/workspace.md:39-45`も同じ契約を定義しており、旧テストの期待更新は製品バグの固定ではない。
- モデルとカバレッジ基準: 条件組合せ。復元元agent有無 × resume解決可否 × paneが現在treeに残るかの有効列を網羅する。

| シナリオ | 層 | 優先度 | 備考 |
|---|---|---:|---|
| agent付きleafをresume commandへ解決できる場合、materialize前の休眠数に1件入る | L1 | 高 | 復元時にcommand/sessionを再設定する経路も通す |
| agent付きleafをresume非対応で素シェル化する場合も、materialize前の休眠数に1件入る | L1 | 高 | 既存`testRestoredAgentCountIncludesResumeUnsupported`を新しい由来モデルの契約へ更新 |
| agent無しの復元leafと新規タブのpaneは休眠数に入らない | L1 | 中 | 無効クラス |
| agent付き・agent無しが混ざるsplit treeではagent付きleafだけを合計する | L1 | 高 | 複数leaf境界 |

### タブの起床開始で休眠由来をlive側へ移し、二重計上しない

- 分類と根拠: **現状挙動**。`recordMaterializationStarted()`は初回だけtabをactivatedにし、全paneの`holdsDormantRestoredAgent`をfalseへ落とす。`Workspace.agentCounts()`はactivatedタブだけ、`dormantAgentCount()`は未activatedタブだけを見る（`Sources/Orbe/App/Layout/TerminalController.swift:188-194`、`Sources/Orbe/Features/Agent/AgentRollup.swift:36-50`）。計画書の「materialize開始時にlive側へ移す」および`docs/spec/chrome/chrome.md:57-61`、`docs/spec/palette/workspace.md:39-41`と一致する。
- モデルとカバレッジ基準: 状態遷移。未activated・dormant由来あり → materialize開始 → activated・dormant由来なし、再実行、無関係なagent状態変更を網羅する。

| シナリオ | 層 | 優先度 | 備考 |
|---|---|---:|---|
| 未activatedの復元agentタブはlive集計0・dormant集計Nである | L1 | 高 | 開始状態 |
| materialize開始直後は最初のhook報告前でも`restoredAgentCount`とworkspaceのdormant集計が0になり、live集計も0である | L1 | 高 | provenanceの消去と、報告前のlive空白を固定 |
| materialize開始後はhook報告済みagentStateだけがlive集計され、復元agent数との二重計上はない | L1 | 高 | live側の母数は復元payloadでなく現在state |
| materialize開始を二度記録してもactivatedと集計結果は変わらない | L1 | 中 | 冪等遷移 |
| activatedタブに残存flagを人工的に立ててもworkspaceのdormant集計には入らない | L1 | 中 | consumer側の防御。不変条件を壊したfixtureでも二重計上しない |

### pane・tab閉鎖へdormant件数とworkspaceの現在状態が追従する

- 分類と根拠: **現状挙動**。`restoredAgentCount`は現在のpane treeから導出され、`TerminalController.close`はsplit leafを同期でtreeから除く（`Sources/Orbe/App/Layout/TerminalController.swift:315-348`）。最後のpaneだけはleafをその場で外さずmain queueへ`onEmpty`を積み、`controlClosePane`のdomain resultは先にsuccessとして確定する（同`:317-320`、`Sources/Orbe/Features/Control/WindowController+Control.swift:133-140`）。`docs/spec/control/api.md:55`は実ソケット応答もteardownより先とする意図を明記するが、下記の残疑義どおり別queue間の配送順はこのL2だけでは保証できない。
- モデルとカバレッジ基準: 状態×イベント遷移。dormant splitの対象pane（agentあり/なし）×close、dormant tab×close、activated/dormant tabの混在×close、最後のpane closeの非同期境界を網羅する。mixed workspaceで最後のactivated tabを閉じたときは、背景workspaceならdormantだけが残ってfalseへ戻る一方、前面workspaceなら`closeTab → select`が残存tabを即materializeしてtrueを維持するため、両列を分ける（`Sources/Orbe/App/Layout/WindowController.swift:285-296`）。

| シナリオ | 層 | 優先度 | 備考 |
|---|---|---:|---|
| dormant splitからagent付きpaneを`close_pane`すると、成功後の`dormantAgentCount`が1減る | L2 | 高 | leaf除去は同期観測可 |
| dormant splitからagent無しpaneを`close_pane`しても、残るagentのdormant件数は減らない | L2 | 高 | 誤ってpane総数を数える退行を検知 |
| dormant tabを`close_tab`すると、そのtab分のdormant件数が消える | L2 | 高 | tab単位除外 |
| dormant tab最後のagent paneを`close_pane`するとdomain success返却直後はtabとdormant件数が残り、main queueの`onEmpty`処理後に両方が消える | L2 | 高 | domain result確定→遅延teardownの二段階を、既存`drainMainQueue`慣習で観測する |
| 背景mixed workspaceで最後のactivatedタブを閉じ、未activatedタブだけが残ると、`Workspace.activated`はfalseへ戻り、残存dormant件数は維持される | L2 | 最高 | storedな単調履歴への退行を検知。前面workspaceでは下のreselect経路になる |
| 前面mixed workspaceで表示中のactivatedタブを閉じると、残存tabが直ちに選択・materializeされ、`Workspace.activated`はtrue、dormant件数は0になる | L2 | 最高 | active closeの`.reselectActive → select`経路。背景closeと同じfalseを期待しない |
| activatedタブが複数あるworkspaceで1枚だけ閉じても、別のactivatedタブが残るため`Workspace.activated`はtrueのままである | L2 | 高 | any集約の境界 |
| activatedタブを最後の1枚まで閉じて0タブにすると、`Workspace.activated == false`かつlive/dormantとも0になる | L2 | 高 | 空集合境界 |
| activatedタブが残るmixed workspaceからdormantタブだけを閉じると、`Workspace.activated`はtrueのままdormant件数だけ減る | L2 | 高 | 2軸の独立性 |
| 未知pane/tabのcloseは既存エラー契約のままで、dormant件数を変えない | L2 | 中 | 既存テストとの結合。新しいsurface必須条件は追加しない |

### mixed workspaceではlive状態とdormant件数を独立集計する

- 分類と根拠: **現状挙動**。`Workspace.agentCounts()`はactivatedタブのみ、`dormantAgentCount()`は未activatedタブのみを走査する（`Sources/Orbe/Features/Agent/AgentRollup.swift:36-50`）。workspace自体がactivatedでも正のdormant件数を許し、`docs/spec/control/api.md:39`もmixed状態を公開値として定義する。
- モデルとカバレッジ基準: デシジョンテーブル。tab activated、復元agent由来、live agentStateの組合せから、computed workspace activated、live count、dormant countの全意味列を網羅する。

| シナリオ | 層 | 優先度 | 備考 |
|---|---|---:|---|
| 完全休眠workspaceはlive 0、未activatedタブに残る復元agent数Nを返す | L1 | 高 | workspace.activated=false |
| 完全起床workspaceはdormant 0、activatedタブの認識済み状態だけをlive集計する | L1 | 高 | working/waiting/done/idleと未知状態/nilの既存集合を維持 |
| mixed workspaceはactivatedタブのlive countと未activatedタブのdormant countを同時に正で返す | L1 | 最高 | Issue #131後の中心状態 |
| 0タブworkspaceは`Workspace.activated == false`かつlive 0・dormant 0である | L1 | 高 | computed empty-anyの境界。前面選択中でも同じ |
| 新規未activatedタブは復元由来を持たないためdormant countを増やさない | L1 | 中 | 境界値0 |

### workspaceパレットはlive chipとdormant chipを別種・正準順で併記する

- 分類と根拠: **現状挙動**。`reloadPalette()`は`AgentRollup.ordered(ws.agentCounts())`の後に、正なら`("dormant", count)`を1件追加し、行の減光は`!ws.activated`だけから導出する（`Sources/Orbe/App/Layout/WindowController+Palette.swift:223-235`）。`AgentStateIcon.Kind`はidleとdormantを別caseとして持ち、`WorkspaceSwitcherRow`は渡された順を保つ（`Sources/Orbe/Features/Agent/AgentStateIcon.swift:5-18,48-57`、`Sources/Orbe/Features/Workspace/WorkspaceSwitcherRow.swift:38-52`）。`docs/spec/palette/workspace.md:39-45`もlive正準順→dormant後置と減光の独立を定義する。
- モデルとカバレッジ基準: 条件組合せ。live有無 × dormant有無 × workspace activatedの列と、live state正準順を網羅する。

| シナリオ | 層 | 優先度 | 備考 |
|---|---|---:|---|
| 完全休眠でagent N件の行は減光され、`idle`ではなく独立した`dormant N` chipを出す | L2 | 高 | 既存失敗テストの期待を更新 |
| 状態語`dormant`は`idle`とは別の`AgentStateIcon.Kind.dormant`へ写り、休眠用zzzを表示できる | L1 | 高 | idleの意味・色・アイコンを休眠表示へ流用しない |
| mixed workspaceは減光せず、live chipsを`working → waiting → done → idle`、最後に`dormant`の順で併記する | L2 | 最高 | idleとdormantが同時に存在するcaseを必須にする |
| 完全起床workspaceは減光せずlive chipsだけを出す | L2 | 高 | dormant 0はchip無し |
| 完全休眠でも復元agent 0件なら減光だけでchipを出さない | L2 | 中 | 0境界 |
| workspaceを前面化し選択タブだけが先にmaterializeされた途中では、行は減光せず残るhidden tab分のdormant chipを保持する | L2 | 高 | 非同期hidden mountの途中状態を表現 |
| 背景mixed workspaceで最後のactivatedタブを閉じてdormantタブだけが残ると、行は再び減光され、dormant chipは残る | L2 | 最高 | close後のcomputed状態を即時再投影。前面workspaceは残存tabをmaterializeするためこの状態に留まらない |
| 前面の0タブworkspaceは選択表示中でも`dormant == true`で減光モデルになり、chipは出さない | L2 | 高 | `active` highlightと休眠減光は独立。描画上の合成色ではなくmodelを検査 |

### `list_workspaces`はmixed状態を返し、既存Control APIを狭めない

- 分類と根拠: **現状挙動**。`controlListWorkspaces()`はworkspaceのactivated値と、workspace状態で0へ潰さない`dormantAgentCount()`を別々に返す。`controlListPanes()`は`store.allPanes()`から全workspaceを列挙し、既存フィールドを維持する（`Sources/Orbe/Features/Control/WindowController+Control.swift:6-31`）。`docs/spec/control/api.md:39-40`は返却フィールドを列挙する一方、キー集合の閉包や追加禁止は定めていないため、既存必須キーだけを検査するopen-world契約が妥当である。
- モデルとカバレッジ基準: デシジョンテーブル。`active` × `activated` × dormant countの代表的な有効組合せ、およびclose後の再投影を網羅する。

| シナリオ | 層 | 優先度 | 備考 |
|---|---|---:|---|
| 全workspace行に`activated: Bool`と`dormantAgentCount: Int`が存在する | L2 | 高 | 既存フィールド契約 |
| 背景mixed workspaceは`active == false`、`activated == true`、`dormantAgentCount > 0`を同時に返す | L2 | 最高 | 3軸の混同を検知 |
| 前面workspaceでもhidden tabの起床途中なら`active == true`、`activated == true`、正のdormant件数を返し得る | L2 | 高 | hidden mount完了前の一時状態 |
| 前面の0タブworkspaceは`active == true`、`activated == false`、`dormantAgentCount == 0`を返す | L2 | 最高 | activeとactivatedの独立境界 |
| 完全起床後は`dormantAgentCount == 0`、完全休眠は復元agent数Nを返す | L2 | 高 | 両境界 |
| dormant agent paneをcloseした後、次の`list_workspaces`は減った現在値を返す | L2 | 高 | 固定スナップショットへの退行を検知 |
| 背景workspaceの最後のactivatedタブを閉じてdormantタブだけが残ると、次の`list_workspaces`は`activated == false`と残存dormant件数Nを返す | L2 | 最高 | computed current stateへの回帰を検知。前面workspaceはreselectで残存tabを起こす |
| `list_panes`は休眠workspaceを含め、paneId/workspaceId/tabId/workspaceName/title/cwd/agentState/agentSessionId/focusedの既存フィールドを保つ | L2 | 中 | JSONの追加フィールドは許容し、将来の`tabActivated`追加を禁止しない |

### lifecycle投影とworkspaceのMRUはイベントの意味に沿って独立する

- 分類と根拠: **現状挙動**。`lastUsedAt`はworkspaceを前面で利用した時刻であり、`SessionStore.recordWorkspaceUse`だけが更新する。背景materializeと背景workspaceのtab/pane closeは前面文脈を変えないためMRUを維持する。一方、前面workspaceでtabを閉じて別tabが残る場合は、そのtabを実際にreselect・前面表示する`closeTab → select → recordSelection`経路を通るためMRUを更新する。前面workspaceが0tab化するcloseは次のtabを表示しないためMRUを更新しない（`Sources/Orbe/App/Layout/WindowController.swift:285-296`、`Sources/Orbe/Features/Workspace/SessionStore.swift:118-132`）。
- モデルとカバレッジ基準: 状態×イベント。background materialize / background close / foreground close（残存tabあり・0tab化）を比較し、前面利用が新たに成立する列だけstampが進むことを網羅する。

| シナリオ | 層 | 優先度 | 備考 |
|---|---|---:|---|
| 背景workspaceのtabをmaterializeしてmixed状態にしても、ownerの`lastUsedAt`とworkspaceパレットのMRU順は変わらない | L2 | 高 | activationと前面利用を分離 |
| 背景workspaceのactivated/dormant tabまたはpaneをcloseして投影値が変わっても、ownerの`lastUsedAt`とMRU順は変わらない | L2 | 高 | background closeはreselectしない |
| 前面workspaceでtabをcloseし残存tabをreselect・前面表示すると、`lastUsedAt`が進みMRU順へ反映される | L2 | 高 | 内部cleanupではなく、次tabを実際に表示し続ける利用イベント |
| 前面workspaceの最後のtabをcloseして0tab化すると、次tabの前面表示は無いため`lastUsedAt`を維持する | L2 | 中 | `clearActiveContent`経路 |

## 実装時の注意

- 旧`testListWorkspacesActiveWorkspaceReportsZeroDormantAgentCount`は、起動直後にactive workspaceの全tabがmaterialize済みなので結果0自体は今も正しいが、テスト名と理由が旧二分法を固定している。完全起床境界として改名・再記述し、別にmixed workspaceの正数ケースを追加する。
- 旧`testDormantAgentCountSumsTabs`は全tab未activatedという前提を明記する。activated tabを混ぜるcaseは別シナリオに分ける。
- dormant splitのleaf closeは`onLayoutChange`からchrome再投影と保存だけを要求し、現在は`reloadPalette()`を呼ばない（`Sources/Orbe/App/Layout/WindowController.swift:176-189`）。最後のpaneからtab closeへカスケードした場合だけ`closeTab`がパレットも再読込する（同`:275-300`）。したがってsplit closeのシナリオは現在値を`dormantAgentCount`/`list_workspaces`で観測し、開いたパレットの即時更新も非更新も固定しない。
- パレットを開いたままagent報告だけでリアルタイム再読込しない現行境界は今回の変更対象ではないが、「更新しないこと」をテストで固定しない。将来の安全なライブ更新を妨げないためである。
- `list_panes`に`tabActivated`が無いこともテストで固定しない。既存必須フィールドの後方互換だけを守り、将来の読み取り専用追加を許容する。
- 背景materializeと背景workspaceのtab/pane closeは`lastUsedAt`を変更しない。前面workspaceのtab closeで残存tabを実際にreselect・表示する場合はMRUを更新し、0tab化して空表示になる場合は維持する。この時間軸を「closeは常に不変」や「closeは常に更新」のどちらにも畳まない。
- `docs/spec/platform/workspace.md`の「tab closeではMRUを動かさない」という包括表現は、前面workspaceで残存tabをreselectする列を除外しておらず上記契約と食い違う。製品spec側を「背景closeと0tab化は維持、前面で次tabを表示するcloseは更新」へ追随させる。
- `Workspace.activated`を「過去に一度でも起きた」という単調履歴としてassertしない。現実装でtabがfalseへ戻るのはcloseで集合から外れたときだけだが、将来tabの再休眠遷移が追加されても、palette/controlはtab集合の現在状態から再投影できる契約に保つ。再休眠時のPTY停止と`holdsDormantRestoredAgent`再構成そのものは今回のテスト対象外。

## 対象外の配送順疑義

- `ControlServer.handle`はmain上でdomain resultを得た後、実応答をcontrol queueへenqueueする（`Sources/Orbe/Features/Control/ControlServer.swift:222-227`）。最後のpaneの`onEmpty`もmain queueへenqueue済みであり、別queue間には「応答バイト送信完了→teardown」のhappens-beforeがない。上記L2が保証するのはdomain result先行とmain queue drain後のprojectionであり、wire上の応答配送順ではない。この疑義はdormant件数・mixed projectionのシナリオ解釈を未確定にはしない。`docs/spec/control/api.md:55`の実配送順を別途保証するなら、自己paneからcloseするwire/process対象として切り出し、必要なら製品側の明示的な応答完了後teardown設計を判断する。
