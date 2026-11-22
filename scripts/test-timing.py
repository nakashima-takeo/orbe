#!/usr/bin/env python3
"""XCTest の出力から、テストごと・クラスごとの所要時間を集計し、Markdown で標準出力へ書き出す。

  python3 scripts/test-timing.py <log>...

log は、`swift test` の出力か、`gh run view <run> --log` で取得した GitHub Actions のログ（各行の先頭の
ジョブ名・ステップ名・時刻は読み飛ばす）。直列実行の XCTest が出す `Test Case … (N seconds)` の行を数えて足す。

- CI: `build-test` のテストのステップが `swift test` の出力を残し、次のステップがこのスクリプトに通して、
  ジョブの要約とステップのログの両方へ出す。
- 取得したログ: `gh run view <run> --log > run.log` で取得し、`python3 scripts/test-timing.py run.log` に通す。
  1 つ渡すと、合計、クラス別とテスト別の上位、全クラスの表を出す。
- 複数のログの比較: 2 つ以上渡すと、クラス別の合計をログごとに並べ、最小・中央値・最大を添えた表を出す。

照合: バンドル（最上位のスイート `All tests` または `Selected tests` の 1 つ）ごとに、数えた本数と秒数を、
XCTest の合計の行（`Executed N tests, … in X (Y) seconds`）の N と X に突き合わせる。秒数の差の許容は、
小数 3 桁の丸めの上限（0.0005 ×（N + 1）秒）。

終了コード: 0 は、全部のバンドルが終わりまで走り、照合が合ったこと（比較に使える記録）。1 は、それ以外
（バンドルが途中で終わった、照合が合わない、合計の行や結果の行を読めない）。テストの失敗だけでは 1 にしない。
1 のときも、理由を出力の先頭に出し、読めた分の集計を出す。

クラスの合計には、クラス単位の準備（`class func setUp`）と後片付けの時間が入らない。Swift Testing の結果は
集計しない。
"""

import re
import statistics
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import List, NamedTuple, Optional

TOP = 20
CASE_START = re.compile(r"Test Case '-\[(\S+)\.(\S+) (\S+)\]' started\.")
CASE_END = re.compile(r"Test Case '-\[(\S+)\.(\S+) (\S+)\]' (passed|failed|skipped) \(([\d.]+) seconds\)")
BUNDLE_START = re.compile(r"Test Suite '(?:All tests|Selected tests)' started at")
BUNDLE_END = re.compile(r"Test Suite '(?:All tests|Selected tests)' (?:passed|failed) at")
EXECUTED = re.compile(r"Executed (\d+) tests?, .* in ([\d.]+) \(([\d.]+)\) seconds")


class Case(NamedTuple):
    target: str
    cls: str
    test: str
    result: str
    ms: int

    @property
    def class_name(self) -> str:
        return f"{self.target}.{self.cls}"

    @property
    def name(self) -> str:
        return f"{self.target}.{self.cls}.{self.test}"


class Executed(NamedTuple):
    count: int
    ms: int
    wall_ms: int


class Bundle:
    def __init__(self) -> None:
        self.cases: List[Case] = []
        self.unfinished: Optional[str] = None
        self.ended = False
        self.executed: Optional[Executed] = None


def to_ms(seconds: str) -> int:
    # XCTest の秒数は小数 3 桁。整数のミリ秒で足して、合計と順位が Python の版（float の sum の実装）によって変わらないようにする。
    return round(float(seconds) * 1000)


def sec(ms: float) -> str:
    return f"{ms / 1000:.3f}"


def parse(path: str) -> List[Bundle]:
    bundles: List[Bundle] = []
    bundle: Optional[Bundle] = None
    closing = False
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = CASE_END.search(line)
            if m and bundle:
                bundle.cases.append(Case(m[1], m[2], m[3], m[4], to_ms(m[5])))
                bundle.unfinished = None
                continue
            m = CASE_START.search(line)
            if m and bundle:
                bundle.unfinished = f"{m[1]}.{m[2]}.{m[3]}"
                continue
            if BUNDLE_START.search(line):
                bundle = Bundle()
                bundles.append(bundle)
                closing = False
                continue
            if BUNDLE_END.search(line) and bundle:
                bundle.ended = True
                closing = True
                continue
            m = EXECUTED.search(line)
            if m and closing and bundle:
                bundle.executed = Executed(int(m[1]), to_ms(m[2]), to_ms(m[3]))
                closing = False
    return bundles


