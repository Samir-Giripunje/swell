<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Wisper icon">
</p>

<h1 align="center">Wisper</h1>

<p align="center">
  <a href="../../releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/Samir-Giripunje/wisper-for-mac?include_prereleases"></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-blue">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-arm64-black">
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/license-MIT-green"></a>
</p>

Hold **right ⌘**, speak, let go — your words are typed wherever your cursor is.

A free, open-source, fully local take on voice dictation apps like [Wispr Flow](https://wisprflow.ai).

Wisper runs OpenAI's Whisper speech recognition **entirely on your Mac** (Neural Engine, via [WhisperKit](https://github.com/argmaxinc/WhisperKit)). No cloud, no account, nothing leaves your machine.

## Features

- **Hold-to-talk anywhere** — right ⌘ (or right ⌥) in any app; text is pasted at the cursor and your clipboard is restored.
- **Animated on-screen pill** while you speak and while it transcribes.
- **Choose your model** — download, switch and delete Whisper models in the app.
- **Lives in the menu bar** — in the Dock and ⌘Tab only while its window is open; quit from the menu bar icon.
- **Launch at login** (starts silently) and **load model at start** toggles.
- **Battery friendly** — ~0% CPU when idle; the microphone is only on while you hold the key.

## Install

1. Download the latest **Wisper-x.y.z.dmg** from [Releases](../../releases/latest).
2. Open it and drag **Wisper** into **Applications**.
3. Open Wisper. Because it isn't notarized by Apple, macOS blocks the first launch — go to **System Settings → Privacy & Security** and click **Open Anyway**.
   Or from Terminal: `xattr -dr com.apple.quarantine /Applications/Wisper.app`
4. Allow **Microphone** and **Accessibility** (needed to detect the hotkey and paste).

Requires an **Apple Silicon** Mac on **macOS 14 Sonoma or later**.

## Models

| Model | Download | Notes |
|---|---|---|
| Tiny | 77 MB | Fastest, good for short notes |
| Base | 147 MB | Better accuracy, still instant (default) |
| Small | 217 MB | Best accuracy for longer dictation |

Models download from [argmaxinc/whisperkit-coreml](https://huggingface.co/argmaxinc/whisperkit-coreml) into `~/Library/Application Support/Whisper/Models`. Switching keeps the current model working until the new one is ready.

## Troubleshooting

| Problem | Fix |
|---|---|
| Nothing is pasted | Accessibility is off or stale: in **Privacy & Security → Accessibility**, remove Wisper with **−**, add it again with **+**. Your text is on the clipboard meanwhile (⌘V). |
| Empty or cut-off text with AirPods | Bluetooth mics drop the first ~0.75 s. Pick the built-in microphone in Wisper → Dictation → Microphone (the default). |
| Popup asks for Accessibility every launch | Same as "Nothing is pasted" — remove and re-add the entry. |

Logs: `/usr/bin/log show --last 10m --predicate 'subsystem == "com.samirgiripunje.whisper"'`

## Build from source

```bash
git clone https://github.com/Samir-Giripunje/wisper-for-mac.git
cd wisper-for-mac
./build.sh            # builds and installs /Applications/Wisper.app
```

Requires Xcode 16+. To package a DMG: `brew install create-dmg`, then `./build.sh --no-install && VERSION=0.0.1 scripts/make_dmg.sh`.

End-to-end self-test (opens TextEdit, dictates a spoken phrase, reads it back, then quits):

```bash
open -a /Applications/Wisper.app --args --self-test
```

## Releasing

Push a tag; GitHub Actions builds, signs, packages the DMG and publishes the release.

```bash
git tag v0.0.2 && git push origin v0.0.2
```

## Credits

- **[Wispr Flow](https://wisprflow.ai)** — the hold-to-talk dictation experience and on-screen pill that inspired Wisper. Wisper is an independent project and is not affiliated with or endorsed by Wispr.
- **[WhisperKit](https://github.com/argmaxinc/WhisperKit)** by Argmax (MIT) — on-device Whisper inference on the Neural Engine.
- **[Whisper](https://github.com/openai/whisper)** by OpenAI (MIT) — the speech recognition models.

## License

[MIT](LICENSE)
