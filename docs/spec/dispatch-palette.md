---
title: Dispatch パレット（現状）
description: Cmd+Shift+X で開くコマンドパレット — worktree/ブランチ/Issue/PR を git・gh 実データで列挙し、フィルタ・⇥ で起動先（検出 agent／素の shell）切替・Enter で選択行の対象ディレクトリに起動先を新タブ起動・⌘↵ で issue/PR および open PR に紐づく worktree/ブランチ行をブラウザで開く
updated: 2026-07-22
---

Cmd+Shift+X で開く Dispatch パレット。worktree/ブランチ/Issue/PR から作業を開始するコマンドパレット（Cmd+X は奪わない）。他パレット（[settings-palette](settings-palette.md)・[workspace](workspace.md)）と同じ提示経路だが、描画は共有パレット基盤を使わず専用の View／モデル／非同期データプロバイダが持つ（行の解剖と実データ供給が共有基盤の 1 行リスト前提に載らないため）。

**器**: scrim ＋ ガラスパネル。上端アンカー・窓幅に追随する上限幅。カード高は窓高に束縛し、リスト部は実測内容高と上限の小さい方で定高化して超過分を内部スクロールへ回す（低窓・多件数でも末尾行・フッターに到達できる）。

**構成（上から）**:
- **ヘッダー**: `❯`＋実 `TextField`（フィルタ入力欄）＋右端に選択中の起動先チップ（`◐ <起動先> で開く`。起動先は検出 agent の raw command か素の shell）。chrome 入力欄のプレースホルダは共通モディファイアで描かれ、**フォーカス中に IME 変換がある間は非表示**になる——未確定文字は binding へ流れず空欄と区別できないため、field editor の marked text を監視して抑制する（確定・取消で空へ戻れば再表示。抑制はフォーカス欄のみ）。
- **リスト 5 セクション**: Worktrees / Local branches / Remote branches / Issues / Pull requests（見出しは選択対象外・空セクションは非表示）。行は先頭グリフ・名前・muted 補足・番号チップ（branch→open PR 相関のみ）・行末ノートで構成。issue/PR 行と、番号チップが付く（open PR に紐づく）worktree/branch 行の行末に「開く」ボタン。選択行のみ着色。選択は移動時に可視域へスクロール追従する。裏のデータ到着でセクションが差し替わるときは、直前に選択していた行を実行ペイロードの同一性で探し直して選択を復元する（行数が変わっても選択が別の行を指さない）。この復元は入力モダリティを奪わない。
- **フッター**: `↵`＋選択行に連動する実行説明（対象名・前置/後置句・起動先名を色で描き分け）＋右端キーヒント `↑↓ 選択` `⇥ agent変更` `esc 閉じる`（⌘↵ が効く行の選択時は `⌘↵ 開く` を追加）。実行失敗時はこの行に失敗理由を赤で出す。worktree 作成待ち中は `↵` もキーヒントも出さず、スピナ＋「作成中…」のみを出す（操作が無効な間は効かない案内を残さない・優先度は 作成中 → エラー → 実行説明）。

**データ供給（プログレッシブ）**: パレット提示と同時にデータロードが走る。git（worktree/branch 列挙・数十 ms）は即描画。初回ロードまでは候補行の形をしたスケルトン行を出し、開いた瞬間の空フレームを埋める。gh（issue/PR 取得・ネット）は前回結果を先に描いて裏で取り直す。git・gh ともログインシェル PATH でサブプロセス実行し、completion をメインで受ける。

- **git 列挙**: worktree 一覧・local/remote branch 一覧（`refs/remotes/origin/HEAD` 等のノイズ除外・local branch は既存 worktree パスも取得して再利用判定に使う）・デフォルトブランチ。remote branch は即時読みに加え、裏で `git fetch --prune origin` を**独立レーン**（共有 queue の barrier チェーンから切り離す＝直後に Enter で来る worktree 作成がこの数秒の fetch を待たない）で走らせ、成功時に読み直して当該セクションだけ差し替える（失敗時はキャッシュ据え置きで UI 非破壊）。
- **GitHub 取得**: 可用性を `notGitHub`／`ghMissing`／`ghUnauthed`／`ready` に分類（origin URL が github.com か → ローカルの認証情報の有無）してから `gh issue list`／`gh pr list --json` で取得。可用性の判定は**ネットに触らない**——疎通不能を「未認証」と誤って分類すると、通信できないだけの状態で誘導情報行が出て前回結果が消えるため。ネット待ちはタイムアウトつき（stdout/stderr を並行排出しデッドロックを避ける）。
- **gh 結果のキャッシュ**: 取得結果はリポジトリ（`git-common-dir`）単位でプロセス内に保持し、次に開いたときは**前回結果を最初の描画フレームから描いた**うえで裏で取り直す（2 回目以降はローディング行を経由しない）。worktree 間で共有され、アプリ終了で消える。取得成功時はセクションをまるごと置換するので閉じた issue／マージ済み PR は残らない。**取得失敗（オフライン・タイムアウト・非 0 終了・デコード失敗）は差し替えず前回結果を据え置く**（remote branch の裏 fetch と同じ規約）——失敗と「0 件」は取得層で区別され、0 件成功では行が消える。取得結果が前回と等値ならセクションを再構築しない。
- **フォールバック3分岐**: `notGitHub`→Issues/PR 両セクション非表示／`ghMissing`・`ghUnauthed`→Issues に誘導情報行 1 本／`ready`→実データ（0 件セクションは非表示）。

