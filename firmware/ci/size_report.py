#!/usr/bin/env python3
"""ファームウェアのメモリ使用量を集計し、ベースとの差分としきい値の判定を行う。

使い方:
  collect  ビルド結果から metrics.json を作る(ビルドジョブの中で実行)
  report   metrics.json の集まりからジョブサマリを書き、しきい値を超えたら 1 で終わる

標準ライブラリだけで動く(dependencies.lock の読み取りだけ PyYAML があれば使う)。
"""

from __future__ import annotations

import argparse
import json
import os
import struct
import sys
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# collect
# ---------------------------------------------------------------------------

PART_ENTRY = struct.Struct("<2sBBII16sI")  # magic, type, subtype, offset, size, label, flags
PART_MAGIC = b"\xaa\x50"


def read_partitions(path: Path) -> dict[str, dict[str, int]]:
    """partition-table.bin(32 バイトのエントリの並び)を読む。"""
    data = path.read_bytes()
    parts: dict[str, dict[str, int]] = {}
    for off in range(0, len(data) - PART_ENTRY.size + 1, PART_ENTRY.size):
        magic, ptype, subtype, offset, size, label, _flags = PART_ENTRY.unpack_from(data, off)
        if magic != PART_MAGIC:
            break
        name = label.split(b"\0", 1)[0].decode("ascii", "replace")
        parts[name] = {"type": ptype, "subtype": subtype, "offset": offset, "size": size}
    return parts


def layout_by_name(size_json: dict[str, Any]) -> dict[str, dict[str, Any]]:
    """esp_idf_size --format json2 の layout を名前で引けるようにする。"""
    return {m["name"]: m for m in size_json.get("layout", [])}


def sum_parts(mem: dict[str, Any] | None, pred) -> int:
    if not mem:
        return 0
    return sum(p["size"] for name, p in mem.get("parts", {}).items() if pred(name))


def is_text(name: str) -> bool:
    return "text" in name or "vectors" in name


def is_bss(name: str) -> bool:
    return name.endswith(".bss") or ".bss" in name


def is_data(name: str) -> bool:
    return name.endswith(".data") or ".data" in name


def read_components(lock: Path) -> dict[str, str]:
    """dependencies.lock から依存コンポーネントの版を取り出す。"""
    if not lock.is_file():
        return {}
    try:
        import yaml  # type: ignore[import-untyped]
    except ImportError:
        return {}
    doc = yaml.safe_load(lock.read_text()) or {}
    out: dict[str, str] = {}
    for name, info in (doc.get("dependencies") or {}).items():
        if isinstance(info, dict) and "version" in info:
            out[name] = str(info["version"])
    return out


