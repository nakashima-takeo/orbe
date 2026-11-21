#!/usr/bin/env perl
# Orbe の取得・処理コマンドが出す JSONL（1 行 1 JSON オブジェクト）をローカルで検証する。
# 使い方: <コマンド> | perl check-jsonl.pl [--role fetch|process] [--judge] [--sample N]
# 終了コード: 0 = Orbe の形式規則違反なし（警告のみ含む）、1 = 形式規則違反あり
use strict;
use warnings;
use utf8;
use Encode qw(decode FB_CROAK LEAVE_SRC);
use JSON::PP qw(decode_json);
use Getopt::Long qw(GetOptions);

my $role   = 'fetch';
my $judge  = 0;
my $sample = 3;

GetOptions(
  'role=s'   => \$role,
  'judge!'   => \$judge,
  'sample=i' => \$sample,
) or die "Usage: $0 [--role fetch|process] [--judge] [--sample N]\n";

die "Invalid --role '$role' (expected fetch or process)\n"
  unless $role eq 'fetch' || $role eq 'process';

my $MAX_STDOUT_BYTES = 1024 * 1024;  # 1 MiB
my $MAX_ROW_BYTES    = 64 * 1024;    # 64 KiB
my $ID_PREFIX_MARGIN = 16;           # "<nodeId>:" 接頭ぶんの余裕

my $total_bytes   = 0;
my $row_count     = 0;
my $max_row_bytes = 0;
my $max_row_line  = 0;
my $missing_link  = 0;
my $missing_time  = 0;
my $short_body    = 0;
my $html_body     = 0;
my $raw_mention   = 0;
my $dup_body      = 0;

my %seen_id;
my %seen_body;
my %key_counts;
my @body_lens;
my @errors;
my @samples;

sub add_error {
  my ($msg) = @_;
  push @errors, $msg;
}

binmode(STDIN);
binmode(STDOUT, ':encoding(UTF-8)');

my $line_no = 0;
while (my $raw = <STDIN>) {
  $line_no++;
  $total_bytes += length($raw);

  (my $trimmed = $raw) =~ s/\r?\n\z//;
  next if $trimmed =~ /\A\s*\z/;

  $row_count++;
  my $row_bytes = length($trimmed);
  if ($row_bytes > $max_row_bytes) {
    $max_row_bytes = $row_bytes;
    $max_row_line  = $line_no;
  }

  my $utf8_ok = eval { decode('UTF-8', $trimmed, FB_CROAK | LEAVE_SRC); 1 };
  if (!$utf8_ok) {
    add_error("line $line_no: invalid UTF-8");
    next;
  }

  my $obj = eval { decode_json($trimmed) };
  if ($@ || ref($obj) ne 'HASH') {
    add_error("line $line_no: not a JSON object");
    next;
  }

  if ($row_bytes + $ID_PREFIX_MARGIN > $MAX_ROW_BYTES) {
    add_error(sprintf(
      "line %d: row is %.1f KiB (limit 64.0 KiB including downstream id prefix)",
      $line_no, ($row_bytes + $ID_PREFIX_MARGIN) / 1024
    ));
  }

  for my $k (keys %$obj) {
    $key_counts{$k}++;
  }

  # id: required non-empty string, unique within run
  if (!exists $obj->{id} || !defined $obj->{id} || ref($obj->{id}) ne '' || $obj->{id} eq '') {
    add_error("line $line_no: missing or non-string id");
  } else {
    my $id = "$obj->{id}";
    if ($seen_id{$id}++) {
      add_error("line $line_no: duplicate id '$id'");
    }
  }

  # body: required on fetch; track quality signals whenever present
  if ($role eq 'fetch') {
    if (!exists $obj->{body} || !defined $obj->{body} || ref($obj->{body}) ne '') {
      add_error("line $line_no: missing or non-string body");
    } elsif ($obj->{body} =~ /\A\s*\z/) {
      add_error("line $line_no: blank body");
    }
  }
  if (exists $obj->{body} && defined $obj->{body} && ref($obj->{body}) eq '') {
    my $body = $obj->{body};
    my $len  = length($body);
    push @body_lens, $len;
    $short_body++  if $len < 40;
    $html_body++   if $body =~ m{<(?:html|body|div|p|br|table|span|style|script)\b}i;
    $raw_mention++ if $body =~ /<@[UW][A-Z0-9]{6,}>/;
    $dup_body++    if $len > 0 && $seen_body{$body}++;
  }

  # link: http(s) URL when present; required for candidate rows when --judge
  if (exists $obj->{link} && defined $obj->{link}) {
    if (ref($obj->{link}) ne '' || $obj->{link} !~ m{\Ahttps?://\S+\z}i) {
      add_error("line $line_no: invalid link '$obj->{link}' (must be http/https URL)");
    }
  } else {
    $missing_link++;
  }

  # time: ISO 8601 when present
  if (exists $obj->{time} && defined $obj->{time}) {
    if (
      ref($obj->{time}) ne ''
      || $obj->{time} !~ /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})\z/
    ) {
      add_error("line $line_no: invalid time '$obj->{time}' (expected ISO 8601 with timezone)");
    }
  } else {
    $missing_time++;
  }

  if (@samples < $sample) {
    my $body_preview = defined($obj->{body}) && ref($obj->{body}) eq '' ? $obj->{body} : '';
    $body_preview =~ s/\s+/ /g;
    $body_preview = substr($body_preview, 0, 140) . (length($body_preview) > 140 ? '…' : '');
    push @samples, {
      line => $line_no,
      id   => defined($obj->{id})   ? "$obj->{id}"   : '(none)',
      link => defined($obj->{link}) ? "$obj->{link}" : '(none)',
      time => defined($obj->{time}) ? "$obj->{time}" : '(none)',
      body => $body_preview,
    };
  }
}