**操作**:
- **フィルタ**: 打鍵で名前・番号・補足を大小無視部分一致で全セクション横断絞り込み。空になったセクションは消え、選択は可視行へクランプ。
- **↑↓ / ⌘↑↓**: ↑↓ は可視の全行を平坦 index で巡回（wrap・見出しはスキップ）・選択行へスクロール追従。⌘↑↓ は選択を最初/最後の対話行へジャンプ（見出し・ローディング・gh 誘導の非対話行は飛ばす・対話行ゼロなら no-op）。**行タップは決定**（↵ と同じ funnel を通り、非対話行・作成中・範囲外では不発。行内の「開く」ボタンは行の決定を巻き込まない）。**マウスホバーで選択がその行へ追従する**（着色行は常に 1 つ・非対話行へは追従しない・ホバーで決定は走らない）。追従の門は共有の入力モダリティ（[workspace](workspace.md)）で、実ポインタ移動で pointer・キー移動や絞り込みで keyboard へ戻り、keyboard の間はスクロールで行がカーソル下へ来ても選択を奪われない。
- **⇥**: 起動先を巡回切替。起動先は検出済み agent（表示は raw command）に素の shell を加えた列で、shell は default agent の直後に常在する。初期選択は default agent（agent 未検出時は shell）。agent 未検出でも shell を選べるため袋小路は無い。
- **Enter（実行）**: 選択行の種別に応じて対象ディレクトリを解決し、選択中の起動先を**現 workspace の新しいタブ**でその cwd に起動する（agent は initialCommand で起動、shell は Cmd+T と同じ既定シェル）。起動後は次 runloop tick で新タブ surface にフォーカスを再確定する。
  - Worktree 行＝既存パスをそのまま使用（非破壊）。Local branch＝既存 worktree があれば再利用、無ければ `git worktree add`。Remote branch＝ローカル追跡ブランチを作って add。Issue＝他行種別と対称で、`issue/<番号>` を既存 worktree／ローカルブランチと突合し 3 分岐（既存 worktree あれば再利用／同名ブランチだけ既存ならそこから追加／どちらも無ければデフォルトブランチから `-b issue/<番号>` で追加）。行末ノート／フッターも実解決に一致（既存worktree／checkout → worktree／新規worktree）。PR（same-repo）＝head ブランチの worktree を作成/再利用。
  - worktree 作成場所は設定 `worktree-path`（パステンプレート）で決まる（[settings-palette](settings-palette.md)・[config](config.md)）。既定 `../{repo}-worktrees/{slug}` はリポジトリルート基準で解決され `<リポジトリ親>/<repo名>-worktrees/<branch slug>` になる（未設定・移行後は現状と同じ場所＝後方互換）。`{repo}`＝リポジトリ名・`{slug}`＝ブランチ名の `/`→`-`。相対はリポジトリルート基準、`~` はホーム、`/` は絶対で解決する。テンプレを変えても既存 worktree は git の記録パスで再利用され、新規のみ新パスへ作られる。`git worktree add` は隔離ディレクトリを追加するだけで現在の作業ツリーに触れない。失敗（パス衝突・checkout 済・ネット不通）時は palette を閉じずフッターに失敗理由を赤で表示し agent を起動しない。失敗理由は git stderr から実質行（`fatal:`／`error:` 行・無ければ最終非空行）を抜く——成功時にも出る進捗風メッセージで本当の理由を覆い隠さないため（この整形は git ラッパー層に閉じる）。
  - **作成中の進捗表示・入力ロック**: 非同期作成の完了を待つ間 `isPreparing` を立て、フッターにスピナ＋「作成中…」を出す。この間は入力を受け付けない（Enter 再実行＝`git worktree add` 二重起動を弾く／↑↓・⇥・検索入力・Esc/scrim 閉じを握り潰す）。既存 worktree 再利用など同期に済むケースは同一 tick で palette が閉じるため進捗は描画されない。
  - fork（cross-repo）PR は worktree 化せず、⌘↵ でのブラウザ表示へ誘導する。
- **⌘↵ / 開くボタン**: issue/PR 行と、open PR に紐づく（番号チップが付く）worktree/branch 行で `gh issue|pr view --web` により対象をブラウザで開く。worktree/branch 行は番号チップと同一番号のルックアップから紐づく PR を開く（一致を保証）。紐づかない行には出さない。
- **閉じる**: Esc / scrim タップで閉じ、アクティブペインへフォーカスが返る。

**octicon グリフ**: issue と branch/PR チップ用グリフは原典 SVG の `d` 文字列を正典とする最小パーサで SwiftUI Path へ移植する（未対応コマンドはパース打ち切り）。
