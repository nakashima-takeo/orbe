# テスト仕様書: Issue #131 — activated タブの live attention 投影

> plan-test が導出しながら書き、検分を経て implement-test に引き渡す文書。実装中の照合に使い、**実装が完了したら役目を終える**——以後は振る舞い単位で命名されたテスト自体が仕様書になる。

## 対象の概要

Issue #131 で導入したタブ単位の activation を、Attention snapshot・メニューバーの一過性ピル・通知音・TopBar の live rollup・アクティブworkspaceのタブグリフへ一貫して投影する振る舞いを対象とする。live の境界は surface pointer の瞬間値ではなく `TerminalController.activated` であり、`Workspace.activated` は `tabs.contains(where: \.activated)` から導出される現在値である。同じ workspace 内に activated タブと未activatedタブが同居してよく、最後のactivatedタブが閉じられればworkspaceもfalseへ戻る。

主要な流れは次のとおり。

1. 背景 workspace への `openTab` が、新規タブをオフスクリーンで materialize する前にtabをactivatedにし、owner workspaceのcomputed値も同じturnにtrueとなる。
2. `controlReportAgent` が agent state をペインへ反映し、waiting / done への実変化を transient と sound へ渡す。
3. `paneAgentStateChanged` が chrome 再投影を要求し、`flushChrome` が同じ時点の TopBar rollup と `AttentionStore` snapshot を更新する。
4. 各面は activated タブだけを live として数え、同じ workspace に残る未activatedタブの状態は、直接注入されていても表示・通知しない。tab close後の再投影も同じ導出値を読み、消えたlive行・件数・ピルを取り下げる。

三角測量の根拠は以下。

- 現行コード: `Workspace.activated` はtab配列から導出され、`AttentionSnapshot.rows`、`WindowController.attentionRow(for:)`、`WindowController.workspace(of:)`、`Workspace.agentCounts()` はいずれも activated タブだけを対象にする。`WindowController.flushChrome()` は `AgentRollup.grandTotal`、タブグリフ、Attention snapshotを同じcoalesce契機で更新する。`closeTab` は集合変更後にchromeを再投影する。
- ドメイン契約: `docs/spec/platform/workspace.md` はworkspace activationの導出、0tab=false、最後のactivated tab close後のfalse復帰を定義する。`docs/spec/palette/attention.md`、`docs/spec/chrome/menubar.md`、`docs/spec/agent/sound.md` は、背景 workspace で materialize 済みのタブを対象に含め、同じ workspace の未materializeタブを除く。`docs/spec/chrome/chrome.md` は TopBar の live 件数とタブグリフを activated タブに限定する。
- 呼び手の期待: `controlReportAgent` は waiting / done の実変化だけ transient / sound を起動し、その後の `paneAgentStateChanged` で chrome と Attention を再投影する。背景 `openTab` は前面 workspace とMRUを変えず、新規 1 タブだけを materialize する。`closeTab` の呼び手は閉鎖後の集合をpalette/chrome/Attentionへ追従させることに依存する。

- 既存テスト資産・慣習の所在:
  - L1: `Tests/OrbeTests/AttentionSnapshotTests.swift`。値を直接組む pure builder テスト。
  - L2: `Tests/OrbeTests/WindowControllerReportAgentTests.swift`、`+Reprojection.swift`、`+Sound.swift`。実 `WindowController`・NSWindow・libghostty と `SoundPlayerFake` を使う。
  - L2: `Tests/OrbeTests/ChromeStatusRowTests.swift`。`paneAgentStateChanged → flushChrome → statusModel` の配線を観察する。
  - L4 の背景 surface の read / input / size / 非前面化は `Tests/OrbeTests/OrbeCliAgentProcessTests.swift` の既存テストが担当する。本仕様では同じ重い導通を重複させず、状態投影は L2 で測る。
  - 全テストは XCTest と `OrbeTestCase` を踏襲し、管理下の `WindowController`・`AttentionStore`・libghostty は実物、音声出力だけ既存 Fake で観察する。

### fixture 移行と新しい契約テストの区別

`AttentionSnapshotTests.workspace(name:activated:)` は旧モデルの `Workspace.activated` setterへ直接代入する。commit `394024c` でworkspace値はget-onlyのcomputed propertyになったため、このfixtureはコンパイル不能であり、仮にsetterだけ残してもtabをactivatedにしないlive fixtureは契約と矛盾する。

