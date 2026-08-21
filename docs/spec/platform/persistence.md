---
title: workspace 永続
description: 構成（workspace・タブ・分割ツリー・cwd・エージェントセッション）の JSON 保存と起動時復元・エージェント resume・デバウンス保存
updated: 2026-08-21
---

# workspace 永続

アプリを再起動しても作業の構成——workspace・タブ・分割・cwd・エージェントセッション——が戻るための永続層。

保存先は `~/Library/Application Support/<bundle-id>/` 直下。`<bundle-id>` はビルドチャネルごとに異なるため（[channel](channel.md)）、dev（Orbe Dev）と release は state を共有しない。環境変数 `ORBE_STATE_DIR`（非空）を設定するとその dir 直下へ移る——検証用の隔離インスタンス用途で、settings.json・gui.conf・取り込んだ通知音の `sounds/`・[制御 API](../control/api.md) の control.sock も同じ dir に同居する。テスト用にファイル位置を差し替える seam を持つ。

## workspaces.json — 構成の永続

保存するもの: workspace 名・root path・各 workspace の設定上書き（[workspace](workspace.md)・[settings](../palette/settings.md)）・最終使用時刻（`WorkspacePalette` の MRU 並べ替え用）・アクティブ workspace・ウィンドウサイズ／各 workspace のタブ群と active タブ／各タブの分割ツリー（二分木）・分割比・明示タイトル（[chrome](../chrome/chrome.md)）／各ペインの cwd とエージェントセッション。

### 復元の挙動

- 各ペインは保存 cwd で新シェルを起こす（ライブプロセスは復元対象外）。非アクティブ workspace の surface は切替時に遅延起動する。
- タブ 0 個（休眠）の workspace もエントリごと保存・復元する（エントリは消えない）。復元時アクティブが 0 タブでも空状態を表示し、背景の 0 タブもそのまま keep する（いずれもシェルは自動起動しない）。
- cwd は OSC 7（`GHOSTTY_ACTION_PWD`）で報告された値を surface が保持したもの。復元は surface 生成時の working_directory 指定で起こす。
- エージェントセッションは hook 由来の (CLI 名, session_id)（[agent/notify](../agent/notify.md)）を葉に持つ。復元直後のペインは記録を凍結したまま休眠し、resume の解決——CLI 別の resume コマンド（claude `--resume <id>`／agy `--conversation <id>`／codex `resume <id>`）＋ログインシェル PATH——は**タブ起床（materialize 開始）時**に行う。CLI 名が未対応・session_id が安全文字集合外なら素のシェルで起きる——生成コマンドへの注入を防ぐため。セッション記録そのものは休眠のあいだ保持され、resume 可否は起床まで判定しない。
- resume が注入する PATH は `app-state.json` のキャッシュ値から**同期で**読む——起動復元をシェル起動の subprocess にブロックさせないため。キャッシュが無い初回は上限つきで待ち、尽きれば既知パスだけで起こす（[shell-path](shell-path.md)）。
- 分割比は保存値を一度だけ適用し、以後は実フレームから算出する。
- タブ 1 枚分の復元単位は `Cmd+Shift+T`（閉じたエージェントタブを開き直す → [layout](../chrome/layout.md)）と共有する——同じ経路を通るので、戻るもの／戻らないものが一致する。閉じたタブの控えはこのファイルに持たず、プロセス内にのみ保つ。
- ウィンドウサイズは画面 `visibleFrame` へクランプして復元し、位置は保存せず毎回中央表示。記憶するのはユーザー意図サイズ（クランプ前）で、小画面での表示クランプは記憶値を破壊しない。
- `NSWindow.isRestorable = false` で OS 標準の復元は使わない。

保存は構成変化のたびデバウンスし、終了時に flush する。

### 互換と破損時の退避

旧スキーマは無損失で読み、次回保存で現行形式へ置き換わる（タブ構成・cwd・エージェントを失わない）。後から足したフィールドは**欠落**を許容する。「あるが読めない」を既定へ落とすのは `editor` と設定層（`settingsOverride`）の 2 つだけで、そのほか——タブ本体（`tree`・エージェントセッション）・`explicitTitle`・`lastUsedAt`・`windowSize`・workspace の名前や index——はファイル全体の fallback へ落ちて**全 workspace を失う**。optional で後から足したフィールドも、既定へ落とす decode を自分で書かない限りこちら側になる。設定層（global・workspace 上書きとも）は現行形式なら読めない 1 キーだけを落として残りを活かし、値ごと読めなければ上書き無し（global 継承）へ落ちる——1 項目の異常で層ごと消さないため。旧 camelCase の読みは global 移行・workspace 上書きとも all-or-nothing で、そこでは範囲外の `theme` が既定値として層に載る。値域を持つ項目は、範囲外の値を**最寄りの端へ丸めて**層に載せる——読出には拒否を返す先が無く、既定へ落とすと「大きくしたい／小さくしたい」という書き手の意図まで捨てるため。丸めは書き込み経路の検証と同じ値域を関門 1 つで共有する。

壊れている・非互換バージョン・空 JSON は既定の単一 workspace で fallback する。このとき**原本が在るのに使えなかった**場合（読めない・構造破損・非互換バージョン）は、fallback する前に原本を同じディレクトリの `workspaces-broken-<日時>.json` へ退避する——直後の既定起動が打つ保存が原本を潰すため。退避物は最新 1 件だけ残す。退避できなかった原本が原位置に残っている間は、そのセッションはその場所へ書かない（保全できていない原本を潰さないため）。ファイル不在（初回起動）と空 JSON は失う構成が無いので退避しない。

## settings.json / app-state.json

- **`settings.json`** … ユーザー設定（global 層）。in-memory SSOT が保持し、変更は即 save する。未知 key（将来の項目・撤去済みの項目）は無視して読む。
- **`sounds/`** … 取り込んだカスタム通知音（48kHz モノラルの WAV・[agent/sound](../agent/sound.md)）。設定値がファイル名で指す実体で、取り込みごとに一意な名前で書く（同名の上書きが起きないので、鳴っている最中の差し替えでも壊れない）。参照されなくなったファイルは、参照集合が変わったとき——取り込みの確定時と workspace の削除時——に突き合わせて消す。
- **`app-state.json`** … ユーザー設定でない内部簿記（エージェントプラグインを導入できたか・最後に登録できたエージェントプラグイン名〔[agent/plugin-package](../agent/plugin-package.md)〕・旧補完方式〔managed block〕の導入済みフラグ・ログインシェル由来の PATH のキャッシュ〔[shell-path](shell-path.md)〕・UI 言語）。全項目 optional。

2 ファイルに分けているのは「ユーザーが決めた値」と「アプリが勝手に覚えた値」を混ぜないため。旧形式（両者が同居した 1 枚）は起動時に無損失で分割移行する（旧ファイル全体が読めたときだけ変換する all-or-nothing。読めなければ既定へ fallback）。app-state.json へは全体上書きでなく**マージ**で書く——旧形式が語彙として持たない項目（UI 言語・登録できたエージェントプラグイン名）も、旧形式が語彙としては持つがその 1 ファイルには書かれていない項目（ログインシェル PATH のキャッシュ等）も移行が巻き戻さず、中断した移行からの再移行が冪等になる。

UI 言語 `preferredLanguage` は **nil＝未選択**（初回言語選択画面を出す・描画は OS 言語追従）、非 nil＝確定（[localization](localization.md)）。グローバル専用で workspace 上書きできない。
