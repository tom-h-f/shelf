# /// script
# requires-python = ">=3.11"
# dependencies = ["pymupdf>=1.24", "pikepdf>=9", "rapidfuzz>=3", "lxml>=5"]
# ///
"""Rename a downloaded PDF or EPUB to its Library name and strip its metadata.

Usage:
  uv run prepare.py FILE [--dry-run] [--threshold T]
  uv run prepare.py FILE --rename-to NAME [--title "Title"]

Finds the best-matching title, authors and year from the file name (Anna's Archive pattern),
embedded metadata and the front-matter text, names it <title>-<authors>-<year>.<ext> per
Library/README.md, removes all embedded metadata with a full rewrite, and renames it in place.
It always renames. Naming falls back in order: Crossref (when the file carries a DOI), the best
title from the evidence (authors and year optional), the cleaned existing file name, and finally
download-<date added>. A taken name gets -2, -3. Prints one JSON object; "confident" is false when
the name rests on weak evidence, so a caller may refine it with --rename-to. Exit 0: done.
Exit 1: error, file untouched.
"""
import argparse
import datetime as dt
import json
import re
import sys
import subprocess
import tempfile
import unicodedata
import urllib.parse
import urllib.request
import uuid
import zipfile
from dataclasses import dataclass, field
from pathlib import Path

import pymupdf as fitz
import pikepdf
from lxml import etree
from rapidfuzz import fuzz

DEFAULT_THRESHOLD = 0.7
FRONT_PAGES = 8
FRONT_SPINE_DOCS = 8
THIS_YEAR = dt.date.today().year

SOURCE_WEIGHT = {"filename-aa": 1.0, "opf": 1.0, "info": 0.8, "xmp": 0.8, "title-page": 1.0, "outline": 0.4, "filename": 0.5}
JUNK_TITLE = re.compile(
    r"^(untitled|title|document|book|unknown|microsoft word|adobe|layout|cover|contents|copyright|\W*$)"
    r"|\.(docx?|indd|pdf|tex|qxd|p65)\b|^[0-9a-f]{16,}$|^[0-9a-f-]{32,}$|^(urn|isbn)\b|^\d+$|anna.s archive",
    re.I,
)
PUBLISHER = re.compile(
    r"\b(publish\w*|press|books|ltd|inc|plc|verlag|editions?|university|llc|group|media|house|sons|wiley|springer"
    r"|routledge|penguin|elsevier|verso|norton|macmillan|harper\w*|bloomsbury|random|knopf|doubleday|suhrkamp)\b",
    re.I,
)
AA_TRUNCATED_LEN = 50
DANGLING = re.compile(r"\b(the|a|an|of|and|or|to|in|on|for|with|by|from|at|their|his|her|its|our|des|der|die|das|und|von|la|le|les|de|du|et)\W*$|,\s*$", re.I)
NAME = re.compile(r"(?:[A-Z][\w’'.-]*|de|von|van|der|da|al-\w+)(?:\s+(?:[A-Z][\w’'.-]*|de|von|van|der|da|al-\w+)){1,4}")
SOURCE_RANK = {"opf": 0, "info": 0, "xmp": 0, "title-page": 2, "filename-aa": 1, "outline": 3, "filename": 4}
FOLD = str.maketrans({"ø": "o", "Ø": "O", "æ": "ae", "Æ": "AE", "œ": "oe", "Œ": "OE", "ß": "ss", "ł": "l", "Ł": "L", "đ": "d", "Đ": "D", "þ": "th", "ı": "i"})


def fold(text):
    text = unicodedata.normalize("NFKD", text.translate(FOLD))
    return "".join(c for c in text if not unicodedata.combining(c))


def slug(text):
    text = re.sub(r"['’]", "", fold(text).lower())
    return re.sub(r"[^a-z0-9]+", "-", text).strip("-")


def norm(text):
    return re.sub(r"\s+", " ", re.sub(r"[^a-z0-9]+", " ", fold(text).lower())).strip()