既存テストがliveを要求するときは、tabをworkspaceへ追加してから `TerminalController.recordMaterializationStarted()`（またはowner検証も含む `SessionStore.recordMaterialization`）でtabをactivatedにする。workspaceは書き換えず、computed値がtrueになったことをfixture前提として確認する。休眠fixtureはtabを未activatedのまま置く。fixture修正だけで緑へ戻す既存テストは、下記の新しい混在・close契約を保証したことには数えない。新規テストでは activated タブと未activatedタブを同一 workspace に明示的に置き、両者へ状態を立てて差を観測する。

## 保証する仕様

### activated タブだけが Attention snapshot と live rollup の母集合になる

- 分類と根拠: **現状挙動**。実装は `Workspace.activated == any(tab.activated)` を常に導出し、`AttentionSnapshot.rows` と `Workspace.agentCounts()` の双方で `tab.activated` を絞る。仕様書も activated タブだけを live と定義する。workspace値は独立入力ではなく、同じworkspaceにactivated siblingがあるかでfalse/trueが決まる。
- モデルとカバレッジ基準: 条件組合せのデシジョンテーブル。tab activation、activated siblingの有無、agent stateの有効クラスを組み合わせ、正当な全列を少なくとも1回通す。computed propertyでは到達不能な `tab.activated == true && workspace.activated == false` はfixtureで捏造しない。

| tab | activated sibling | computed workspace | agent state | Attention row | live rollup |
|---|---|---|---|---|---|
| activated | 任意 | true | waiting / done / working | 含む | 同じstateで含む |
| activated | 任意 | true | idle | 除外 | idleとして含む |
| activated | 任意 | true | nil / 未知状態 | 除外 | 除外 |
| 未activated | あり | true | 任意の注入状態 | 除外 | 除外 |
| 未activated | なし | false | 任意の注入状態 | 除外 | 除外 |

| シナリオ | 層 | 優先度 | 備考 |
|---|---|---|---|
| activated タブの waiting / done / working は Attention 行と同名の live rollup 状態へ入る | L1 | 高 | 各状態クラスを通す |
| activated タブの idle は Attention には出ず live rollup の idle へだけ入る | L1 | 中 | 2面の対象集合の意図的な差 |
| activated タブの nil と未知状態は Attention / live rollup の双方へ出ない | L1 | 中 | 無効クラス |
| mixed workspace内の未activated siblingタブへwaiting / doneを直接注入しても、workspaceはactivatedのままAttention / live rollupへは出ない | L1 | 最高 | Issue #131 の混在モデルを固定する新規契約。旧fixture移行では代替不可 |
| 完全休眠 workspace の未activatedタブへ状態を直接注入しても、Attention / live rollupへ出ない | L1 | 高 | 既存 dormant 除外の粒度をtabモデルで維持 |
| 複数 workspace の activated タブは現在の `activeWorkspace` に関係なく横断集計される | L1 | 高 | 背景 workspace のliveを落とす退行を検知 |

### 背景 workspace で materialize したタブの waiting / done は三つの注意喚起面へ届く

- 分類と根拠: **現状挙動**。`openTab` の背景分岐は `recordMaterialization` を通して新規タブをactivatedにしてからattachし、owner workspaceのcomputed値もtrueになる。Attention・transient・soundはそのactivatedタブを走査する。背景経路は`recordWorkspaceUse`を呼ばないためMRUは変えない。関連仕様書はいずれも背景materialize済みタブを対象と明記する。
- モデルとカバレッジ基準: 正常シーケンスと、同一workspaceに未activated siblingが残る分岐。waiting / done の両イベントについて `background openTab → report → transient/sound → flush → snapshot/TopBar` を通し、旧バグの全観測面を検査する。

```text
背景workspace（既存の未activated復元タブあり）
  └─ openTabで新規タブだけmaterialize
       └─ waiting / doneへ実変化
            ├─ Attention snapshotに行
            ├─ transientに同じpaneの行
            ├─ soundに対応event
            └─ TopBar live rollupに同じstateを1件
```