def collect(args: argparse.Namespace) -> int:
    size_json = json.loads(Path(args.size_json).read_text())
    layout = layout_by_name(size_json)
    diram = layout.get("DIRAM")
    iram = layout.get("IRAM")
    psram = layout.get("External RAM")

    build = Path(args.build_dir)
    parts = read_partitions(build / "partition_table" / "partition-table.bin")
    app_bin = build / f"{args.project}.bin"
    app_size = app_bin.stat().st_size
    ota0 = parts.get("ota_0") or parts.get("factory")
    srmodels = build / "srmodels" / "srmodels.bin"
    model = parts.get("model")

    metrics: dict[str, Any] = {
        "variant": args.variant,
        "image_size": size_json.get("total_size"),
        "diram_used": diram["used"] if diram else None,
        "diram_total": diram["total"] if diram else None,
        "diram_text": sum_parts(diram, is_text),
        "diram_bss": sum_parts(diram, is_bss),
        "diram_data": sum_parts(diram, is_data),
        "iram_used": iram["used"] if iram else None,
        "psram_bss": sum_parts(psram, is_bss),
        "app_bin": app_size,
        "app_partition": ota0["size"] if ota0 else None,
        "srmodels_bin": srmodels.stat().st_size if srmodels.is_file() else None,
        "model_partition": model["size"] if model else None,
        "layout": {
            name: {"used": m["used"], "total": m["total"], "parts": {k: v["size"] for k, v in m["parts"].items()}}
            for name, m in layout.items()
        },
        "components": read_components(Path(args.lock)) if args.lock else {},
        "commit": os.environ.get("GITHUB_SHA", ""),
    }
    Path(args.out).write_text(json.dumps(metrics, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({k: v for k, v in metrics.items() if k not in ("layout", "components")}, indent=2))
    return 0


# ---------------------------------------------------------------------------
# report
# ---------------------------------------------------------------------------

# サマリに出す行: (キー, 表示名)
ROWS = [
    ("diram_used", "DIRAM 静的使用量"),
    ("diram_text", "└ IRAM `.text`(DIRAM 内)"),
    ("diram_bss", "└ `.bss`"),
    ("diram_data", "└ `.data`"),
    ("iram_used", "IRAM(専用 32KB)"),
    ("psram_bss", "PSRAM `.bss`"),
    ("app_bin", "アプリ bin"),
    ("app_free", "アプリパーティション空き"),
    ("srmodels_bin", "srmodels.bin"),
    ("model_free", "model パーティション空き"),
]

# 主要なコンポーネントだけサマリに出す(全部は metrics.json にある)
KEY_COMPONENTS = ["espressif/esp-sr", "espressif/esp-dl", "lvgl/lvgl", "espressif/m5stack_core_s3", "idf"]


def derived(m: dict[str, Any]) -> dict[str, Any]:
    m = dict(m)
    if m.get("app_partition") and m.get("app_bin") is not None:
        m["app_free"] = m["app_partition"] - m["app_bin"]
        m["app_ratio"] = m["app_bin"] / m["app_partition"]
    if m.get("model_partition") and m.get("srmodels_bin") is not None:
        m["model_free"] = m["model_partition"] - m["srmodels_bin"]
    return m


def load_dir(path: Path | None) -> dict[str, dict[str, Any]]:
    out: dict[str, dict[str, Any]] = {}
    if not path or not path.is_dir():
        return out
    for f in sorted(path.rglob("metrics.json")):
        m = json.loads(f.read_text())
        out[m["variant"]] = derived(m)
    return out


def fmt(n: Any) -> str:
    return "—" if n is None else f"{n:,}"


def fmt_delta(cur: Any, base: Any) -> str:
    if cur is None or base is None:
        return ""
    d = cur - base
    if d == 0:
        return "±0"
    return f"{d:+,}"


def check_budget(variant: str, m: dict[str, Any], budget: dict[str, Any]) -> tuple[list[str], list[str]]:
    """(失敗, 注意) のメッセージを返す。"""
    errors: list[str] = []
    notes: list[str] = []
    defaults = budget.get("default", {})
    vb = {**defaults, **budget.get("variants", {}).get(variant, {})}

    ratio_max = vb.get("app_ratio_max")
    if ratio_max is not None and m.get("app_ratio") is not None:
        if m["app_ratio"] > ratio_max:
            errors.append(
                f"アプリ bin がパーティションの {m['app_ratio']:.1%} を使っています(上限 {ratio_max:.0%})"
            )

    for key, label in (("diram_used", "DIRAM 静的使用量"), ("app_bin", "アプリ bin")):
        limit = vb.get(f"{key}_max")
        if limit is None:
            if key == "diram_used":
                notes.append(f"{label} の上限が `firmware/ci/memory-budget.json` に未設定です")
            continue
        if m.get(key) is not None and m[key] > limit:
            errors.append(f"{label} {m[key]:,} が上限 {limit:,} を {m[key] - limit:,} バイト超えています")
    return errors, notes


def report(args: argparse.Namespace) -> int:
    cur = load_dir(Path(args.current))
    base = load_dir(Path(args.base)) if args.base else {}
    budget = json.loads(Path(args.budget).read_text()) if args.budget else {}
    expected = [v for v in (args.expect or "").split(",") if v]

    lines: list[str] = ["## ファームウェアのメモリ使用量", ""]
    if args.base_label:
        lines.append(f"比較対象: {args.base_label}" if base else f"比較対象 {args.base_label} の計測値が見つかりませんでした(差分なし)")
        lines.append("")

    failed = False
    missing = [v for v in expected if v not in cur]
    if missing:
        lines.append(f"> [!WARNING]\n> 計測値がないバリアント: {', '.join(missing)}(ビルド失敗またはスキップ)")
        lines.append("")

    all_errors: list[str] = []
    all_notes: list[str] = []
    for variant, m in cur.items():
        errs, notes = check_budget(variant, m, budget)
        all_errors += [f"`{variant}`: {e}" for e in errs]
        all_notes += [f"`{variant}`: {n}" for n in notes]
    if all_errors:
        failed = True
        lines.append("> [!CAUTION]\n> しきい値を超えました\n>")
        lines += [f"> - {e}" for e in all_errors]
        lines.append("")
    if all_notes:
        lines += [f"- {n}" for n in all_notes]
        lines.append("")

    variants = list(cur)
    if variants:
        header = "| 項目 | " + " | ".join(f"`{v}`" for v in variants) + " |"
        lines += [header, "|---|" + "---:|" * len(variants)]
        for key, label in ROWS:
            cells = []
            for v in variants:
                c = cur[v].get(key)
                b = base.get(v, {}).get(key)
                d = fmt_delta(c, b)
                cells.append(fmt(c) + (f" ({d})" if d else ""))
            if all(c == "—" for c in cells):
                continue
            lines.append(f"| {label} | " + " | ".join(cells) + " |")
        ratios = [cur[v].get("app_ratio") for v in variants]
        if any(r is not None for r in ratios):
            lines.append("| アプリ bin / パーティション | " + " | ".join("—" if r is None else f"{r:.1%}" for r in ratios) + " |")
        lines.append("")
        lines.append("括弧内はベースとの差(バイト)。DIRAM は内部 RAM の静的配置で、実行時のヒープは含みません。")
        lines.append("")

        comps = {v: cur[v].get("components", {}) for v in variants}
        first = comps[variants[0]]
        if first:
            lines += ["<details><summary>依存コンポーネントの版</summary>", ""]
            lines += ["| コンポーネント | 版 | ベース |", "|---|---|---|"]
            base_comps = base.get(variants[0], {}).get("components", {})
            names = [n for n in KEY_COMPONENTS if n in first] + sorted(n for n in first if n not in KEY_COMPONENTS)
            for n in names:
                bv = base_comps.get(n, "")
                mark = " ⚠️" if bv and bv != first[n] else ""
                lines.append(f"| `{n}` | {first[n]}{mark} | {bv} |")
            lines += ["", "</details>", ""]

        lines += ["<details><summary>メモリ種別ごとの内訳</summary>", ""]
        for v in variants:
            lines += [f"**{v}**", "", "| 種別 / セクション | サイズ | 差 |", "|---|---:|---:|"]
            blay = base.get(v, {}).get("layout", {})
            for name, mem in cur[v].get("layout", {}).items():
                bmem = blay.get(name, {})
                lines.append(f"| **{name}** used / total | {fmt(mem['used'])} / {fmt(mem['total'])} | {fmt_delta(mem['used'], bmem.get('used'))} |")
                for sec, size in mem["parts"].items():
                    lines.append(f"| {sec} | {fmt(size)} | {fmt_delta(size, bmem.get('parts', {}).get(sec))} |")
            lines.append("")
        lines += ["</details>", ""]

    text = "\n".join(lines) + "\n"
    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as f:
            f.write(text)
    else:
        sys.stdout.write(text)
    for e in all_errors:
        print(f"::error title=メモリしきい値::{e}")
    if missing and args.fail_on_missing:
        failed = True
    return 1 if failed else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    c = sub.add_parser("collect")
    c.add_argument("--variant", required=True)
    c.add_argument("--size-json", required=True, help="idf.py size --format json2 の出力")
    c.add_argument("--build-dir", required=True)
    c.add_argument("--project", default="muse-gadget")
    c.add_argument("--lock", help="dependencies.lock")
    c.add_argument("--out", required=True)
    c.set_defaults(func=collect)

    r = sub.add_parser("report")
    r.add_argument("--current", required=True, help="今回の metrics.json があるディレクトリ")
    r.add_argument("--base", help="ベースの metrics.json があるディレクトリ")
    r.add_argument("--base-label", default="")
    r.add_argument("--budget", help="memory-budget.json")
    r.add_argument("--expect", help="計測値があるはずのバリアント(カンマ区切り)")
    r.add_argument("--fail-on-missing", action="store_true")
    r.add_argument("--summary", default=os.environ.get("GITHUB_STEP_SUMMARY"))
    r.set_defaults(func=report)

    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