@dataclass
class Cand:
    value: str
    source: str
    extra: dict = field(default_factory=dict)


@dataclass
class Evidence:
    titles: list = field(default_factory=list)
    authors: list = field(default_factory=list)
    years: list = field(default_factory=list)
    front_text: str = ""
    lines: list = field(default_factory=list)


def clean_title(t, aa=False):
    if aa:
        t = re.sub(r"(?<=\w)\s*(?:_|\s-|-)\s+", ": ", t)
    t = re.sub(r"\s+", " ", t.replace("_", ":")).strip(" .;,-©")
    t = re.sub(r"^(?:chapter|ch\.?)\s+\w+\s*[:.-]?\s+", "", t, flags=re.I)
    t = re.sub(r"\s*\([^)]*\b(?:classics|series|library|edition|ed\.|vol\.?|volume)\b[^)]*\)\s*$", "", t, flags=re.I)
    t = re.sub(r"\s*:\s*", ": ", t)
    return t


def split_authors(s):
    s = re.sub(r"\s*\((auth|author|ed|eds|editor|editors|trans|translator)\.?\)\s*", " ", s, flags=re.I).strip()
    s = "; ".join(seg for seg in re.split(r"\s*;\s*", s) if not PUBLISHER.search(seg))
    parts = [p.strip() for p in re.split(r"\s*;\s*|\s*&\s*|\s+and\s+", s) if p.strip()]
    if len(parts) == 1 and s.count(",") >= 2:
        parts = [p.strip() for p in s.split(",") if p.strip()]
    out = []
    for p in parts:
        m = re.fullmatch(r"([^,]+),\s*([^,]+)", p)
        if m and len(m.group(1).split()) <= 2:
            p = f"{m.group(2)} {m.group(1)}"
        p = re.sub(r"\s+", " ", p).strip(" .,")
        if p and not re.search(r"\d|www\.|\.com", p) and not PUBLISHER.search(p):
            out.append(p)
    return out


def valid_year(y):
    return 1450 <= y <= THIS_YEAR


def parse_filename(path, ev):
    stem = path.stem
    parts = [p.strip() for p in stem.split(" -- ")]
    if len(parts) >= 3 and re.search(r"anna.s archive", parts[-1], re.I):
        ev.titles.append(Cand(clean_title(parts[0], aa=True), "filename-aa", {"truncated": len(parts[0]) >= AA_TRUNCATED_LEN}))
        ev.authors.append(Cand(split_authors(parts[1]), "filename-aa"))
        m = re.search(r"\b(1[4-9]\d\d|20\d\d)\b", parts[2]) if len(parts) > 3 else None
        if m and valid_year(int(m.group(1))):
            ev.years.append(Cand(int(m.group(1)), "filename-aa"))
    else:
        ev.titles.append(Cand(clean_title(re.sub(r"[-_]+", " ", re.sub(r"\s*\(\d+\)$", "", stem))), "filename"))


FIRST_PUB = re.compile(r"(?:first|originally)\s+(?:published|issued|printed)[^.\n]{0,60}?\b(1[4-9]\d\d|20\d\d)\b", re.I)
COPYRIGHT = re.compile(r"(?:copyright|©|\(c\))\s*(?:©\s*)?(?:by\s+)?[^\n]{0,40}?\b(1[4-9]\d\d|20\d\d)\b", re.I)


def years_from_text(text, ev):
    for m in FIRST_PUB.finditer(text):
        if valid_year(int(m.group(1))):
            ev.years.append(Cand(int(m.group(1)), "first-published"))
    for m in COPYRIGHT.finditer(text):
        if valid_year(int(m.group(1))):
            ev.years.append(Cand(int(m.group(1)), "copyright"))


