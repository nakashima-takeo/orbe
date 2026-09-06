---
title: 閉じたエージェント パレット
description: ⇧⌘T で開く、この workspace で閉じたまま戻っていないエージェントセッションの一覧。Enter で 1 件を休眠タブとして戻して起こす
updated: 2026-09-07
---

# 閉じたエージェント パレット

アクティブ workspace（照合は rootPath → [寿命ログ](../platform/session-log.md)）で閉じたまま戻っていないエージェントセッションを 1 枚で見て、選んで戻すための面。[寿命ログ](../platform/session-log.md)を読み、「session_id の最後のイベントが `closed` で、今 Orbe のどのタブ（live／休眠）にも無いもの」を新しい順に並べる。全 workspace を横断しない——見せるのは今いる場所の履歴で、他 workspace の分はその workspace で開く。文言は現在言語に追従する（[localization](../platform/localization.md)）。

## 入口

⇧⌘T。タブが 1 枚も無い 0 タブ workspace でも開く（[layout](../chrome/layout.md)）。

## 一覧

平らな一覧。群や階層は持たない——同じ事故で落ちた連続行はそのまま並ぶ。

各行の主役は**閉じた時点のタブタイトル**（無ければタブバーと同じ既定語）。脇に CLI 名と cwd（workspace root からの相対）、右端に終わり方のバッジと経過時間を置く。終わり方は色ではなく語で言う——自分で閉じた／落ちた／終了した／外部から閉じた／resume できなかった（[寿命ログ](../platform/session-log.md)の origin 5 値の写し）。終了理由（`reason`）は行に出さない。

空なら情報行 1 本。開いている間に別のタブが閉じれば行が増え、別の経路（`orb` / MCP）で復元されれば行が消える。選択は行の位置ではなく session_id に追従する——一覧が組み変わっても、選んでいたものが別の行にすり替わらないため。

## 操作

- **↵ / 行タップ** — 選んだ 1 件を復元する。休眠チケットとしてアクティブ workspace に足し（位置は新規タブと同じ規則——同じ worktree の連の右端、無ければ末尾）、パレットを閉じ、そのタブを選択して起こす（起床時に resume が解決される → [persistence](../platform/persistence.md)）。同じ workspace に他の休眠チケットがあれば mount 規律どおり順次起きる。⌘R の明示タイトルは復元対象外——行が見せる名前は閉じた時点の表示名で、復元後のタブ名は起床後の派生名になる。
- **↑↓** 1 行移動・**⌘↑↓** 先頭/末尾ジャンプ（共有 `PaletteCard` の規律 → [workspace パレット](workspace.md)）。ホバーで選択が追従する。
- **esc / 暗幕タップ** — 閉じる。

1 件ずつしか戻さない。多数（事故で一斉に落ちた分など）を一度に戻すのは制御 API の [`restore_sessions`](../control/api.md)（`orb session restore --at` か MCP）で行う。GUI に一括操作を置かないのは、戻す先が背景 workspace にまたがり、起こす順序と数を人が見ながら決める操作にならないため。
