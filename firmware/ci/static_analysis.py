#!/usr/bin/env python3
"""パッチが足した C/C++ の行だけを対象に静的解析を行う。

SDK 本体の警告で落ちないように、muse-stackchan.patch が追加した行(新規ファイルは全行)に
出た指摘だけを数える。ビルド済みの compile_commands.json を使う。

  gcc         -Wall -Wextra で構文チェック(-fsyntax-only)。パッチの行の警告はエラー扱い
  cppcheck    --enable=warning,portability
  clang-tidy  bugprone-* / cert-* / concurrency-*(esp-clang の compile_commands.json を使う)
  clang-format 書式。SDK に .clang-format がないので firmware/ci/.clang-format を使い、
              既定では報告だけ(--format-strict で失敗にする)

既知の指摘は static-analysis-baseline.txt に「ツール|ファイル|チェック名」で書くと失敗にならない
(行番号は入れない。パッチを直して行がずれても効くように)。
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

SOURCE_EXT = {".c", ".cc", ".cpp"}
HEADER_EXT = {".h", ".hpp"}
TIDY_CHECKS = ",".join(
    [
        "-*",
        "bugprone-*",
        "cert-*",
        "concurrency-*",
        # 引数の並びが似ているという指摘で、C の API ではほぼ全関数に出るため外す
        "-bugprone-easily-swappable-parameters",
    ]
)
DIAG_RE = re.compile(r"^(?P<file>[^:\n]+):(?P<line>\d+):(?:(?P<col>\d+):)?\s*(?P<sev>warning|error|style|portability|performance|information):\s*(?P<msg>.*?)(?:\s*\[(?P<check>[^\]]+)\])?\s*$")


@dataclass(frozen=True)
class Finding:
    tool: str
    file: str  # SDK ルートからの相対パス(例: esp32/main/stackchan_head.c)
    line: int
    severity: str
    message: str
    check: str

    def key(self) -> str:
        return f"{self.tool}|{self.file}|{self.check}"

    def render(self) -> str:
        return f"{self.file}:{self.line}: [{self.tool}] {self.message} ({self.check})"


def added_lines(patch: Path) -> dict[str, set[int]]:
    """パッチの新しい側で追加された行番号を、ファイルごとに返す。"""
    result: dict[str, set[int]] = {}
    cur: set[int] | None = None
    new_line = 0
    for raw in patch.read_text(encoding="utf-8", errors="replace").splitlines():
        if raw.startswith("+++ "):
            path = raw[4:].strip()
            if path == "/dev/null":
                cur = None
                continue
            path = path[2:] if path.startswith("b/") else path
            if Path(path).suffix in SOURCE_EXT | HEADER_EXT:
                cur = result.setdefault(path, set())
            else:
                cur = None
            continue
        if raw.startswith("@@"):
            m = re.match(r"@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@", raw)
            new_line = int(m.group(1)) if m else 0
            continue
        if cur is None or raw.startswith("--- ") or raw.startswith("diff --git"):
            continue
        if raw.startswith("+"):
            cur.add(new_line)
            new_line += 1
        elif raw.startswith(" ") or raw == "":
            new_line += 1
        # "-" 行と "\ No newline" は新しい側の行番号を進めない
    return result


def line_ranges(lines: set[int]) -> list[tuple[int, int]]:
    out: list[tuple[int, int]] = []
    for n in sorted(lines):
        if out and out[-1][1] == n - 1:
            out[-1] = (out[-1][0], n)
        else:
            out.append((n, n))
    return out


class Context:
    def __init__(self, sdk: Path, targets: dict[str, set[int]]):
        self.sdk = sdk.resolve()
        self.targets = targets

    def rel(self, path: str, cwd: str | None = None) -> str | None:
        p = Path(path)
        if not p.is_absolute() and cwd:
            p = Path(cwd) / p
        try:
            return str(p.resolve().relative_to(self.sdk))
        except (ValueError, OSError):
            return None

    def keep(self, f: Finding) -> bool:
        return f.line in self.targets.get(f.file, set())


def load_db(build_dir: Path) -> list[dict]:
    db = build_dir / "compile_commands.json"
    if not db.is_file():
        raise SystemExit(f"{db} がありません。先にビルド(または reconfigure)してください")
    return json.loads(db.read_text())


def entry_args(entry: dict) -> list[str]:
    return list(entry["arguments"]) if "arguments" in entry else shlex.split(entry["command"])


def target_entries(ctx: Context, db: list[dict]) -> dict[str, dict]:
    out: dict[str, dict] = {}
    for e in db:
        rel = ctx.rel(e["file"], e.get("directory"))
        if rel and rel in ctx.targets and Path(rel).suffix in SOURCE_EXT:
            out[rel] = e
    return out


def parse_output(ctx: Context, tool: str, text: str, cwd: str | None) -> list[Finding]:
    found: list[Finding] = []
    for line in text.splitlines():
        m = DIAG_RE.match(line.strip())
        if not m:
            continue
        rel = ctx.rel(m.group("file"), cwd)
        if not rel:
            continue
        check = m.group("check") or ("compiler-error" if m.group("sev") == "error" else "")
        found.append(Finding(tool, rel, int(m.group("line")), m.group("sev"), m.group("msg"), check))
    return found


def run(cmd: list[str], cwd: str | None = None) -> subprocess.CompletedProcess:
    print("+", " ".join(shlex.quote(c) for c in cmd[:6]), "..." if len(cmd) > 6 else "", flush=True)
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)


def strip_output_flags(args: list[str]) -> list[str]:
    out: list[str] = []
    skip = False
    for a in args:
        if skip:
            skip = False
            continue
        if a in ("-o", "-MF", "-MT", "-MQ"):
            skip = True
            continue
        if a in ("-MD", "-MMD", "-c") or a.startswith("-Werror"):
            continue
        out.append(a)
    return out


def run_gcc(ctx: Context, entries: dict[str, dict]) -> list[Finding]:
    found: list[Finding] = []
    for rel, e in entries.items():
        args = strip_output_flags(entry_args(e)) + ["-fsyntax-only", "-Wall", "-Wextra", "-fdiagnostics-color=never"]
        r = run(args, cwd=e.get("directory"))
        found += parse_output(ctx, "gcc", r.stdout + r.stderr, e.get("directory"))
    return found


def run_cppcheck(ctx: Context, build_dir: Path, entries: dict[str, dict]) -> list[Finding]:
    found: list[Finding] = []
    db = str(build_dir / "compile_commands.json")
    for rel, e in entries.items():
        r = run(
            [
                "cppcheck",
                f"--project={db}",
                f"--file-filter={Path(e['file']).resolve() if Path(e['file']).is_absolute() else Path(e.get('directory', '.'), e['file']).resolve()}",
                "--enable=warning,portability",
                "--inline-suppr",
                "--quiet",
                "--suppress=missingIncludeSystem",
                "--suppress=missingInclude",
                "--suppress=unmatchedSuppression",
                "--template={file}:{line}:{column}: {severity}: {message} [{id}]",
            ]
        )
        found += parse_output(ctx, "cppcheck", r.stdout + r.stderr, None)
    return found


def run_clang_tidy(ctx: Context, clang_tidy: str, clang_build: Path) -> list[Finding]:
    db = load_db(clang_build)
    entries = target_entries(ctx, db)
    found: list[Finding] = []
    for rel, e in entries.items():
        r = run(
            [
                clang_tidy,
                "-p",
                str(clang_build),
                f"--checks={TIDY_CHECKS}",
                "--quiet",
                # esp-clang が知らない GCC 用の警告オプションで止まらないように
                "--extra-arg=-Wno-unknown-warning-option",
                "--extra-arg=-Wno-unused-command-line-argument",
                e["file"],
            ],
            cwd=e.get("directory"),
        )
        found += parse_output(ctx, "clang-tidy", r.stdout + r.stderr, e.get("directory"))
        if r.returncode != 0 and not r.stdout.strip():
            print(r.stderr[-4000:], file=sys.stderr)
    return found


def run_clang_format(ctx: Context, clang_format: str, style_file: Path) -> list[Finding]:
    found: list[Finding] = []
    for rel, lines in ctx.targets.items():
        path = ctx.sdk / rel
        if not path.is_file() or not lines:
            continue
        cmd = [clang_format, f"--style=file:{style_file}", "--dry-run", "--ferror-limit=0"]
        cmd += [f"--lines={a}:{b}" for a, b in line_ranges(lines)]
        r = run(cmd + [str(path)])
        for f in parse_output(ctx, "clang-format", r.stderr, None):
            found.append(Finding(f.tool, f.file, f.line, "format", "書式が .clang-format と違います", "clang-format"))
    return found


def load_baseline(path: Path | None) -> set[str]:
    if not path or not path.is_file():
        return set()
    return {
        line.strip()
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--patch", required=True, type=Path)
    ap.add_argument("--sdk", required=True, type=Path, help="パッチを当てた SDK のルート(esp32/ の親)")
    ap.add_argument("--build-dir", required=True, type=Path, help="GCC でビルドしたディレクトリ")
    ap.add_argument("--clang-build-dir", type=Path, help="IDF_TOOLCHAIN=clang で configure したディレクトリ")
    ap.add_argument("--clang-tidy", default=os.environ.get("CLANG_TIDY", ""))
    ap.add_argument("--clang-format", default=os.environ.get("CLANG_FORMAT", "clang-format"))
    ap.add_argument("--format-style", type=Path, default=Path(__file__).with_name(".clang-format"))
    ap.add_argument("--format-strict", action="store_true")
    ap.add_argument("--baseline", type=Path, default=Path(__file__).with_name("static-analysis-baseline.txt"))
    ap.add_argument("--tools", default="gcc,cppcheck,clang-tidy,clang-format")
    ap.add_argument("--summary", default=os.environ.get("GITHUB_STEP_SUMMARY"))
    args = ap.parse_args()

    targets = added_lines(args.patch)
    ctx = Context(args.sdk, targets)
    tools = set(args.tools.split(","))
    db = load_db(args.build_dir)
    entries = target_entries(ctx, db)
    print(f"対象: {', '.join(sorted(targets))}")
    print(f"compile_commands.json にある翻訳単位: {', '.join(sorted(entries))}")

    all_found: list[Finding] = []
    ran: list[str] = []
    if "gcc" in tools:
        all_found += run_gcc(ctx, entries)
        ran.append("gcc -Wall -Wextra")
    if "cppcheck" in tools:
        all_found += run_cppcheck(ctx, args.build_dir, entries)
        ran.append("cppcheck")
    if "clang-tidy" in tools:
        if not args.clang_tidy or not args.clang_build_dir:
            raise SystemExit("clang-tidy には --clang-tidy と --clang-build-dir が必要です")
        all_found += run_clang_tidy(ctx, args.clang_tidy, args.clang_build_dir)
        ran.append("clang-tidy")
    if "clang-format" in tools:
        all_found += run_clang_format(ctx, args.clang_format, args.format_style)
        ran.append("clang-format")

    # パッチの行だけ残し、ヘッダーが複数の翻訳単位から読まれた重複を除く
    uniq: dict[tuple, Finding] = {}
    for f in all_found:
        if ctx.keep(f):
            uniq.setdefault((f.tool, f.file, f.line, f.check, f.message), f)
    findings = sorted(uniq.values(), key=lambda f: (f.file, f.line, f.tool))
    baseline = load_baseline(args.baseline)

    blocking = [f for f in findings if f.key() not in baseline and (f.tool != "clang-format" or args.format_strict)]
    known = [f for f in findings if f.key() in baseline]
    advisory = [f for f in findings if f.tool == "clang-format" and not args.format_strict and f.key() not in baseline]

    lines = ["## 静的解析(パッチが足した行)", "", f"実行: {', '.join(ran)}", ""]
    if not blocking:
        lines.append("新しい指摘はありません。")
    else:
        lines.append(f"> [!CAUTION]\n> 新しい指摘が {len(blocking)} 件あります")
    lines.append("")
    for title, items in (("指摘", blocking), ("既知(baseline)", known), ("書式(報告のみ)", advisory)):
        if not items:
            continue
        lines += [f"<details{' open' if items is blocking else ''}><summary>{title}: {len(items)} 件</summary>", ""]
        lines += ["| 場所 | ツール | 内容 | チェック |", "|---|---|---|---|"]
        for f in items:
            msg = f.message.replace("|", "\\|")
            lines.append(f"| `{f.file}:{f.line}` | {f.tool} | {msg} | `{f.check}` |")
        lines += ["", "</details>", ""]
    if blocking:
        lines += [
            "既知として残す場合は `firmware/ci/static-analysis-baseline.txt` に次の行を足してください:",
            "",
            "```",
            *sorted({f.key() for f in blocking}),
            "```",
            "",
        ]

    text = "\n".join(lines) + "\n"
    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as fh:
            fh.write(text)
    print(text)
    for f in blocking:
        print(f"::error title={f.tool}::{f.render()}")
    for f in advisory[:50]:
        print(f"::warning title=clang-format::{f.render()}")
    return 1 if blocking else 0


if __name__ == "__main__":
    sys.exit(main())