def pdf_evidence(path, ev, use_meta):
    doc = fitz.open(path)
    if doc.needs_pass:
        raise RuntimeError("PDF is encrypted")
    if use_meta:
        info = doc.metadata or {}
        if info.get("title"):
            ev.titles.append(Cand(clean_title(info["title"]), "info"))
        if info.get("author"):
            ev.authors.append(Cand(split_authors(info["author"]), "info"))
        with pikepdf.open(path) as pdf:
            try:
                xmp = pdf.open_metadata()
                if xmp.get("dc:title"):
                    ev.titles.append(Cand(clean_title(str(xmp["dc:title"])), "xmp"))
                creators = xmp.get("dc:creator")
                if creators:
                    names = [c for c in creators] if isinstance(creators, list) else split_authors(str(creators))
                    ev.authors.append(Cand([n for a in names for n in split_authors(a)], "xmp"))
            except Exception:
                pass
        toc = doc.get_toc(simple=True)
        if toc and toc[0][0] == 1 and len(toc[0][1]) > 3:
            ev.titles.append(Cand(clean_title(toc[0][1]), "outline"))

    texts, lines = [], []
    for pno in range(min(FRONT_PAGES, doc.page_count)):
        page = doc[pno]
        texts.append(page.get_text())
        for block in page.get_text("dict")["blocks"]:
            for line in block.get("lines", []):
                spans = [s for s in line["spans"] if s["text"].strip()]
                if not spans:
                    continue
                text = " ".join(s["text"].strip() for s in spans)
                size = max(s["size"] for s in spans)
                lines.append((pno, line["bbox"][1], size, len(text), text))
                ev.lines.append(text)
    ev.front_text = "\n".join(texts)
    years_from_text(ev.front_text, ev)
    title_page_lines(lines, ev)


def title_page_lines(lines, ev):
    if not lines:
        return
    weights = {}
    for _, _, size, n, _ in lines:
        weights[round(size, 1)] = weights.get(round(size, 1), 0) + n
    body = max(weights, key=weights.get)
    big = [l for l in lines if l[2] >= body * 1.35 and 2 <= len(l[4]) <= 120]
    if not big:
        return
    top = max(l[2] for l in big)
    page = min(l[0] for l in big if l[2] >= top * 0.95)
    on_page = sorted((l for l in big if l[0] == page), key=lambda l: l[1])
    group, prev = [], None
    for l in on_page:
        if prev and abs(l[2] - prev[2]) / prev[2] < 0.15 and l[1] - prev[1] < prev[2] * 2.2:
            group.append(l)
        else:
            if group:
                ev.titles.append(Cand(clean_title(" ".join(g[4] for g in group)), "title-page", {"size": group[0][2]}))
            group = [l]
        prev = l
    if group:
        ev.titles.append(Cand(clean_title(" ".join(g[4] for g in group)), "title-page", {"size": group[0][2]}))


def read_opf(z):
    container = etree.fromstring(z.read("META-INF/container.xml"))
    opf_path = container.find(".//{*}rootfile").get("full-path")
    return opf_path, etree.fromstring(z.read(opf_path))


DC = "http://purl.org/dc/elements/1.1/"


