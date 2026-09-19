---
title: git 実行
description: git CLI を起動する共通基盤。3 つの並行レーン・無出力での打ち切り・観測の契約
updated: 2026-09-19
---

# git 実行

Orbe が git に触る操作——Dispatch の worktree 作成・掃除（[dispatch](../palette/dispatch.md)）、workspace 作成の clone（[workspace パレット](../palette/workspace.md)）、ブランチ・worktree の一覧、エディターの根の観測（[editor/files](../editor/files.md)）——はすべて `/usr/bin/git` の子プロセスとして走る。それらの起動を 1 箇所に集める基盤が持つ契約をここに置く。個々の面が「どう見せるか」は各面の spec が持ち、ここは「どう走らせるか」だけを持つ。

hooks・署名がユーザーのシェル環境と同等に動くよう、全呼び出しがログインシェル由来の PATH を引き継ぐ（[shell-path](shell-path.md)）。`GIT_TERMINAL_PROMPT=0` を必ず渡す——資格情報の対話プロンプトは GUI からは見えず、待てば無限に待つことになるので、認証が要る操作は待たずに失敗へ落とす。

## 実行レーン

レーンは 3 種で、「何と競合するか」で選ぶ。

- **読み取り** — 並行に走る。
- **同一リポジトリの ref・作業ツリーを書く操作** — 単独で直列化する。git のロックは待たずに即 fatal するため、順番はアプリ側で作る。
- **共有チェックアウトと領域が交わらない操作、または結果が古くても取り直せる観測**（clone・worktree 作成・fetch・掃除の分類プローブ・エディターの根の status と index の読み） — 独立レーンで走らせ、直列化のチェーンに載せない。

3 つ目を分けるのは、直列化がプロセス単位で効くため。時間の上限が無い操作をそこへ置くと、無関係な読み取りまでその完了を待たされる。プローブのように「本数ぶん走り、かつ直後の操作を待たせてはいけない」ものも、呼び出し側の判断でこのレーンへ逃がせる。観測を載せるのは逆の理由——直列化は submit 済みの全ブロックの完了を待つため、巨大リポジトリの status を読み取りレーンに置くと worktree の削除や ref の更新がその完了を待つ。観測は監視が取り直すので、古い結果が返っても害が無い。

## 無応答の打ち切り

**無出力が 120 秒続いた実行は SIGTERM で打ち切る。** 経過時間ではなく無出力時間で測るのは、巨大リポジトリの clone のような正当な長時間実行を切らないため——出力が流れている間は延命し、何も起きていないときだけ切る。そのため clone・fetch には `--progress` を渡す。GUI から起動した git は stderr が tty でないので既定では進捗を出さず、そのままでは無音と区別できない。

打ち切りに SIGTERM を使うのは、git 自身に後始末をさせるため。`.git/index.lock` も作りかけの clone 先も残らない（SIGKILL では残る）。

打ち切った後は pipe の EOF を無期限には待たない。git が終了しても、その出力を継いだ孫プロセス（hook が背景に残した子・`git remote-ext`・gpg）が pipe を握っていれば EOF は来ない——待ちそのものが新しいハングになるので、猶予を過ぎたら諦めて返る。

打ち切りは終了コードと別の値で伝える。終了コードでは起動失敗と区別できないため。打ち切られた操作を成功と読むか失敗と読むかは呼び出し側が決める——worktree 作成のように「実体が出来ていれば成功」と読み替える面がある（[dispatch](../palette/dispatch.md)）。

## 観測

worktree の状態を見る `status` には `--no-optional-locks` を渡す。ユーザーが作業中のリポジトリを観測するだけでロックを取らないため。

エディターの根の観測（[editor/files](../editor/files.md)）は 3 つの読みで成る。status は porcelain v2 の NUL 区切り（パスは verbatim）で、見え方を左右するユーザー設定（`status.showUntrackedFiles`・`diff.ignoreSubmodules`）を引数で封じる。index の版は `ls-files -s` の OID で引き、変わったときだけ `cat-file --filters --path=<相対パス>` で本文を取る——そのパスの属性で smudge filter と eol 変換を掛けた、作業ツリーに出したときの姿。smudge の実行コマンドは config 側にしか書けないので、信頼できないリポジトリがコードを走らせる面は checkout と同じ。textconv・外部 diff は通らず、diff driver は起動しない。無出力 120 秒の打ち切りは他の呼び出しと同じで、smudge が黙って止まれば baseline 無しに落ちる。問い合わせるファイル名は pathspec として解釈させない（literal を前置し、それを覆す環境変数は全呼び出しから落とす）。

チェックアウトの解決は toplevel・git dir・common dir の 3 値。linked worktree では git dir が本体側の `worktrees/<name>` を指し、index・HEAD はそこにある（監視の対象）。綴りは git の返すままにする——`git worktree list` の生パスとの等値比較に使うため、正準形と比べる場では比べる側が両辺を揃える。
