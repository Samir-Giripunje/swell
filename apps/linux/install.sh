#!/bin/sh
# Installs Swell for Linux from this checkout: dependencies, the `swell` launcher, the settings app in your
# app menu, and (if you had it) start at login. Moves settings over from the older Whisper Dictation app.
# Usage: apps/linux/install.sh        Rerun after pulling to pick up changes.
set -eu

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="$HOME/.config/swell"
LEGACY_CONFIG_DIR="$HOME/.config/whisper-dictate"
LEGACY_APP_DIR="$HOME/tools/whisper-dictate"
BIN_DIR="$HOME/.local/bin"
APPLICATIONS_DIR="$HOME/.local/share/applications"
AUTOSTART_DIR="$HOME/.config/autostart"

for tool in xclip xprop xrandr; do
  command -v "$tool" >/dev/null 2>&1 || echo "warning: $tool is missing; install it with: sudo apt install x11-utils xclip x11-xserver-utils"
done
/usr/bin/python3 -c "import gi" 2>/dev/null || echo "warning: the settings app needs GTK for Python: sudo apt install python3-gi gir1.2-gtk-3.0"

if ! command -v uv >/dev/null 2>&1 && [ ! -x "$BIN_DIR/uv" ]; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi
UV="$(command -v uv || echo "$BIN_DIR/uv")"
"$UV" sync --project "$APP_DIR" --no-dev --quiet

mkdir -p "$CONFIG_DIR" "$BIN_DIR" "$APPLICATIONS_DIR"
for file in settings.json server_token writer_prompt.md; do
  if [ -e "$LEGACY_CONFIG_DIR/$file" ] && [ ! -e "$CONFIG_DIR/$file" ]; then
    cp -p "$LEGACY_CONFIG_DIR/$file" "$CONFIG_DIR/$file"
    echo "Moved over $file from Whisper Dictation"
  fi
done
# Rephrasing (Medium, High, corrections) runs on Ollama: the 7B model on an NVIDIA GPU, the 1.7B one on the CPU.
if nvidia-smi -L >/dev/null 2>&1; then CLEANUP_MODEL="qwen2.5:7b"; else CLEANUP_MODEL="qwen3:1.7b"; fi
if command -v ollama >/dev/null 2>&1; then
  ollama pull "$CLEANUP_MODEL" >/dev/null && echo "Rephrasing model ready: $CLEANUP_MODEL"
else
  echo "note: install Ollama for Medium/High rephrasing (Off and Low work without it):"
  echo "  curl -fsSL https://ollama.com/install.sh | sh && ollama pull $CLEANUP_MODEL"
fi

if [ -e "$LEGACY_APP_DIR/vocab.txt" ] && [ ! -e "$CONFIG_DIR/vocab.txt" ]; then
  cp "$LEGACY_APP_DIR/vocab.txt" "$CONFIG_DIR/vocab.txt"
fi

cat > "$BIN_DIR/swell" <<EOF
#!/bin/sh
mkdir -p "\$HOME/.cache/swell"
exec "$UV" run --project "$APP_DIR" --no-dev --frozen swell "\$@" >> "\$HOME/.cache/swell/swell.log" 2>&1
EOF
chmod +x "$BIN_DIR/swell"

cat > "$APPLICATIONS_DIR/swell.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Swell
Comment=Hold-to-talk dictation settings
Exec=env PYTHONPATH=$APP_DIR/src /usr/bin/python3 -m swell.control
Icon=audio-input-microphone
Categories=Utility;Accessibility;
Terminal=false
StartupWMClass=swell
EOF
rm -f "$APPLICATIONS_DIR/whisper-dictation.desktop"

if [ -e "$AUTOSTART_DIR/whisper-dictate.desktop" ]; then
  model="$(sed -n 's/^Exec=env DICTATE_MODEL=\([^ ]*\) .*/\1/p' "$AUTOSTART_DIR/whisper-dictate.desktop")"
  sed -e "s|^Name=.*|Name=Swell|" -e "s|^Exec=.*|Exec=env SWELL_MODEL=${model:-small.en} $BIN_DIR/swell|" \
    "$AUTOSTART_DIR/whisper-dictate.desktop" > "$AUTOSTART_DIR/swell.desktop"
  rm "$AUTOSTART_DIR/whisper-dictate.desktop"
  echo "Swell now starts at login instead of Whisper Dictation"
fi

echo "Installed. Open Swell from your app menu, or run: swell"