def epub_evidence(path, ev, use_meta):
    with zipfile.ZipFile(path) as z:
        opf_path, opf = read_opf(z)
        if use_meta:
            for t in opf.iter(f"{{{DC}}}title"):
                if t.text and t.text.strip():
                    ev.titles.append(Cand(clean_title(t.text), "opf"))
                    break
            names = []
            for c in opf.iter(f"{{{DC}}}creator"):
                role = c.get("{http://www.idpf.org/2007/opf}role")
                refines = opf.xpath(f'//*[@refines="#{c.get("id")}" and @property="role"]') if c.get("id") else []
                role = role or (refines[0].text if refines else "aut")
                if role == "aut" and c.text:
                    names += split_authors(c.text)
            if names:
                ev.authors.append(Cand(names, "opf"))
        base = Path(opf_path).parent
        manifest = {i.get("id"): i.get("href") for i in opf.iter("{*}item")}
        texts = []
        for ref in list(opf.iter("{*}itemref"))[:FRONT_SPINE_DOCS]:
            href = manifest.get(ref.get("idref"))
            if not href:
                continue
            try:
                raw = z.read(str((base / href).as_posix()).lstrip("/"))
                html = etree.fromstring(raw, etree.HTMLParser(encoding="utf-8"))
            except (KeyError, etree.XMLSyntaxError, ValueError):
                continue
            nodes = [re.sub(r"\s+", " ", t).strip() for t in html.xpath("//body//text()")]
            nodes = [t for t in nodes if t]
            ev.lines += nodes
            texts.append("\n".join(nodes))
            for h in html.xpath("//h1|//h2|//*[contains(@class,'title')]")[:3]:
                t = re.sub(r"\s+", " ", " ".join(h.itertext())).strip()
                if 2 < len(t) < 150:
                    ev.titles.append(Cand(clean_title(t), "title-page"))
        ev.front_text = re.sub(r"[ \t]+", " ", "\n".join(texts))
        years_from_text(ev.front_text, ev)


def supported(value, text):
    if not text.strip() or not value.strip():
        return 0.0
    return fuzz.partial_ratio(norm(value), norm(text)) / 100


def strip_names(title, authors):
    """Remove author names merged into a title line, and citation tails after them.

    A name the title grammatically needs ("The Complete Works of William Shakespeare") stays.
    """
    for a in authors:
        for form in {a, fold(a)}:
            m = re.search(rf"(?:^|\s+|\s*[,/:-]\s*)(?:by\s+)?{re.escape(form)}\b", title, flags=re.I)
            if not m:
                continue
            before = title[: m.start()].strip(" .;,:/-")
            if m.start() == 0:
                title = title[m.end():]
            elif len(before) >= 3 and not DANGLING.search(before):
                title = before
    return title.strip(" .;,:/-")


def complete_from_lines(prefix, lines, authors):
    """Find the front-matter line run that a possibly truncated title fragment starts.

    Returns the run as printed (it may spell words differently from the file name), or None.
    """
    pn = norm(prefix)
    if len(pn) < 8:
        return None
    names = {norm(a) for a in authors}
    for i in range(len(lines)):
        if fuzz.ratio(norm(lines[i])[: len(pn)], pn[: len(norm(lines[i]))]) < 90:
            continue
        for k in (1, 2, 3):
            run = lines[i:i + k]
            nj = norm(" ".join(run))
            if k > 1 and (PUBLISHER.search(run[-1]) or norm(run[-1]) in names):
                break
            if len(nj) >= len(pn) - 3 and fuzz.ratio(nj[: len(pn)], pn) >= 90:
                return " ".join(run)
    return None


NOT_SUBTITLE = re.compile(r"^\s*(chapter|part|book|section|contents|copyright|[ivxlc]+\b\.?|\d+\b)", re.I)


