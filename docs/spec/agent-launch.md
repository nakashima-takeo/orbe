---
title: エージェント起動（現状）
description: claude / codex / agy の自動検出と、Cmd+Shift+A 選択パレット / Cmd+Shift+C デフォルト起動による新タブでの直接起動
updated: 2026-07-22
---

一級サポートのエージェント CLI は claude / codex / agy（この並びがデフォルト未設定時の優先順）。

- **初回フロー（言語選択 → Onboarding）**: 初回起動時は、Onboarding（各 CLI へプラグイン導入・[agent-plugin-package](agent-plugin-package.md)）の**前段**に UI 言語だけを選ぶ画面を出す（ja/en 2 択・↑↓／↵ ないし行タップで確定・行はホバーで選択が追従・真のモーダル＝scrim では閉じない）。確定で現在言語を更新し永続化してから Onboarding へ進む。2 回目以降は言語画面をスキップ。起動フロー全体の文言は現在言語に追従する（[localization](localization.md)）。
- **検出**: ユーザーのデフォルトシェルを login + interactive で起こして PATH を取得し（数秒で打ち切り）、その PATH 上の実行ファイルを絶対パスへ解決する。アプリ起動時に 1 回＋パレットを開くたびに裏で再検出（in-flight 中はスキップ）。シェル起動失敗時は既知の検出結果を保持する。検出した PATH は永続キャッシュ（変化時のみ書く）。復元 resume が同期で要求する PATH は メモリ→キャッシュ→（どちらも無い稀ケースのみ一度だけ）同期検出 の順で解決する——起動クリティカルパスを検出 subprocess で塞がないため（[persistence](persistence.md)）。
- **起動パレット（Cmd+Shift+A）**: 検出済み CLI を列挙するオーバーレイ。↑↓＋Enter で起動、→ サブメニューに「デフォルトに設定」、← / Esc で 1 段戻る。ルート（一覧・検出中・空状態）はヘッダ行なしで行リストから始まり、サブメニューでは breadcrumb ヘッダが出る。検出ゼロは情報行のみの空状態。初回検出が未完了の間は「CLI を検出中…」の情報行を出し、完了で結果表示へ差し替える。● がデフォルト印。開いたまま再検出が届くと表示へ反映（潜り先が消えたら一覧へ戻る）。
- **デフォルト起動（Cmd+Shift+C）**: デフォルト（設定値が検出済みならそれ、それ以外〔未設定・未検出〕は検出順の先頭）を即起動。検出ゼロならパレットの空状態を、初回検出未完了なら検出中パレットを開く。設定値は**アクティブ workspace の実効 `default-agent`** で workspace 上書きに追従する（Cmd+Shift+C・dispatch の既定 agent・起動パレットの ● が同じ解決を読む・[workspace](workspace.md)）。
- **起動形態**: アクティブペインの実効 cwd（0タブは workspace の root path → [layout](layout.md)）を引き継いだ新タブで、シェルの代わりに絶対パスのエージェント CLI を直接起動する。環境変数 `PATH` には検出時のログインシェル PATH を注入する（エージェントの子プロセスにも検出時と同じコマンド解決を保証するため）。エージェント終了はシェル exit と同じ経路でタブが閉じる。永続スナップショットでは、hook 由来のエージェントセッションを持つペインは resume 起動、持たない／未対応 CLI のペインは保存 cwd の通常シェルタブで復元される（→ [persistence](persistence.md)）。
- **デフォルトの永続**: `default-agent` は他設定と同じ均一レイヤに載り、global は settings、workspace は当該 WS の上書き層に保存する。起動パレット Cmd+Shift+A・オンボーディングの「デフォルトに設定」は WS 文脈を持たないため **global スコープの設定変更**へ一本化する。設定パレットの agent サブパレットは他項目と同じ経路で、workspace スコープなら上書きを書ける（→ [settings-palette](settings-palette.md)）。
- オーバーレイ UI は workspace パレットと共通のパレット基盤を共有する。ヘッダ行は入力欄か breadcrumb のあるときだけ描かれる（ヘッダのショートカットバッジは存在しない）。行リストの高さ上限・選択追従スクロール・⌘↑↓ での有効な先頭/末尾行ジャンプは共有基盤の挙動（→ [workspace](workspace.md)）。
