---
title: workspace 永続（現状）
description: 構成（workspace・タブ・明示タイトル・分割ツリー・cwd・エージェントセッション・最終使用時刻）の JSON 保存と起動時復元・エージェント resume・デバウンス保存
updated: 2026-08-06
---

保存先は `~/Library/Application Support/<bundle-id>/` 直下。`<bundle-id>` はビルドチャネルごとに異なるため（[channel](channel.md)）、dev（Orbe Dev）と release は state を共有しない。環境変数 `ORBE_STATE_DIR`（非空）を設定するとその dir 直下へ移る——検証用の隔離インスタンス用途で、settings.json・gui.conf・[control-api](control-api.md) の control.sock も同じ dir に同居する。テスト用にファイル位置を差し替える seam を持つ。

## workspaces.json — 構成の永続

保存するもの: workspace 名・root path・各 workspace の設定上書き（[workspace](workspace.md)・[settings-palette](settings-palette.md)）・最終使用時刻（`WorkspacePalette` の MRU 並べ替え用）・アクティブ workspace・ウィンドウサイズ／各 workspace のタブ群と active タブ／各タブの分割ツリー（二分木）・分割比・明示タイトル（[chrome](chrome.md)）・EditorPane の開閉と開いているツール（粗粒度。選択ファイル等は持たない・[editor-pane](editor-pane.md)）／各ペインの cwd とエージェントセッション。

復元の挙動:

- 各ペインは保存 cwd で新シェルを起こす（ライブプロセスは復元対象外）。非アクティブ workspace の surface は切替時に遅延起動。
- タブ 0 個（休眠）の workspace もエントリごと保存・復元する（エントリは消えない）。復元時アクティブが 0 タブでも空状態を表示し、背景の 0 タブもそのまま keep する（いずれもシェルは自動起動しない）。
- cwd は OSC 7（`GHOSTTY_ACTION_PWD`）で報告された値を surface が保持したもの。復元は surface 生成時の working_directory 指定で起こす。
- エージェントセッションは hook 由来の (CLI 名, session_id)（[agent-notify](agent-notify.md)）を葉に持ち、復元時に CLI 別の resume コマンド（claude `--resume <id>`／agy `--conversation <id>`／codex `resume <id>`）＋ログインシェル PATH で起こす。CLI 名が未対応・session_id が安全文字集合外なら素のシェルへ fallback する（生成コマンドへの注入を防ぐため）。
- resume が注入するログインシェル PATH は `app-state.json` のキャッシュ値から**同期で**読む——起動復元を PATH 検出 subprocess（ログインシェル起動・数秒〜十数秒かかりうる）にブロックさせないため（[agent-launch](agent-launch.md)）。
- 分割比は保存値を一度だけ適用し、以後は実フレームから算出する。
- タブ 1 枚分の復元単位は `Cmd+Shift+T`（閉じたエージェントタブを開き直す → [layout](layout.md)）と共有する——同じ経路を通るので戻るもの／戻らないものが一致する。閉じたタブの控えはこのファイルに持たずプロセス内にのみ保つ。
- ウィンドウサイズは画面 `visibleFrame` へクランプして復元し、位置は保存せず毎回中央表示。記憶するのはユーザー意図サイズ（クランプ前）で、小画面での表示クランプは記憶値を破壊しない。
- `NSWindow.isRestorable = false` で OS 標準の復元は使わない。

保存は構成変化のたびデバウンスし、終了時に flush する。

互換: 旧スキーマは無損失で読み、次回保存で現行形式へ置き換わる（タブ構成・cwd・エージェントを失わない）。後から足したフィールドは**欠落**を許容する。`editor` だけは「あるが読めない」も既定へ落とす——このフィールドの異常でタブを失わないため。設定層（global・workspace 上書きとも）は現行形式なら読めない 1 キーだけを落として残りを活かす——1 項目の異常で層ごと消さないため。旧 camelCase の読みは global 移行・workspace 上書きとも all-or-nothing で、そこでは範囲外の `theme` が既定値として層に載る。値域を持つ項目は範囲外の値もそのまま層へ載せる（値域を守るのは書き込み経路）。タブ本体（`tree`・エージェントセッション）・`explicitTitle`・`lastUsedAt`・workspace の名前や index が「あるが読めない」ならファイル全体の fallback へ落ちる。壊れている・非互換バージョン・空 JSON は既定の単一 workspace で fallback。

## settings.json / app-state.json

- **`settings.json`** … ユーザー設定（global 層）。in-memory SSOT が保持し、変更は即 save する。未知 key（将来の項目・撤去済みの項目）は無視して読む。
- **`app-state.json`** … ユーザー設定でない内部簿記（エージェントプラグインを導入できたか・最後に登録できたエージェントプラグイン名〔[agent-plugin-package](agent-plugin-package.md)〕・補完のインストール済みフラグ・ログインシェル PATH のキャッシュ・UI 言語）。全項目 optional。

2 ファイルに分けているのは「ユーザーが決めた値」と「アプリが勝手に覚えた値」を混ぜないため。旧形式（両者が同居した 1 枚）は起動時に無損失で分割移行する（旧ファイル全体が読めたときだけ変換する all-or-nothing。読めなければ既定へ fallback）。app-state.json へは全体上書きでなく**マージ**で書く——旧形式が語彙として持たない項目（UI 言語・登録できたエージェントプラグイン名）も、旧形式が語彙としては持つがその 1 ファイルには書かれていない項目（ログインシェル PATH のキャッシュ等）も移行が巻き戻さず、中断した移行からの再移行が冪等になる。

UI 言語 `preferredLanguage` は **nil＝未選択**（初回言語選択画面を出す・描画は OS 言語追従）、非 nil＝確定（[localization](localization.md)）。グローバル専用で workspace 上書きできない。