| シナリオ | 層 | 優先度 | 備考 |
|---|---|---|---|
| 背景workspaceへ新規作成・materializeしたタブがwaitingへ変化すると、Attention行・transient・waiting音・TopBar waiting 1件へ届く | L2 | 最高 | Issue #131 の直接回帰テスト。`activeWorkspace` とowner workspaceの`lastUsedAt`は不変、computed `activated`はtrueをassertする |
| 同じ背景タブがdoneへ実変化すると、Attention行・transient・done音・TopBar done 1件へ届く | L2 | 最高 | waitingと音eventが異なるため別シナリオ |
| 同じ背景workspaceに残る未activated siblingタブへwaiting / doneを直接報告しても、Attention・transient・sound・TopBarのいずれにも追加されない | L2 | 最高 | new tabだけ起こす混在状態を一つの実fixtureで測る |
| 背景タブの報告後も Attention とTopBarが同じactivatedペイン集合・状態別件数を示す | L2 | 高 | waiting/done/workingの共通集合だけ比較し、Attentionが意図的に除くidleは比較対象外 |

### activatedタブのcloseはcomputed workspaceと注意喚起を同じ集合へ戻す

- 分類と根拠: **現状挙動**。`SessionStore.removeTab` はタブをworkspace配列から外し、背景workspaceなら`.backgroundChanged`を返す。`WindowController.closeTab` はその分岐でも`refreshChrome()`を呼び、次の`flushChrome()`がcomputedな`Workspace.activated`、TopBar rollup、Attention snapshotを再読込する。`AttentionStore.apply`は投影元のpane/stateがlist rowsから消えたtransientをretractedにする。`docs/spec/platform/workspace.md`も最後のactivatedタブclose後に全tab休眠ならworkspace=falseへ戻ると定義する。
- モデルとカバレッジ基準: 状態遷移。背景workspaceのactivatedタブ数を2/1、休眠タブ数を1としてactivatedタブを閉じ、非最終と最終の全有効遷移を通す。アクティブworkspaceでは残存タブを`select`して即materializeするため、再休眠の境界は背景workspaceで検査する。

| close前 | イベント | close後 | Attention / TopBar | transient |
|---|---|---|---|---|
| activated 2 + dormant 1 | activated 1枚をclose | activated 1 + dormant 1、workspace=true | 閉じたpaneだけ除外、残るliveは維持 | 閉じたpaneを指せばretracted |
| activated 1 + dormant 1 | 最後のactivatedをclose | dormant 1、workspace=false | 当該workspaceのlive投影は0 | 当該paneを指せばretracted |

| シナリオ | 層 | 優先度 | 備考 |
|---|---|---|---|
| activatedタブが複数あるmixed背景workspaceで1枚を閉じると、workspaceはtrueのまま、閉じたpaneのAttention行・TopBar件数だけが消え、残るlive投影は維持される | L2 | 高 | transientが閉じたpaneを指していればretractedも確認する |
| mixed背景workspaceの最後のactivatedタブを閉じると、未activated siblingだけが残ってcomputed workspaceはfalseとなり、Attention行とTopBar件数が消え、対応transientがretractedになる | L2 | 最高 | Issue #131の現在状態モデルとclose後reprojectionを一つの本番経路で固定する。closeでMRUは動かない |

### transient と通知音は eligibility に加えて「実変化」と可視性を守る

- 分類と根拠: **現状挙動**。`controlReportAgent` は waiting / done への実変化だけを二つの通知へ渡し、両consumerは見ているタブを抑制する。未activatedタブはowner探索で対象外になる。既存の通知仕様は変更せず、tab eligibilityを一段追加した形である。ただし見ているタブの `done` は通知抑制だけで終わらず、続く `paneAgentStateChanged` から `consumeVisibleTabDone()` が走って `idle` へ消費される（`Sources/Orbe/App/Layout/WindowController.swift:186-189,271-273`、既存検査 `Tests/OrbeTests/WindowControllerReportAgentTests.swift:190-207`）。
- モデルとカバレッジ基準: 条件組合せのデシジョンテーブル。activated、状態変化、対象state、visibleの主要列を全て通す。

| tab | 実変化 | state | 見ているタブ | transient / sound |
|---|---|---|---|---|
| activated | yes | waiting / done | no | 発火 |
| activated | no | waiting / done | no | 発火しない |
| activated | yes | working / idle / clear | no | 発火しない |
| activated | yes | waiting / done | yes | 発火しない |
| 未activated | yes | waiting / done | no | 発火しない |

