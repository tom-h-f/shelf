# Shelf

macOS menubar app. Pick a recent download (PDF, EPUB, HTML, Markdown), a file, or a URL. Shelf tidies it, converts it to EPUB with the to-epub skills, files it in the iCloud Library, and optionally emails it to the Kindle (`frenchtom06_g2Shs0@kindle.com`).

Full plan: `~/.claude/plans/we-have-a-skill-golden-rabbit.md`.

## Pipeline per job
1. **Prepare** (`scripts/prepare.py`, PDF/EPUB only): renames the file in place in Downloads to `<title>-<authors>-<year>.<ext>` and strips all embedded metadata with a full rewrite. Below the confidence threshold it strips but doesn't rename (exit 2), and Claude picks the name, then calls `prepare.py --rename-to`.
2. **Convert and file**: headless `claude -p` runs to-epub (or, for an existing EPUB, identify plus `file_book.py`). Scoped tool allowlist, no MCP. Returns schema JSON.
3. **Send** (optional): Mail.app via AppleScript, from the approved sender to the Kindle address. The app sends, never Claude.

## Decisions (Tom, 2026-11-07)
- Author names stay as printed, middle names and initials included (`alyson-m-cole`, `olufemi-o-taiwo`). Same in prepare.py and file_book.py.
- Sender: thomas.harry.french@icloud.com via Mail.app.
- Originals stay in Downloads after filing (renamed and stripped).
- Headless runs use Sonnet (`--model sonnet`) for every job kind.
- Everything is filed in the Library, always: books in Books, papers, essays and web articles in Papers, encyclopedia entries in Reference (Tom, 2026-11-07).
- Papers and articles use an essay layout: cover, title once, byline "A, B and C", abstract, sections flowing, no contents page (the reader's nav still has it), journal/DOI/dates in About this edition at the end.
- Naming is forgiving: a title alone is enough. Fallbacks: best guess, then the cleaned existing filename, then `download-YYYY-MM-DD` (date added). prepare.py always renames; low confidence only means Claude may refine it.
- Jobs get broad Bash permissions with a deny list (messaging, ssh, keychain, git push, recursive claude). Runs use the claude.ai subscription (`apiKeySource: none`); `$` figures are API-equivalent estimates.
- `file_book.py` slug now folds accents (`zizek`, not `i-ek`), same as prepare.py.

## Constraints
- Swift 6.4 and Command Line Tools only: SwiftPM plus a hand-assembled `.app`, ad-hoc signed, installed to `~/Applications`.
- iCloud is the master. Never write into `~/Drive/My Drive/Library/`.
- No placeholder names or values. A name that can't be established goes to Claude, not to a guess.
- prepare.py runs once per file. After stripping, its evidence is gone, so a rerun reports `low_confidence`. The app records that it ran.

## prepare.py: measured 2026-11-07
Eval: `uv run tools/eval_prepare.py --n N --seed S --work DIR` clones Library files (named correctly by hand) under junk names. "Core" = main title plus first-author surname match. The exact-match figure is held down by ground-truth noise: hand-shortened titles and non-convention names such as `mcnay-2004-...`.

| set | mode | renamed at 0.7 | core right | real errors |
|---|---|---|---|---|
| seed 1, n=40 (tuning) | metadata | 20 | 18 | 0 (2 misses are ground-truth noise) |
| seed 2, n=60 (holdout) | metadata | 33 | 28 | 1 ("Chapter 30" prefix, since fixed); 43/60 exact |
| both | text only (`--no-meta`) | 0 | - | 0: all go to Claude |
| 11 Anna's Archive downloads | real | 9 | 9 | 0 (2 sent to Claude: 0.5, 0.6) |

- Threshold 0.7.
- Year: when given, it matched the Library 22/26 times, and 3 of the 4 others were the true original year. Otherwise the year is left out (README rule 4).
- Strip: PDF Info/XMP/PieceInfo removed, `pdftotext` byte-identical. EPUB OPF reduced to title, language, a new UUID, modified date and cover. NCX uid synced, docAuthor removed. epubcheck counts unchanged vs the original.

## Headless claude: measured 2026-11-07 (Sonnet)
| job | time | cost | denials | result |
|---|---|---|---|---|
| EPUB filing (Metastases) | 21s | $0.20 | 0 | filed Humanities/Psychoanalysis/Books, epubcheck 0/0 |
| URL article (Theses on Feuerbach) | 56s | $0.24 | 0 | Print/marx-theses-on-feuerbach, epubcheck 0/0, Kindle Supported/Success/0 |

- Kindle Previewer is unpacked once to `~/.local/share/kindle-previewer`, with wrapper `~/.local/bin/kindle-previewer-cli` (`scripts/setup-kindle-previewer.sh`). The skill's per-run unpack into a scratch path with spaces can't be allowlisted.
- `--add-dir ~/.claude/skills` is needed, or Bash path checks block reading skill files.
- Allowlist risk: `uv run` and `curl` are allowed, so a prompt-injected PDF could still run code as Tom. No MCP, ssh or osascript. Sandboxing is a possible later step.

## Build notes
- The macOS 27 SDK makes SwiftUI `@State` a macro whose plugin ships only with Xcode. `scripts/env.sh` pins the 26.x SDK from the CLT.
- Tests: `scripts/test.sh` (adds the CLT swift-testing plugin path, which the 26.x SDK doesn't find on its own).
- Install: `scripts/install.sh`.

## Status
- [x] 0a prepare.py + eval
- [x] 0b headless claude spike (EPUB, URL). Book PDF not yet run end to end.
- [x] App code: scanner, prepare, runner, stream parser, prompts, mailer, notifications, settings, login item. 17 unit tests.
- [x] Installed to ~/Applications/Shelf.app (ad-hoc signed, running)
- [ ] Visual check of the menu (needs Tom, screen not capturable from the terminal)
- [ ] First real job through the app; book PDF timing
- [ ] First test send to Kindle (needs Tom's OK)