def pick_title(ev, authors):
    cands = []
    for c in ev.titles:
        v = strip_names(c.value, authors) if authors else c.value
        if v and not JUNK_TITLE.search(v) and len(norm(v)) >= 2:
            cands.append(Cand(clean_title(v), c.source, c.extra))
    if not cands:
        return None, 0.0, []
    text = norm(ev.front_text)
    scored = []
    for c in cands:
        main = norm(c.value.split(":")[0])
        agree = {o.source for o in cands if o.source != c.source and fuzz.token_set_ratio(main, norm(o.value.split(":")[0])) >= 90}
        corroboration = min(1.0, sum(SOURCE_WEIGHT[s] for s in agree))
        in_text = supported(c.value.split(":")[0], text) if text and c.source != "title-page" else (1.0 if c.source == "title-page" else 0.0)
        score = 0.5 * corroboration + 0.5 * in_text
        scored.append((round(score, 3), c))
    scored.sort(key=lambda s: (-s[0], SOURCE_RANK[s[1].source], -len(s[1].value)))
    best_score, best = scored[0]
    title = best.value.split(":")[0].strip() if best.extra.get("truncated") else best.value
    best_main = norm(title.split(":")[0])
    for score, c in scored:
        n = norm(c.value)
        if (
            ":" in c.value
            and not NOT_SUBTITLE.search(c.value.split(":", 1)[1])
            and n.startswith(best_main)
            and len(n) > len(norm(title))
            and not c.extra.get("truncated")
            and (not text or supported(c.value, text) >= 0.9)
        ):
            title = c.value
    if ":" not in title:
        for score, c in scored:
            if c.extra.get("truncated") and ":" in c.value and norm(c.value).startswith(best_main):
                sub = c.value.split(":", 1)[1].strip()
                full = complete_from_lines(sub, ev.lines, authors)
                if full:
                    full = strip_names(clean_title(full), authors) if authors else clean_title(full)
                    title = f"{title}: {full}"
                elif not DANGLING.search(sub):
                    title = f"{title}: {sub}"
                break
    return title, best_score, [(s, c.value, c.source) for s, c in scored]


def text_form(name, text):
    toks = fold(name).split()
    if len(toks) < 2:
        return name
    first, last = re.escape(toks[0]), re.escape(toks[-1])
    found = re.findall(rf"\b{first}(?:\s+(?:[A-Z]\.|[A-Z][a-z]+)){{0,2}}\s+{last}\b", text)
    if not found:
        return name
    form = max(set(found), key=found.count)
    return name if form == fold(name) else re.sub(r"\s+", " ", form)


NOT_AUTHOR_LINE = re.compile(r"^(translat\w*|foreword|introduc\w*|preface|afterword|illustrat\w*|with an?\b|notes?\b|selected|cover)", re.I)


def dictionary():
    try:
        words = Path("/usr/share/dict/words").read_text().split()
    except OSError:
        return set()
    return {w for w in words if w.islower()}


DICT = dictionary()


def plausible_name(part):
    toks = [t.strip(".’'").lower() for t in part.split()]
    return any(len(t) > 1 and t not in DICT for t in toks)


def name_line(line):
    if NOT_AUTHOR_LINE.search(line.strip()):
        return None
    line = re.sub(r"^(?:by|edited by|von)\s+", "", line.strip(), flags=re.I).strip(" .,")
    if not 4 <= len(line) <= 80 or PUBLISHER.search(line) or re.search(r"\d", line):
        return None
    if line.isupper():
        line = line.title()
    parts = [x.strip() for x in re.split(r"\s*(?:,|&|\band\b|\bund\b)\s*", line) if x.strip()]
    if parts and all(NAME.fullmatch(x) and plausible_name(x) for x in parts):
        return parts
    return None


def authors_near_title(ev):
    mains = {norm(c.value.split(":")[0]) for c in ev.titles if c.value and not JUNK_TITLE.search(c.value)}
    mains = {m for m in mains if len(m) >= 3}
    for i, line in enumerate(ev.lines):
        nl = norm(line)
        if nl and any(fuzz.ratio(nl, m) >= 90 for m in mains):
            for nxt in ev.lines[i + 1:i + 8]:
                names = name_line(nxt)
                if names and not any(fuzz.ratio(norm(nxt), m) >= 90 for m in mains):
                    ev.authors.append(Cand(names, "title-page"))
                    return


def names_agree(a, b):
    return any(fuzz.ratio(slug(x), slug(y)) >= 80 for x in a for y in b)