| シナリオ | 層 | 優先度 | 備考 |
|---|---|---|---|
| activatedかつ見ていないタブのwaiting / done実変化だけがtransientと対応音を発火する | L2 | 高 | 既存テストを維持 |
| 同値のwaiting / done報告、working、idle、clearはtransient / soundを発火しない | L2 | 高 | デシジョンテーブルの非対象state全列を維持 |
| waitingのピルが立ったペインがidleへ変化すると、新しいピル・音は発火せず、Attention行は消え、TopBarはidleへ移り、既存ピルはretractedになる | L2 | 高 | idleは「通知対象外」だがlive rollup対象。発火と既存投影の取り下げを別々に検査する |
| waitingのピルが立ったペインが未知状態（代表値`error`）へ変化すると、新しいピル・音は発火せず、Attention / TopBar / タブグリフから消え、既存ピルはretractedになる | L2 | 高 | unknownはidleと異なりlive rollupにも数えない。`AgentRollup.countedStates`と`aggregateAgentState`の両境界 |
| waitingのピルが立ったペインがclearされると、新しいピル・音は発火せず、状態・Attention / TopBar / タブグリフが消え、既存ピルはretractedになる | L2 | 高 | clearは未知文字列ではなく`agentState=nil`への遷移。unknownと同じ1ケースに畳まない |
| 見ているactivatedタブのwaitingはtransient / soundだけ抑制され、AttentionとTopBarのwaitingには残る | L2 | 高 | 注意喚起面と常時表示の差を固定 |
| 見ているactivatedタブのdoneはtransient / soundを抑制した後にidleへ消費され、Attentionには残らずTopBarのidleへ入る | L2 | 高 | `WindowController.swift:186-189,271-273` の既存フォーカス消費契約を固定 |
| 見ていない別タブならwindowがkeyでもtransient / soundが発火する | L2 | 中 | 可視性の粒度はpaneやworkspaceでなくtab |
| 通知音はactive workspaceでなく発信元のactivatedタブが属するworkspaceの実効設定を使う | L2 | 高 | 既存origin overrideテストを維持 |

### Attentionの既存表示規則はlive fixtureへ移行後も維持される

- 分類と根拠: **現状挙動**。activationの母集合以外はcommit `3eeefa2`で変更されておらず、Attention仕様も状態集合・並び・message・メニューバー派生を維持している。現在の失敗はfixtureがtabをactivatedにしていないためで、これらの期待値を変更する根拠はない。
- モデルとカバレッジ基準: 入力分割と順序。既存の状態クラス、時刻境界、同時刻tie、message有無、working集約を全て維持する。各live fixtureは対象タブもactivatedにする。

| シナリオ | 層 | 優先度 | 備考 |
|---|---|---|---|
| idle / nilを除きwaiting / done / workingだけを行にする | L1 | 高 | **fixture移行**。workspaceだけでなくtabもactivatedにする |
| stateChangedAt降順、同時刻はpaneId降順で安定化する | L1 | 高 | **fixture移行**。空配列のindex参照を防ぐため、先に行数または全配列の期待値をassertしてからtie部分を見る |
| workingのmessageはnilへ落とし、waiting / doneのmessageは保つ | L1 | 中 | **fixture移行** |
| メニューバー一覧はwaiting / doneだけ、working summaryはペイン件数とworkspace名の重複排除・出現順を返す | L1 | 中 | **fixture移行**。手組みした2タブも両方activatedにする |
| 経過時間の負値・秒/分/時/日境界を従来どおり変換する | L1 | 低 | activationと無関係。既存テストを無変更で維持 |

### TopBarはactivatedタブのlive状態だけを件数とタブグリフへ投影する

- 分類と根拠: **現状挙動**。`flushChrome` は `AgentRollup.grandTotal(of:)` を `working → waiting → done → idle` の順へ整列して `statusModel` に渡し、各タブのグリフも未activatedなら `nil` にする（`Sources/Orbe/App/Layout/WindowController.swift:320-328`）。`Workspace.agentCounts()` が未activatedタブを除くため、背景workspaceのactivatedタブは入り、同居する未activatedタブは入らない。`docs/spec/chrome/chrome.md:45-59` もタブグリフと横断件数の両方をmaterialize済みタブに限定する。
- モデルとカバレッジ基準: 入力分割と結合配線。counted stateの全クラス・0件・複数workspace・混在tabをL1で、reportからstatusModelの横断件数とタブグリフまでをL2で通す。

タブグリフは横断件数と同じ値をそのまま描くのではなく、**現在のworkspaceの各tabごと**に次の別規則で畳む。ここを件数テストだけで代用しない。

