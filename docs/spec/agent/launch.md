---
title: エージェント起動
description: claude / codex / agy の自動検出と、⌘⇧A 選択パレット / ⌘⇧C デフォルト起動 / 制御 API による新タブでの直接起動
updated: 2026-08-16
---

# エージェント起動

エージェント CLI をワンアクションで「起動した状態のタブ」として開くための機構。一級サポートのエージェント CLI は claude / codex / agy（この並びがデフォルト未設定時の優先順）。

## 初回フロー（言語選択 → Onboarding）

初回起動時は、Onboarding（各 CLI へプラグイン導入・[plugin-package](plugin-package.md)）の**前段**に UI 言語だけを選ぶ画面を出す（ja/en 2 択・↑↓／↵ ないし行タップで確定・行はホバーで選択が追従・真のモーダル＝scrim では閉じない）。確定で現在言語を更新し永続化してから Onboarding へ進む。2 回目以降は言語画面をスキップする。起動フロー全体の文言は現在言語に追従する（[localization](../platform/localization.md)）。

## 検出

解決済みの子プロセス PATH（[shell-path](../platform/shell-path.md)）上の実行ファイルを絶対パスへ解決する。アプリ起動時に 1 回＋パレットを開くたびに裏で再走査する（in-flight 中はスキップ）。走査し直すのは実行ファイルの有無だけで、PATH 自体は取り直さない。解決できた CLI だけを覚える——見つからなかったことを覚えると、PATH が整う前の 1 回の走査がセッション全体を縛るため。

## 起動パレット（⌘⇧A）

検出済み CLI を列挙するオーバーレイ。↑↓＋Enter で起動、→ サブメニューに「デフォルトに設定」、← / Esc で 1 段戻る。ルート（一覧・検出中・空状態）はヘッダ行なしで行リストから始まり、サブメニューでは breadcrumb ヘッダが出る。検出ゼロは情報行のみの空状態。初回検出が未完了の間は「CLI を検出中…」の情報行を出し、完了で結果表示へ差し替える。● がデフォルト印。開いたまま再検出が届くと表示へ反映する（潜り先が消えたら一覧へ戻る）。

オーバーレイ UI は workspace パレットと共通のパレット基盤を共有する。ヘッダ行は入力欄か breadcrumb のあるときだけ描かれる（ヘッダのショートカットバッジは存在しない）。行リストの高さ上限・選択追従スクロール・⌘↑↓ での有効な先頭/末尾行ジャンプは共有基盤の挙動（→ [workspace パレット](../palette/workspace.md)）。

## デフォルト起動（⌘⇧C）

デフォルト（設定値が検出済みならそれ、それ以外〔未設定・未検出〕は検出順の先頭）を即起動する。検出ゼロならパレットの空状態を、初回検出未完了なら検出中パレットを開く。設定値は**アクティブ workspace の実効 `default-agent`** で workspace 上書きに追従する（⌘⇧C・dispatch の既定 agent・起動パレットの ● が同じ解決を読む・[workspace](../platform/workspace.md)）。

## 起動形態

アクティブペインの実効 cwd（0 タブは workspace の root path → [layout](../chrome/layout.md)）を引き継いだ新タブで、シェルの代わりに絶対パスのエージェント CLI を直接起動する。環境変数 `PATH` には子プロセス PATH（[shell-path](../platform/shell-path.md)）を注入する——エージェントの子プロセスにも Orbe 自身と同じコマンド解決を保証するため。エージェント終了はシェル exit と同じ経路でタブが閉じる。永続スナップショットでは、hook 由来のエージェントセッションを持つペインは resume 起動、持たない／未対応 CLI のペインは保存 cwd の通常シェルタブで復元される（→ [persistence](../platform/persistence.md)）。

## 外部からの起動

制御 API と `orb agent spawn` / `orb agent resume`（[control/cli](../control/cli.md)）からも起こせる。**GUI と同じ経路**を通る——新タブを起こす関数が 1 本しかなく、絶対パス・PATH 注入・cwd フォールバックの組成をそのまま共有する。起動のされ方が入口ごとに割れると、その差は「GUI からは動くが CLI からは動かない」という遠い形で出る。

外部起動だけが持つのは対象 workspace の指定で、**指定しても前面化しない**（[control/api](../control/api.md) の mount 境界）。このとき解くデフォルトは**対象 workspace の**実効 `default-agent` で、⌘⇧C がアクティブ workspace のそれを読むのと同じ規則を、入力だけ変えて使う。

resume 起動は永続復元だけでなく `orb agent resume` からも走る。セッション ID は `orb pane list --json` の `agentSessionId`（hook 報告が入ってから値を持つ）から取る。

## デフォルトの永続

`default-agent` は他設定と同じ均一レイヤに載り、global は settings、workspace は当該 WS の上書き層に保存する。起動パレット ⌘⇧A・オンボーディングの「デフォルトに設定」は WS 文脈を持たないため、**global スコープの設定変更**へ一本化する。設定パレットの agent サブパレットは他項目と同じ経路で、workspace スコープなら上書きを書ける（→ [settings](../palette/settings.md)）。