def pick_authors(ev):
    lists = [c for c in ev.authors if c.value]
    if not lists:
        return [], 0.0
    folded = fold(ev.front_text)
    lower = folded.lower()
    scored = []
    for c in lists:
        surnames = [fold(a.split()[-1]).lower() for a in c.value]
        found = sum(1 for s in surnames if len(s) > 1 and re.search(rf"\b{re.escape(s)}\b", lower)) / len(surnames) if lower else 0.0
        corroborated = any(o is not c and names_agree(o.value, c.value) for o in lists)
        if c.source == "title-page":
            score = 1.0 if corroborated else 0.5
        else:
            score = 0.6 * found + 0.4 * (1.0 if corroborated else 0.0)
        scored.append((round(score, 3), c))
    scored.sort(key=lambda s: (-s[0], SOURCE_RANK[s[1].source]))
    best_score, best = scored[0]
    names = best.value
    for _, o in scored[1:]:
        if names_agree(o.value, names) and len(o.value) == len(names) and sum(map(len, o.value)) > sum(map(len, names)):
            names = o.value
    return [text_form(a, folded) for a in names], best_score


def pick_year(ev):
    first = [c.value for c in ev.years if c.source == "first-published"]
    if first:
        return min(first)
    copy = [c.value for c in ev.years if c.source == "copyright"]
    aa = [c.value for c in ev.years if c.source == "filename-aa"]
    if copy:
        return min(copy)
    return aa[0] if aa else None


DOI = re.compile(r"\b(10\.\d{4,9}/[^\s\"<>,;]+)", re.I)
CROSSREF_TIMEOUT = 6


def find_doi(ev, extra=""):
    m = DOI.search(extra + "\n" + ev.front_text)
    return m.group(1).rstrip(".)]") if m else None


def crossref(doi):
    """Title, authors and year for a DOI from Crossref, or None on any failure (offline, unknown DOI)."""
    url = "https://api.crossref.org/works/" + urllib.parse.quote(doi)
    req = urllib.request.Request(url, headers={"User-Agent": "Shelf/0.1 (local file organiser)"})
    try:
        with urllib.request.urlopen(req, timeout=CROSSREF_TIMEOUT) as r:
            msg = json.load(r)["message"]
    except Exception:
        return None
    title = " ".join((msg.get("title") or [""])[0].split())
    if not title:
        return None
    subtitle = " ".join((msg.get("subtitle") or [""])[0].split())
    if subtitle and norm(subtitle) not in norm(title):
        title = f"{title}: {subtitle}"
    authors = [f'{a.get("given", "")} {a["family"]}'.strip() for a in msg.get("author", []) if a.get("family")]
    parts = (msg.get("issued") or {}).get("date-parts") or [[None]]
    year = parts[0][0] if parts and parts[0] and isinstance(parts[0][0], int) else None
    return {"doi": doi, "title": title, "authors": authors, "year": year}


JUNK_STEM = re.compile(r"^(download|document|file|scan|untitled|img|image|book|paper|article|pdf|epub)\b", re.I)


def filename_stem(path):
    """The existing file name as a Library stem, if it says anything; None for names like 'download (3)'."""
    stem = path.stem.split(" -- ")[0]
    stem = re.sub(r"\s*\(\d+\)$", "", stem)
    words = [w for w in re.split(r"[^a-z]+", fold(stem).lower()) if len(w) >= 3]
    if len(words) < 2 or JUNK_STEM.match(stem.strip()):
        return None
    return slug(stem)


def date_added(path):
    try:
        out = subprocess.run(["mdls", "-raw", "-name", "kMDItemDateAdded", str(path)], capture_output=True, text=True, timeout=5).stdout
        if re.match(r"\d{4}-\d{2}-\d{2}", out):
            return out[:10]
    except Exception:
        pass
    st = path.stat()
    return dt.date.fromtimestamp(getattr(st, "st_birthtime", st.st_mtime)).isoformat()


def library_stem(title, authors, year):
    who = slug(authors[0]) + "-et-al" if len(authors) >= 3 else "-".join(slug(a) for a in authors)
    return "-".join(p for p in (slug(title), who, str(year) if year else "") if p)