| tab | tab内のagent state集合 | status glyph |
|---|---|---|
| 未activated | waiting / working / doneを含む任意の注入状態 | nil |
| activated | nil / idle / 未知状態（`error`等）のみ | nil |
| activated | done（ほかはnil / idle / unknown） | done |
| activated | working + done | working |
| activated | waiting + working + done | waiting |

背景workspaceのactivated tabは横断rollupには入るが、`StatusRowModel.titles/glyphs`は現在のworkspaceのタブ列だけを表すため、背景にいる間はタブグリフ列へ追加されない。workspaceを前面化した後は、そのtabが持つlive stateからグリフを導出する。ただし選択されて見えるtabのdoneは既存のフォーカス消費でidleへ変わるため、「同じstateを必ず維持する」とはしない。

| シナリオ | 層 | 優先度 | 備考 |
|---|---|---|---|
| activatedタブのworking / waiting / done / idleをペイン単位で合算し、0件を落として正準順で返す | L1 | 高 | AgentRollupのpure契約 |
| mixed workspaceの未activatedタブへ注入されたcounted stateはgrand totalへ加算しない | L1 | 最高 | Issue #131 の混在境界 |
| activatedタブのグリフはwaiting > working > doneで畳み、idle / nil / unknownだけならnilになる | L1 | 高 | `TerminalController.aggregateAgentState`の全同値クラスと優先順位を固定する |
| activatedタブのagent state変化は`paneAgentStateChanged → flushChrome`でTopBarへ届く | L2 | 高 | 既存Chrome配線を維持 |
| 未activatedタブの直接報告がchrome再投影を要求してもTopBar件数は増えない | L2 | 高 | 通知要求と対象選定を混同しない |
| mixedな現在workspaceではstatusModelのglyphsがtab順を保ち、activated tabだけに上表のグリフ、未activated siblingにはnilを返す | L2 | 最高 | workspace-level `activated == true`だけで全tabへグリフを漏らす退行を検知する |
| waitingを持つ背景workspaceのactivatedタブは横断rollupへ入るが現在workspaceのタブグリフ列へは入らず、前面化後にwaitingグリフが現れる | L2 | 高 | 横断面とcurrent-workspace面の対象範囲を区別する。doneは前面化時のフォーカス消費があるため代表値にしない |
| hidden mount途中の未activatedタブへ状態を注入し再投影してもそのタブのグリフはnilで、materialize後にagent報告経路で再投影すると同じ状態がグリフへ現れる | L2 | 高 | `WindowController.swift` のtab activation gate。materialize単独はchrome更新契機ではないため、後段は本来の報告経路まで通す。件数だけではこの退行を検知できない |

## リスク・注意点

- pure fixtureで `Workspace.activated = true` を使うことはできない。fixture helperは対象tabだけを明示的にactivatedへ進め、workspaceのcomputed値を確認する。mixed fixtureではlive側のtabだけを進める。
- `rows[0]` や `rows[1...2]` を期待値確認より先に使うと、eligibility退行がXCTest failureではなくprocess fatalになる。まず行数または全pane/workspace配列をassertし、`XCTUnwrap`等で安全に要素を取り出す。
- live eligibility の判定に `surfacePtr` を使うテストへ寄せない。契約上の単一の正はtabの**現在状態** `activated` で、現行遷移はmaterialize開始前にtrueへ進む。現実装がsurface生成失敗時に自動rollbackしないことを「履歴bitである」という永続契約には格上げせず、将来の再休眠・失敗復旧でfalseへ戻せる余地を残す。
- 見ているタブの `done` は通知だけが抑制されるのではなく、同じ報告経路内で `idle` へ消費される。可視 `waiting` と一括して「Attention/TopBarへ同じstateで残る」と期待しない。
- 背景workspaceのL2 fixtureは、既存復元タブと新規tabの双方を持たせる。新規tabだけのfixtureではIssue #131は再現できても、混在workspaceのdormant siblingを誤ってliveへ混ぜる退行を捕まえられない。
- soundの観察は既存 `SoundPlayerFake` を使い、AppKit/Attention/rollupは管理下の実物を使う。内部helperの呼出回数はassertしない。
- L4の背景spawn usabilityテストは既存資産を維持するが、本仕様の三面投影をそこへ過積載しない。L2で同じ本番ドメイン経路を通せるため、process起動・文字待ちのflakyコストを増やさない。

## 残った前提

なし。未確定・既知バグの固定化・対象外とする契約変更はない。旧fixtureのsetterコンパイル失敗は、tab activationをfixtureへ反映することで解消するテスト側の移行事項である。
