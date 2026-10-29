# Swell

Swell is hold-to-talk dictation: hold a key, speak, let go, and the words are pasted where the cursor is. It ships for macOS (Swift) and Linux (Python), and one Swell can transcribe for another over Tailscale.

## What we never compromise on

1. **Your machines only.** Speech is transcribed on the user's own Mac or PC. No cloud speech service, no account, no telemetry. Writer mode on Linux calls OpenAI only because the user asks for it by holding that key.
2. **Instant.** Release the key and text appears in about a second. Measure before and after anything on the dictation path: audio capture, encoding, the network hop, model calls.
3. **Dictation always works.** A sleeping or unreachable machine falls back to on-device transcription; it never leaves the user with nothing. Every failure says what to do next.
4. **Quiet.** ~0% CPU when idle. The microphone is on only while the key is held.

## Glossary

- **host** means a Swell that transcribes for others (today Swell for Linux, with **Serve other machines** on).
- **client** means a Swell that sends audio to a host (today Swell for Mac).
- **engine** means where a client transcribes: **on-device**, or a **machine** (a paired host).
- **pairing link** means the `swell://pair?…` link carrying a host's name, URL and token.

## Layout

| Path | What |
|---|---|
| `apps/macos` | Swell for Mac. SwiftPM executable `WhisperApp`; `build.sh` bundles and signs `Swell.app`. |
| `apps/linux` | Swell for Linux. uv project; `swell.main` is the daemon, `swell.control` the GTK settings window. |
| `packages/protocol` | The contract between host and client: `README.md` (spec), `schema.json`, `fixtures/`. |

## Hit every surface

The most common defect is a change that works where you tried it and is missing everywhere else. Before calling work done, say which of these applied:

- **Contracts.** Anything crossing the wire is defined in `packages/protocol`. Change the spec, schema and fixtures together; both apps test against the fixtures.
- **Both apps.** A host change needs a client decision and the reverse, even if the decision is "not supported there".
- **Entry points.** Mac settings live in the window (`SettingsView`) and the menu bar (`StatusItemController`); Linux settings live in the control window. Check both on the Mac.
- **Reverse states.** If you add a way in, add the way out and the way to see it. Pairing needs remove. Serve needs stop.
- **Failure modes.** Host asleep, Tailscale off, wrong token, model still loading, permissions missing. Each one shows a message that tells the user what to do.
- **Docs.** Check whether the change makes `README.md` or `packages/protocol/README.md` wrong.

## Code

- Prefer the smallest change that makes the behavior unsurprising. Do not add a layer, protocol or dependency for one caller.
- Match the surrounding code: comments explain why, not what; names are full words.
- Swift: `@MainActor` for UI state, actors for engines, no force unwraps outside tests. Secrets go in files only the user can read (0600), never `UserDefaults`. Not the Keychain: builds have no Apple team ID, so it would ask for the login password after every update.
- Python: the modules the control window imports (`settings`, `pairing`, `cleanup`, `server`) are standard library only, because it runs on the system Python.

## Verifying

- Linux: `cd apps/linux && uv run --only-group dev ruff check . && uv run --only-group dev ruff format --check . && uv run --only-group dev pytest`
- Mac: `cd apps/macos && swift build && swift test`. `build.sh` installs into `/Applications`, so run it only when asked.
- Test behavior that can break: protocol parsing and errors, auth, pairing links, engine selection and fallback, settings migration. Skip tests for what the type system already guarantees, copy text and view layout.
- Extend an existing test table before adding a new test. No sleeps or timeouts to make a test pass.
- A protocol bug gets a failing test first, then the fix.

## The ways to hurt yourself

1. **The live install.** The developer dictates with these apps all day. Don't kill Swell by name; on Linux, stop the PID in `~/.cache/swell/lock`. Don't run `build.sh` without being asked, because it replaces `/Applications/Swell.app`.
2. **Leaking tokens.** Never print, log or commit a host token or pairing link. Pass it through a private file.
3. **Resetting permissions.** Builds signed ad hoc lose macOS Microphone and Accessibility grants. `build.sh` signs with the stable "Whisper Local Signing" certificate when it exists; keep it that way.
