#!/bin/sh
# Orbe のエージェントプラグインを、検出された各 CLI が読む中身へそろえる。
# Orbe が実体化先のパス・プラグイン名・時限を引数にバックグラウンドで呼ぶ（中身が変わった起動とオンボーディング）。
# claude は登録した実体化先をそのまま読むので、未導入のときだけ導入する。codex / agy は導入時の
# コピーを読むので、入れ直してコピーを今の中身へ置き換える。利用者がプラグインを無効にした設定は残す。
#
# 使い方: install.sh <plugin_dir> <plugin_name> <register_limit> <list_limit> <install_limit>
# プラグイン名はチャネルごとに違う（dev / release が別枠で共存する）ので焼き付けず引数で受ける。
# 各 CLI のコマンドの時限（秒。小数も可）は、登録（marketplace add）・一覧（plugin list）・導入の順に Orbe が渡す。
# 各 CLI ごとに status を 1 行出力: installed / unchanged / skip-no-cli / error
# 個々の CLI のハングを tmo で打ち切る。
DIR="${1:?plugin_dir required}"
NAME="${2:?plugin_name required}"
REGISTER_LIMIT="${3:?register_limit required}"
LIST_LIMIT="${4:?list_limit required}"
INSTALL_LIMIT="${5:?install_limit required}"

# macOS に timeout が無いため perl で代替する。CLI を子として起こし、時限で終了を要求（SIGTERM）し、猶予の後も
# 残っていれば強制終了（SIGKILL）する。SIGALRM を CLI へ直に届けないのは、agy が SIGALRM では終わらないため。
# 打ち切ったら CLI の終了コードによらず失敗（124）を返す——agy は SIGTERM を受けて 0 で終わることがある。
# 時限が正の数でなければ CLI を起こさずに失敗（125）を返す——空や 0 の時限で alarm を掛けると、時限が黙って外れる。
# SIGALRM は、fork の前から、ハンドラと子の pid がそろうまでブロックしておく（子は exec の前にブロックを解除する）。
# そろう前に外から届いた SIGALRM も、捨てずに、そろった後で時限の到来として受ける。
# stderr は常に捨てる: このスクリプトの stdout は status 行の通り道で、混ざると Orbe が誤読する。
tmo() {
  perl -MTime::HiRes=alarm -mPOSIX -e '
    my $limit = shift;
    exit 125 unless $limit =~ /^\d+(?:\.\d+)?\z/ && $limit > 0;
    my ($alrm, $mask) = (POSIX::SigSet->new(POSIX::SIGALRM()), POSIX::SigSet->new);
    POSIX::sigprocmask(POSIX::SIG_BLOCK(), $alrm, $mask);
    my $pid = fork;
    exit 127 unless defined $pid;
    if (!$pid) { POSIX::sigprocmask(POSIX::SIG_SETMASK(), $mask); exec @ARGV; exit 127 }
    my $cut = 0;
    $SIG{ALRM} = sub { kill($cut++ ? "KILL" : "TERM", $pid); alarm 2 };
    alarm $limit;
    POSIX::sigprocmask(POSIX::SIG_SETMASK(), $mask);
    waitpid($pid, 0);
    exit 124 if $cut;
    exit($? & 127 ? 128 + ($? & 127) : $? >> 8);
  ' -- "$@" </dev/null 2>/dev/null
}

# list の出力はパイプでなくこのファイルで受ける（毎回 truncate される）。CLI が孫プロセスを残した
# まま打ち切られても、孫が握るのはこの fd なので読み手は EOF を待たない（パイプだと孫が閉じるまで
# 待ち続け、打ち切りが効かない）。一覧を読めない（打ち切り・失敗。codex は JSON の形の変化も）ときは、導入を試みず error にする。
# claude の plugin install も codex の plugin add も無効にしたプラグインを有効へ戻すので、読めないまま
# 導入すると、利用者が無効にした設定を黙って覆す。error なら指紋を記録せず、次の起動でやり直す。
LIST="$(mktemp -t orbe-plugin-list)" || exit 1
trap 'rm -f "$LIST"' EXIT

# 各 CLI の開始時に "start <cli>" を出し、UI が「導入中」を出せるようにする（echo は逐次 write）。
echo "start claude"
if command -v claude >/dev/null 2>&1; then
  tmo "$REGISTER_LIMIT" claude plugin marketplace add "$DIR" >/dev/null
  # list は "<name>@<marketplace>" の行を持つ。別チャネルの枠（名前の先頭が同じ）を自分のものと
  # 誤認して plugin install を永久に飛ばさないよう、完全一致で判定する。このプラグインの行は無効にしても残るので、
  # あれば終了コードによらず導入済み。行が無いことを信じるのは、一覧が最後まで出た（終了コード 0）ときだけ。
  tmo "$LIST_LIMIT" claude plugin list >"$LIST"
  LIST_STATUS=$?
  if grep -qF "${NAME}@${NAME}" "$LIST"; then
    echo "unchanged claude"
  elif [ "$LIST_STATUS" -ne 0 ]; then
    echo "error claude"
  elif tmo "$INSTALL_LIMIT" claude plugin install "${NAME}@${NAME}" >/dev/null; then
    echo "installed claude"
  else
    echo "error claude"
  fi
else
  echo "skip-no-cli claude"
fi

echo "start codex"
if command -v codex >/dev/null 2>&1; then
  # marketplace add は冪等。plugin add の再実行はキャッシュのコピーを丸ごと置き換えるが、同時に必ず
  # 有効へ戻すので、利用者が無効にしていれば入れ直さない（次に中身が変わって有効なら入れ直す）。
  tmo "$REGISTER_LIMIT" codex plugin marketplace add "$DIR" >/dev/null
  tmo "$LIST_LIMIT" codex plugin list --json --marketplace "$NAME" >"$LIST"
  # 0: 利用者が無効にしている / 1: 無効ではない / 2: 一覧を読めない（installed の配列が無い形も含む）。
  perl -MJSON::PP -0777 -e '
      my $id = shift;
      my $list = eval { decode_json(<STDIN>) };
      exit 2 unless ref $list eq "HASH" && ref $list->{installed} eq "ARRAY";
      exit((grep { $_->{pluginId} eq $id && !$_->{enabled} } @{ $list->{installed} }) ? 0 : 1);
    ' "${NAME}@${NAME}" <"$LIST" 2>/dev/null
  case $? in
    0) DISABLED=yes ;;
    1) DISABLED=no ;;
    *) DISABLED=unknown ;;
  esac
  if [ "$DISABLED" = yes ]; then
    echo "unchanged codex"
  elif [ "$DISABLED" = unknown ]; then
    echo "error codex"
  elif tmo "$INSTALL_LIMIT" codex plugin add "${NAME}@${NAME}" >/dev/null; then
    echo "installed codex"
  else
    echo "error codex"
  fi
else
  echo "skip-no-cli codex"
fi

echo "start agy"
if command -v agy >/dev/null 2>&1; then
  # agy はローカルパス導入＝プラグイン本体の subdir（plugin.json のあるルート）を指す。
  # install の再実行はステージ先を中身どおりに置き換え、有効/無効の設定は残す。
  if tmo "$INSTALL_LIMIT" agy plugin install "$DIR/plugins/$NAME" >/dev/null; then
    echo "installed agy"
  else
    echo "error agy"
  fi
else
  echo "skip-no-cli agy"
fi
