# Swell protocol

How one Swell app transcribes speech on another machine. A **host** (today: Swell for Linux with a GPU) serves it; a **client** (today: Swell for Mac) calls it. Everything that crosses the wire is described here, in [`schema.json`](schema.json), and by the examples in [`fixtures/`](fixtures). Both apps test against those fixtures, so change all three together.

## Transport

- Plain HTTP on port `8765`. Hosts only answer clients on the Tailscale network (`100.64.0.0/10`) or loopback, so the tailnet provides encryption and reachability.
- Every request carries `Authorization: Bearer <token>`. The host generates the token once and keeps it in its config directory.
- Every path is versioned under `/v1`. A breaking change adds `/v2` and bumps `protocol` in the health response.

## `GET /v1/health`

Cheap; clients call it to test a machine and to decide, while you are still speaking, whether to fall back to on-device transcription.

```json
{"protocol": 1, "name": "samir-Legion-5Pro-16ACH6H", "model": "large-v3-turbo", "device": "cuda", "cleanup": "medium"}
```

| Field | Meaning |
|---|---|
| `protocol` | Protocol version, `1`. |
| `name` | The host's machine name, shown in client settings. |
| `model` | Whisper model the host transcribes with. |
| `device` | `cuda` (GPU) or `cpu`. |
| `cleanup` | The host's rephrasing level when a request doesn't name one: `off`, `low`, `medium` or `high`. |

## `POST /v1/transcribe`

Body: a mono 16-bit PCM WAV file (`Content-Type: audio/wav`), at most 50 MB. Any sample rate; the host resamples.

Query:

- `language` is `auto` (default) or a Whisper language code such as `en`. English-only models always use `en`.
- `cleanup` is how much the host rephrases the transcript with its language model. Omit it to use the host's level from `/v1/health`.

| `cleanup` | What changes |
|---|---|
| `off` | Nothing: Whisper's text as is. |
| `low` | Filler sounds (um, uh, er, hmm) removed. Every other word stays as spoken; no language model. |
| `medium` | Also false starts, repeated phrases and filler phrases (you know, basically). |
| `high` | Rewritten into clear, well-formed sentences, with grammar fixed and run-ons split. Never adds content. |

The host keeps the original transcript when its model fails, or strays too far from what was said.

```json
{"text": "Can you check why the Docker build is failing on stage?"}
```

`text` is final: transcribed, then rephrased at the requested level. It is empty when the audio held no speech.

## Errors

Any non-2xx response has this body:

```json
{"error": {"code": "unauthorized", "message": "Wrong or missing token."}}
```

| Status | `code` | When |
|---|---|---|
| 400 | `bad_request` | Body missing or not decodable audio, or an unknown `language` or `cleanup`. |
| 401 | `unauthorized` | Token missing or wrong. |
| 403 | `forbidden` | Caller is not on the tailnet or loopback. |
| 404 | `not_found` | Unknown path. |
| 413 | `too_large` | Body over 50 MB. |
| 500 | `internal` | Transcription failed on the host. |

## Pairing link

A host hands its address and token to a client as one link, so nothing is typed by hand:

```
swell://pair?name=<machine name>&url=<base URL>&token=<token>
```

All three parameters are required and URL-encoded. `url` is `http` or `https` with no path, for example `http://100.114.142.113:8765`. Treat the link like a password.
