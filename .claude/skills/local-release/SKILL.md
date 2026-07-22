---
name: local-release
description: Orbe をビルドして自分の Mac の /Applications に最新版として据える（ローカルリリース）。「ローカルに反映」「自分の PC を最新版に」「local-release」や、ship のマージ後に常用環境を更新したい時に使う。
---

# local-release — 自分の Mac の Orbe を最新ビルドに入れ替える

開発中の Orbe を、自分の常用環境（`/Applications/Orbe.app`）へ最新ビルドとして据えるスキル。処理の実体は `scripts/install.sh`（ビルド → 起動中の Orbe を終了 → 置換 → 再起動）。このスキルはその呼び出し口。

## いつ使うか
- ship のマージ後、確定した main を常用環境に反映する（ship の末尾から呼ばれる）。
- ship を通さず手で直した／`git pull` で取り込んだ後、単体 `/local-release` で反映する。

## 手順
1. `./scripts/install.sh` を実行し、最後に出る build-id を短く報告する。
   - **Orbe の中から実行したとき**: 入れ替え（終了→置換→再起動）は本体の生死から切り離して走り、直後に Orbe がこの実行元セッションごと再起動する（ワークスペース構成は復元される）。install.sh が返す build-id と再起動予告を伝えて終える——再起動後の報告はこのセッションからはできない。
   - 前提不足（フル Xcode 未導入・zig 失敗など）での失敗は、出力されたメッセージ（`docs/BUILD.md` 参照）に従う。
