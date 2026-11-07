#!/bin/zsh
# Unpack Kindle Previewer once and put a space-free wrapper on PATH: ~/.local/bin/kindle-previewer-cli
set -euo pipefail
dest="$HOME/.local/share/kindle-previewer"
cli="$dest/component.pkg/Payload/Applications/Kindle Previewer 4.app/Contents/MacOS/KindlePreviewer4CLI"
if [[ ! -x "$cli" ]]; then
  pkg="$(brew --cache --cask kindle-previewer)"
  [[ -f "$pkg" ]] || brew fetch --cask kindle-previewer
  rm -rf "$dest"
  pkgutil --expand-full "$pkg" "$dest"
fi
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/kindle-previewer-cli" <<WRAP
#!/bin/zsh
# Kindle Previewer 4 CLI. Creates the --output folder first, which the CLI requires.
args=("\$@")
for i in {1..\$#args}; do [[ "\${args[i]}" == --output ]] && mkdir -p "\${args[i+1]}"; done
exec "$cli" "\$@"
WRAP
chmod +x "$HOME/.local/bin/kindle-previewer-cli"
echo "kindle-previewer-cli -> $cli"
