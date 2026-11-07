#!/bin/zsh
# Run one Shelf job headless, exactly as the app will. Usage: spike_claude.sh <convert|epub> <input> <workdir>
set -u
mode=$1 input=$2 work=$3
here=${0:A:h}/..
mkdir -p "$work"
lib="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Library"
print_dir="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Print"
common="This runs unattended from the Shelf menubar app. Never ask questions. Never send email or any message. Write only inside the Library, Print and the current working directory; put temporary files in the working directory, not /tmp. Tools are pre-approved by an allowlist: run one simple command per Bash call (no && or ; chains, no cd), and if a command is denied, retry it in a simpler allowed form before giving up. If a decision is ambiguous, take the skill's default and say so in the summary. Finish with the JSON result."
if [[ $mode == convert ]]; then
  prompt="Use the to-epub skill to turn this into an EPUB, then follow the skill it routes to fully, including its checks (epubcheck, Kindle Previewer) and its filing step. Input: $input
For the Kindle Previewer check, the CLI is already unpacked: run kindle-previewer-cli <copy>.epub --convert --qualitychecks --output <dir> (no pkgutil or brew steps).
$common"
else
  prompt="This is an existing EPUB, already renamed and stripped of embedded metadata: $input
Do not reconvert it. File it in the Library:
1. Identify the title, authors (as printed, middle names and initials kept) and original publication year from its text.
2. Choose Domain, Subject and lowercase hyphenated topic tags per $lib/README.md.
3. Copy it into the working directory, write title, authors and date into the copy with ebook-meta, then run: uv run ~/.claude/skills/book-epub/scripts/file_book.py <copy> --dir \"<Domain>/<Subject>/Books\" --tags \"<Domain>,<Subject>,Books,<topics>\"
4. Run epubcheck on the filed file. Don't run Kindle Previewer.
$common"
fi
cd "$work"
export PATH="/opt/homebrew/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
start=$(date +%s)
claude -p "$prompt" --model sonnet --output-format stream-json --verbose \
  --json-schema "$(cat $here/Resources/result-schema.json)" \
  --settings "$here/Resources/claude-settings.json" --permission-mode dontAsk \
  --strict-mcp-config --no-chrome --no-session-persistence \
  --add-dir "$HOME/Downloads" --add-dir "$lib" --add-dir "$print_dir" --add-dir "$HOME/.claude/skills" > job.log 2> job.err
code=$?
echo "exit $code, $(( $(date +%s) - start ))s" | tee timing.txt
