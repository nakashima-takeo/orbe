#!/usr/bin/env bash
# Orbe Dev.app をビルドして /Applications に据える（自分の Mac で開発版を常用するため）。
# 開発バージョンアップのたびに、これ1本で Orbe Dev を最新ビルドに入れ替えて再起動する。
# 本番の /Applications/Orbe.app には触れない（dev は別 identity のアプリとして共存する）。
# 実機検証用の隔離インスタンス（scripts/dev-verify.sh）と違い、こちらは常用の実体を入れ替える。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# 祖先を辿り、Orbe Dev 本体の中から実行されているか調べる（居ればその pid を掴む）。
# 中から入れ替えると quit した瞬間に置換作業ごと自滅するため、後段で swap を切り離す。
# 固定文字列の完全パス一致で見る: 部分一致だと本番 Orbe の中からの実行まで拾って
# 自己入れ替え扱いになるが、本番には触れないので切り離しは不要（＝マッチしないのが正しい）。
orbe_pid=""
guard_pid=$$
while [ "${guard_pid:-0}" -gt 1 ]; do
  if ps -o args= -p "$guard_pid" 2>/dev/null | grep -qF "/Applications/Orbe Dev.app/Contents/MacOS/Orbe"; then
    orbe_pid="$guard_pid"
    break
  fi
  guard_pid="$(ps -o ppid= -p "$guard_pid" 2>/dev/null | tr -d ' ')"
done

# ビルドは build/Orbe.app を作るだけで本体に触れないため、Orbe の中からでも前景で走る。
"$ROOT/scripts/build-app.sh"
BUILD_ID="$(/usr/libexec/PlistBuddy -c 'Print :OrbeBuildID' "$ROOT/build/Orbe.app/Contents/Info.plist")"

if [ -n "$orbe_pid" ]; then
  # Orbe Dev の中から実行された。swap（終了→置換→再起動）を nohup で本体の生死から切り離して起こす。
  # 直後にこの実行元セッションごと Orbe Dev が落ちるため、報告は swap 前のいまのうちに出す。
  # 先頭 sleep は、呼び出し元が build-id を伝え終える猶予（Orbe Dev が落ちるまでの間）。
  nohup bash -c "sleep 2; exec bash '$ROOT/scripts/_swap.sh' '$ROOT/build/Orbe.app' '$orbe_pid'" \
    >"${TMPDIR:-/tmp}/orbe-swap.log" 2>&1 </dev/null &
  disown
  echo "==> 新ビルド $BUILD_ID を用意。いまからこのセッションごと Orbe Dev を再起動して /Applications へ入れ替えます（ワークスペース構成は復元されます）"
else
  # Orbe Dev の外（別ターミナル・本番 Orbe の中等）から実行された。その場で入れ替える。
  bash "$ROOT/scripts/_swap.sh" "$ROOT/build/Orbe.app" ""
  echo "==> 完了: $BUILD_ID"
fi