if ($total_bytes > $MAX_STDOUT_BYTES) {
  add_error(sprintf(
    "stdout is %.1f KiB (exceeds 1024.0 KiB limit)",
    $total_bytes / 1024
  ));
}

my @warnings;
if ($row_count == 0) {
  push @warnings, "0 rows emitted (verify whether the source truly has no matching items)";
}
if ($total_bytes > $MAX_STDOUT_BYTES * 0.75 && $total_bytes <= $MAX_STDOUT_BYTES) {
  push @warnings, sprintf("stdout is %.1f KiB (>75%% of 1 MiB limit)", $total_bytes / 1024);
}
if ($max_row_bytes > $MAX_ROW_BYTES * 0.75 && $max_row_bytes + $ID_PREFIX_MARGIN <= $MAX_ROW_BYTES) {
  push @warnings, sprintf(
    "largest row (line %d) is %.1f KiB (>75%% of 64 KiB limit)",
    $max_row_line, $max_row_bytes / 1024
  );
}
if ($judge && $missing_link > 0) {
  push @warnings, "$missing_link/$row_count rows have no link (rows without link cannot become task candidates)";
}
if ($row_count > 0 && $missing_time == $row_count && $role eq 'fetch') {
  push @warnings, "no rows include time (consider adding ISO 8601 time for ordering and freshness)";
}
if ($short_body > 0) {
  push @warnings, "$short_body/$row_count rows have very short body (<40 chars; check if body has enough context beyond a bare title)";
}
if ($html_body > 0) {
  push @warnings, "$html_body/$row_count rows appear to contain raw HTML tags (strip HTML before passing to LLM)";
}
if ($raw_mention > 0) {
  push @warnings, "$raw_mention/$row_count rows contain raw Slack user IDs like <\@U...> (resolve user names if practical)";
}
if ($dup_body > 0) {
  push @warnings, "$dup_body rows have identical body text to an earlier row";
}

my $status = @errors ? 'ERROR' : (@warnings ? 'WARN' : 'OK');
printf "status: %s\n", $status;
printf "rows: %d | stdout: %.1f / 1024.0 KiB | max_row: %.1f / 64.0 KiB%s\n",
  $row_count,
  $total_bytes / 1024,
  $max_row_bytes / 1024,
  ($max_row_line ? " (line $max_row_line)" : '');

if (@body_lens) {
  my @sorted = sort { $a <=> $b } @body_lens;
  my $med    = $sorted[ int(@sorted / 2) ];
  printf "body_chars: min=%d median=%d max=%d\n", $sorted[0], $med, $sorted[-1];
}

if (%key_counts) {
  my @keys = sort { $key_counts{$b} <=> $key_counts{$a} || $a cmp $b } keys %key_counts;
  my $list = join(', ', map { "$_($key_counts{$_})" } @keys);
  printf "fields: %s\n", $list;
}

if (@errors) {
  printf "errors (%d):\n", scalar(@errors);
  my $shown = @errors > 10 ? 10 : scalar(@errors);
  for my $i (0 .. $shown - 1) {
    printf "  - %s\n", $errors[$i];
  }
  printf "  - ... (%d more)\n", scalar(@errors) - $shown if @errors > $shown;
}

if (@warnings) {
  printf "warnings (%d):\n", scalar(@warnings);
  for my $w (@warnings) {
    printf "  - %s\n", $w;
  }
}

if (@samples) {
  printf "samples (%d):\n", scalar(@samples);
  for my $s (@samples) {
    printf "  [line %d] id=%s | link=%s | time=%s\n    body: %s\n",
      $s->{line}, $s->{id}, $s->{link}, $s->{time}, $s->{body};
  }
}

exit(@errors ? 1 : 0);