def strip_pdf(path):
    with pikepdf.open(path) as pdf:
        if "/Info" in pdf.trailer:
            del pdf.trailer["/Info"]
        for obj in pdf.objects:
            if isinstance(obj, (pikepdf.Dictionary, pikepdf.Stream)):
                for key in ("/Metadata", "/PieceInfo"):
                    if key in obj:
                        del obj[key]
        with tempfile.NamedTemporaryFile(dir=path.parent, suffix=".pdf", delete=False) as tmp:
            pass
        pdf.save(tmp.name, fix_metadata_version=False)
    Path(tmp.name).replace(path)


HEAD_META = re.compile(rb"<meta\b(?=[^>]*\bname\s*=\s*[\"'](?!viewport)[^\"']*[\"'])[^>]*>\s*", re.I)
DROP_FILES = {"META-INF/calibre_bookmarks.txt", "iTunesMetadata.plist", "iTunesMetadata-original.plist"}


def strip_ncx(raw, uid, title):
    ncx = etree.fromstring(raw)
    head = ncx.find("{*}head")
    if head is not None:
        for m in list(head):
            name = m.get("name", "")
            if name == "dtb:uid":
                m.set("content", uid)
            elif not name.startswith("dtb:") or name == "dtb:generator":
                head.remove(m)
    for author in ncx.findall("{*}docAuthor"):
        ncx.remove(author)
    doc_title = ncx.find("{*}docTitle/{*}text")
    if doc_title is not None and title:
        doc_title.text = title
    return etree.tostring(ncx, xml_declaration=True, encoding="utf-8")


def strip_epub(path, title):
    with zipfile.ZipFile(path) as z:
        opf_path, opf = read_opf(z)
        version = opf.get("version", "2.0")
        meta = opf.find("{*}metadata")
        uid_id = opf.get("unique-identifier") or "uid"
        opf.set("unique-identifier", uid_id)
        old_title = next((t.text for t in meta.iter(f"{{{DC}}}title") if t.text), None)
        lang = next((l.text for l in meta.iter(f"{{{DC}}}language") if l.text), None)
        cover = next((m.get("content") for m in meta.iter("{*}meta") if m.get("name") == "cover"), None)
        ns = meta.nsmap.get(None) or "http://www.idpf.org/2007/opf"
        for child in list(meta):
            meta.remove(child)
        t = etree.SubElement(meta, f"{{{DC}}}title")
        t.text = title or old_title or ""
        if lang:
            etree.SubElement(meta, f"{{{DC}}}language").text = lang
        ident = etree.SubElement(meta, f"{{{DC}}}identifier", id=uid_id)
        ident.text = f"urn:uuid:{uuid.uuid4()}"
        if version.startswith("3"):
            m = etree.SubElement(meta, f"{{{ns}}}meta", property="dcterms:modified")
            m.text = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        if cover:
            etree.SubElement(meta, f"{{{ns}}}meta", name="cover", content=cover)
        new_opf = etree.tostring(opf, xml_declaration=True, encoding="utf-8")
        ncx_href = next((i.get("href") for i in opf.iter("{*}item") if i.get("media-type") == "application/x-dtbncx+xml"), None)
        ncx_path = (Path(opf_path).parent / ncx_href).as_posix().lstrip("./") if ncx_href else None
        new_ncx = strip_ncx(z.read(ncx_path), ident.text, t.text) if ncx_path in z.namelist() else None
        with tempfile.NamedTemporaryFile(dir=path.parent, suffix=".epub", delete=False) as tmp:
            pass
        with zipfile.ZipFile(tmp.name, "w") as out:
            out.writestr(zipfile.ZipInfo("mimetype"), z.read("mimetype") if "mimetype" in z.namelist() else b"application/epub+zip", compress_type=zipfile.ZIP_STORED)
            for info in z.infolist():
                if info.filename == "mimetype" or info.filename in DROP_FILES:
                    continue
                if info.filename == opf_path:
                    data = new_opf
                elif info.filename == ncx_path and new_ncx:
                    data = new_ncx
                elif info.filename.lower().endswith((".xhtml", ".html", ".htm")):
                    data = HEAD_META.sub(b"", z.read(info.filename))
                else:
                    data = z.read(info.filename)
                out.writestr(info.filename, data, compress_type=zipfile.ZIP_DEFLATED)
    Path(tmp.name).replace(path)


