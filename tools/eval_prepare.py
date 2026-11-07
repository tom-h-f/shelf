# /// script
# requires-python = ">=3.11"
# ///
"""Measure prepare.py naming accuracy against the Library, whose files are already named correctly.

Usage: uv run tools/eval_prepare.py --n 40 --work <scratch dir> [--seed 1]

Clones a random sample of Library Books/Papers PDFs and EPUBs (APFS clone, no extra disk) under
junk names, runs prepare.py --dry-run with and without embedded metadata, and compares the stems.
"""
import argparse
import json
import random
import re
import subprocess
import unicodedata
from pathlib import Path


def slug(text):
    text = "".join(c for c in unicodedata.normalize("NFKD", text) if not unicodedata.combining(c))
    return re.sub(r"[^a-z0-9]+", "-", re.sub(r"['’]", "", text.lower())).strip("-")

LIBRARY = Path.home() / "Library/Mobile Documents/com~apple~CloudDocs/Library"
PREPARE = Path(__file__).resolve().parent.parent / "scripts/prepare.py"
MAX_BYTES = 40_000_000


def split_stem(stem):
    m = re.match(r"(.*?)(?:-(\d{4}))?$", stem)
    return m.group(1), m.group(2)


def run(path, no_meta):
    cmd = ["uv", "run", "-q", str(PREPARE), str(path), "--dry-run"] + (["--no-meta"] if no_meta else [])
    out = subprocess.run(cmd, capture_output=True, text=True, cwd=path.parent)
    try:
        return json.loads(out.stdout)
    except json.JSONDecodeError:
        return {"error": out.stderr.strip().splitlines()[-1] if out.stderr.strip() else "no output"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=40)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--work", type=Path, required=True)
    args = ap.parse_args()

    pool = [
        p for p in LIBRARY.rglob("*")
        if p.suffix in (".pdf", ".epub") and p.parent.name in ("Books", "Papers")
        and p.is_file() and p.stat().st_size < MAX_BYTES and p.stat().st_blocks > 0
    ]
    random.Random(args.seed).shuffle(pool)
    sample = pool[: args.n]
    args.work = args.work.resolve()
    args.work.mkdir(parents=True, exist_ok=True)

    rows = []
    for i, src in enumerate(sample):
        d = args.work / f"{i:03d}"
        d.mkdir(exist_ok=True)
        dst = d / f"download ({i}){src.suffix}"
        if not dst.exists():
            subprocess.run(["cp", "-c", str(src), str(dst)], check=True)
        truth_body, truth_year = split_stem(src.stem)
        for mode in ("meta", "no-meta"):
            r = run(dst, mode == "no-meta")
            stem = r.get("stem") or ""
            body, year = split_stem(stem)
            main = slug((r.get("title") or "").split(":")[0])
            surname = slug(r["authors"][0].split()[-1]) if r.get("authors") else ""
            rows.append({
                "file": src.relative_to(LIBRARY).as_posix(), "mode": mode, "truth": src.stem, "got": stem,
                "exact_body": body == truth_body, "year_ok": year == truth_year,
                "core_ok": bool(main and surname and truth_body.startswith(main) and f"-{surname}" in truth_body),
                "confidence": r.get("confidence", 0.0), "error": r.get("error"),
            })

    for mode in ("meta", "no-meta"):
        rs = [r for r in rows if r["mode"] == mode]
        ok = [r for r in rs if r["exact_body"]]
        core = sum(r["core_ok"] for r in rs)
        print(f"\n== {mode}: {len(ok)}/{len(rs)} exact, {core}/{len(rs)} core (main title + surname), {sum(r['year_ok'] for r in rs)}/{len(rs)} year exact")
        for t in (0.5, 0.6, 0.7, 0.8, 0.9, 1.0):
            above = [r for r in rs if r["confidence"] >= t]
            right = sum(r["core_ok"] for r in above)
            print(f"   conf >= {t}: renamed {len(above)}, core right {right}, core wrong {len(above) - right}")
        for r in rs:
            if not r["exact_body"]:
                print(f"   x {r['confidence']:.2f} {r['truth']}\n          got {r['got'] or r['error']}")
    (args.work / "results.json").write_text(json.dumps(rows, indent=1))


if __name__ == "__main__":
    main()