def problems(bundles: List[Bundle]) -> List[str]:
    """記録を比較に使えない理由の一覧（Markdown の行）。空なら、比較に使える記録。"""
    lines: List[str] = []
    for b in bundles:
        if b.executed is None and b.ended:
            lines.append(
                "> **XCTest の合計の行（`Executed …`）を読めない。** テストの失敗ではなく、"
                "集計（`scripts/test-timing.py`）が XCTest の出力の形に合っていない。"
            )
            continue
        if b.executed is None:
            lines.append("> **テストの実行が途中で終わった。** 記録は途中まで。")
            if b.unfinished:
                lines.append(f"> - 終わらなかったテスト: `{b.unfinished}`")
            continue
        counted = sum(c.ms for c in b.cases)
        bound = 0.5 * (b.executed.count + 1)
        diff = abs(counted - b.executed.ms)
        if b.executed.count != len(b.cases) or diff > bound:
            lines.append(
                "> **集計が XCTest の値と合わない。** テストの失敗ではなく、集計（`scripts/test-timing.py`）の不一致。"
            )
            lines.append(f"> - 本数: XCTest {b.executed.count}、集計 {len(b.cases)}")
            lines.append(
                f"> - 秒数: XCTest {sec(b.executed.ms)}、集計 {sec(counted)}（差 {sec(diff)}、丸めの上限 {sec(bound)}）"
            )
    if not lines and not any(b.cases for b in bundles):
        lines.append("> **テストの結果の行がログに無い。** テストが 1 本も走らなかったか、XCTest の出力の形が変わった。")
    return lines


def class_ms(bundles: List[Bundle]) -> "defaultdict[str, List[int]]":
    by: "defaultdict[str, List[int]]" = defaultdict(list)
    for b in bundles:
        for c in b.cases:
            by[c.class_name].append(c.ms)
    return by


def summary(bundles: List[Bundle]) -> List[str]:
    out = ["## テストの所要時間", ""]
    reasons = problems(bundles)
    out += reasons
    cases = [c for b in bundles for c in b.cases]
    if not cases:
        return out
    if reasons:
        out.append("")
    total = sum(c.ms for c in cases)
    results = Counter(c.result for c in cases)
    out.append(
        f"- 各テストの秒数の合計: **{sec(total)} 秒**（{len(cases)} 本。"
        f"成功 {results['passed']}、失敗 {results['failed']}、skip {results['skipped']}）"
    )
    done = [b for b in bundles if b.executed]
    if done:
        executed = sum(b.executed.ms for b in done)
        wall = sum(b.executed.wall_ms for b in done)
        counted = sum(c.ms for b in done for c in b.cases)
        out.append(
            f"- XCTest の `Executed` の値: {sec(executed)} 秒（集計との差 {(counted - executed) / 1000:+.3f} 秒。"
            f"実時間 {sec(wall)} 秒）"
        )

    classes = sorted(class_ms(bundles).items(), key=lambda kv: (-sum(kv[1]), kv[0]))

    def class_table(rows):
        table = ["| 順位 | クラス | 本数 | 合計（秒） | 割合 |", "|---:|---|---:|---:|---:|"]
        for i, (name, ms) in enumerate(rows, 1):
            share = f"{100 * sum(ms) / total:.1f}%" if total else "-"
            table.append(f"| {i} | {name} | {len(ms)} | {sec(sum(ms))} | {share} |")
        return table

    out += ["", f"### クラス別の上位 {TOP}", ""]
    out += class_table(classes[:TOP])
    out += ["", f"### テスト別の上位 {TOP}", "", "| 順位 | テスト | 結果 | 秒 |", "|---:|---|---|---:|"]
    for i, c in enumerate(sorted(cases, key=lambda c: (-c.ms, c.name))[:TOP], 1):
        out.append(f"| {i} | {c.name} | {c.result} | {sec(c.ms)} |")
    out += ["", f"<details><summary>全クラス（{len(classes)}）</summary>", ""]
    out += class_table(classes)
    out += ["", "</details>"]
    return out


def comparison(paths: List[str], parsed: List[List[Bundle]]) -> List[str]:
    names = [Path(p).name for p in paths]
    out = [f"## テストの所要時間（{len(paths)} 回の比較）", ""]
    for name, bundles in zip(names, parsed):
        reasons = problems(bundles)
        if reasons:
            out += [f"`{name}`:", ""] + reasons + [""]
    sums = [{k: sum(v) for k, v in class_ms(bundles).items()} for bundles in parsed]
    out.append("| クラス | " + " | ".join(names) + " | 最小 | 中央値 | 最大 |")
    out.append("|---|" + "---:|" * (len(names) + 3))

    def row(label: str, values: List[Optional[int]]) -> str:
        present = [v for v in values if v is not None]
        cells = ["-" if v is None else sec(v) for v in values]
        stats = [min(present), statistics.median(present), max(present)]
        return f"| {label} | " + " | ".join(cells + [sec(v) for v in stats]) + " |"

    out.append(row("合計", [sum(s.values()) for s in sums]))
    keys = set().union(*sums)
    medians = {k: statistics.median([s[k] for s in sums if k in s]) for k in keys}
    for k in sorted(keys, key=lambda k: (-medians[k], k)):
        out.append(row(k, [s.get(k) for s in sums]))
    return out


def main() -> int:
    paths = sys.argv[1:]
    if not paths:
        print(__doc__, file=sys.stderr)
        return 2
    parsed = [parse(p) for p in paths]
    out = summary(parsed[0]) if len(paths) == 1 else comparison(paths, parsed)
    print("\n".join(out))
    return 1 if any(problems(bundles) for bundles in parsed) else 0


if __name__ == "__main__":
    sys.exit(main())
