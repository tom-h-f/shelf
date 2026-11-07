# /// script
# requires-python = ">=3.11"
# ///
"""Measure extract_paper.py on a set of PDFs: text coverage and reading order vs pdftotext, optional similarity
to a hand-checked Markdown, and whether the full build passes epubcheck.

Usage: uv run tools/eval_extract.py --work DIR PDF[=REFERENCE.md] ...
"""
import argparse
import difflib
import re
import subprocess
from collections import Counter
from pathlib import Path

SKILL = Path.home() / ".claude/skills/print-article/scripts"


def words(text):
    text = re.sub(r"!\[[^\]]*\]\([^)]*\)|\[\^\d+\]|https?://\S+", " ", text)
    text = re.sub(r"[*_#>`\[\]]", " ", text)
    return [w for w in re.findall(r"[a-zà-ÿ]+", text.lower()) if len(w) > 2]


def bigrams(ws):
    return Counter(zip(ws, ws[1:]))


def overlap(a, b):
    inter = sum((a & b).values())
    return inter / max(1, sum(b.values()))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", type=Path, required=True)
    ap.add_argument("pdfs", nargs="+")
    args = ap.parse_args()
    for spec in args.pdfs:
        pdf, _, ref = spec.partition("=")
        pdf = Path(pdf)
        wd = args.work / re.sub(r"[^a-z0-9]+", "-", pdf.stem.lower())[:40]
        wd.mkdir(parents=True, exist_ok=True)
        run = subprocess.run(["uv", "run", "-q", str(SKILL / "extract_paper.py"), str(pdf), "--out", str(wd)], capture_output=True, text=True)
        if run.returncode:
            print(f"== {pdf.name[:50]}: extract FAILED\n{run.stderr[-600:]}")
            continue
        md = (wd / "article.md").read_text()
        raw = subprocess.run(["pdftotext", str(pdf), "-"], capture_output=True, text=True).stdout
        mw, rw = words(md), words(raw)
        coverage = len(set(rw) & set(mw)) / max(1, len(set(rw)))
        order = overlap(bigrams(mw), bigrams(rw))
        line = f"== {pdf.name[:50]}\n   {run.stdout.strip()}\n   coverage {coverage:.1%} | bigrams shared with pdftotext {order:.1%}"
        if ref:
            refw = words(Path(ref).read_text())
            sm = difflib.SequenceMatcher(None, refw, mw, autojunk=False)
            line += f" | similarity to reference {sm.ratio():.1%}"
        build = subprocess.run(["uv", "run", "-q", str(SKILL / "build_epub.py"), str(wd / "article.md"), "--out", str(wd / "out.epub"), "--no-cover"],
                               capture_output=True, text=True)
        if build.returncode:
            line += " | build FAILED: " + build.stderr.strip().splitlines()[-1][:150]
        else:
            check = subprocess.run(["epubcheck", str(wd / "out.epub")], capture_output=True, text=True)
            msgs = re.search(r"Messages: .*", check.stdout + check.stderr)
            line += f" | {msgs.group(0) if msgs else 'epubcheck ?'}"
        print(line)


if __name__ == "__main__":
    main()