def rename(path, stem):
    ext = path.suffix.lower()
    for n in range(1, 100):
        target = path.with_name((stem if n == 1 else f"{stem}-{n}") + ext)
        if target == path:
            return path, "unchanged"
        if not target.exists():
            path.rename(target)
            return target, "renamed"
    return path, "target_exists"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("file", type=Path)
    ap.add_argument("--dry-run", action="store_true", help="report only, change nothing")
    ap.add_argument("--threshold", type=float, default=DEFAULT_THRESHOLD)
    ap.add_argument("--rename-to", help="Library stem chosen elsewhere, e.g. by Claude")
    ap.add_argument("--title", help="title for the stripped EPUB's dc:title with --rename-to")
    ap.add_argument("--no-meta", action="store_true", help="ignore embedded metadata (evaluation)")
    ap.add_argument("--no-network", action="store_true", help="skip the Crossref lookup")
    args = ap.parse_args()

    path = args.file.resolve()
    kind = path.suffix.lower().lstrip(".")
    if kind not in ("pdf", "epub") or not path.is_file():
        print(json.dumps({"error": f"not a PDF or EPUB file: {path}"}))
        return 1

    if args.rename_to:
        if not re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", args.rename_to):
            print(json.dumps({"error": "--rename-to must be a lowercase hyphenated stem with no extension"}))
            return 1
        strip_pdf(path) if kind == "pdf" else strip_epub(path, args.title)
        new, status = rename(path, args.rename_to)
        print(json.dumps({"new_path": str(new), "rename": status, "stripped": True, "confident": True, "naming": "given"}))
        return 0

    ev = Evidence()
    try:
        parse_filename(path, ev)
        (pdf_evidence if kind == "pdf" else epub_evidence)(path, ev, not args.no_meta)
    except Exception as e:
        print(json.dumps({"error": f"could not read {kind}: {e}"}))
        return 1

    authors_near_title(ev)
    authors, a_score = pick_authors(ev)
    title, t_score, t_cands = pick_title(ev, authors)
    year = pick_year(ev)
    confidence = round(min(t_score, a_score), 3) if title and authors else round(t_score * 0.5, 3) if title else 0.0
    naming = "evidence"
    found = None
    doi = find_doi(ev, path.stem)
    if doi and not args.no_network:
        found = crossref(doi)
    if found:
        title, authors, year, confidence, naming = found["title"], found["authors"], found["year"] or year, 1.0, "crossref"
    if title:
        stem = library_stem(title, authors, year)
    elif filename_stem(path):
        stem, naming = filename_stem(path), "filename"
    else:
        stem, naming = f"download-{date_added(path)}", "date"
    result = {
        "kind": kind,
        "title": title,
        "authors": authors,
        "year": year,
        "doi": doi,
        "stem": stem,
        "naming": naming,
        "confidence": confidence,
        "confident": naming == "crossref" or (naming == "evidence" and confidence >= args.threshold),
        "title_score": t_score,
        "author_score": a_score,
        "candidates": {
            "titles": t_cands,
            "authors": [(c.value, c.source) for c in ev.authors],
            "years": sorted({(c.value, c.source) for c in ev.years}),
        },
    }
    if args.dry_run:
        result["new_path"] = str(path)
        print(json.dumps(result, ensure_ascii=False))
        return 0

    try:
        strip_pdf(path) if kind == "pdf" else strip_epub(path, title)
    except Exception as e:
        print(json.dumps({"error": f"strip failed, file untouched: {e}"}))
        return 1
    result["stripped"] = True
    new, status = rename(path, stem)
    result["new_path"], result["rename"] = str(new), status
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
