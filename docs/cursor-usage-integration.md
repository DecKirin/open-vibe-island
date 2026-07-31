# Cursor Usage Integration

Investigated 2026-07-31 in worktree `feat+cursor-usage-badge` on branch `feat/cursor-usage-badge`.

## Question

How does Open Island show Cursor's usage percentage in the badge, alongside Claude and Codex, without asking the user to connect or sign in to anything?

## Short Answer

It doesn't talk to Cursor's public API at all. It reads Cursor IDE's **own local session** (the same token Cursor IDE itself is already using) straight off disk, and calls Cursor's **internal** dashboard API with it — the exact call Cursor IDE's own UI makes to render its own usage screen. As long as Cursor IDE is installed and logged in, there is nothing for the user to do; if it isn't, the badge silently doesn't show a Cursor chip, the same way Claude/Codex silently don't show a chip when their own local sources are absent.

## Why not the public API?

Several things look like they should work and don't:

- **`cursor-agent` CLI** — no usage/quota data anywhere: not in `--help`, not in any subcommand output, not in its hook payloads, not in any local file it writes.
- **Cursor's Team Analytics Admin API** (`docs.cursor.com/account/teams/admin-api`) — real, but Enterprise-only, team-scoped, needs a manually-generated Admin API key, and reports spend/counts — not a personal usage percentage.
- **`api2.cursor.sh/auth/usage`** — a real, working legacy endpoint (still reachable with a plain OAuth-obtained token — see [`kenryu42/pi-cursor-oauth`](https://github.com/kenryu42/pi-cursor-oauth) for a clean reference implementation of Cursor's `loginDeepControl` + poll login flow). But it returns the *old* per-model request-quota shape, and every field is `null` on any account using Cursor's current usage-based pricing — confirmed live against a real Team-plan account.
- **`cursor.com/api/usage-summary`** — this is the endpoint that actually has the real dollar-based numbers (confirmed by reading it out of a reference product's local cache file). But it's gated by a **website session cookie** (`WorkosCursorSessionToken`), a completely different credential from anything obtainable via the flows above. Every attempt to reach it — Cursor IDE's local JWT as a cookie, as a bearer token, a freshly-minted OAuth token from the `loginDeepControl` flow — returned `{"error":"not_authenticated"}`.

## The actual mechanism

Found by intercepting a reference product's real traffic with `mitmproxy` (after clearing its cached credentials to force a genuine fresh capture) and independently reproducing the winning request from scratch afterward, with no reference product involved, to confirm it wasn't a fluke.

### 1. The credential is already on disk — no login needed

Cursor IDE caches its own session token locally:

```
~/Library/Application Support/Cursor/User/globalStorage/state.vscdb
```

a SQLite DB with a plain `ItemTable(key, value)` schema (standard VS Code global-storage shape). The key `cursorAuth/accessToken` holds a JWT:

```json
{
  "sub": "github|user_...",
  "iss": "https://authentication.cursor.sh",
  "aud": "https://cursor.com",
  "type": "session",
  "scope": "openid profile email offline_access"
}
```

Verified byte-for-byte identical between what's sitting in `state.vscdb` right now and the `Authorization: Bearer` header the reference product's captured traffic actually sent. Cursor IDE put it there the moment you logged in; nothing else needs to write or manage it.

### 2. The right endpoint is the *internal* dashboard API, not the public one

```
POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage
```

This is a [Connect RPC](https://connectrpc.com/) (protobuf-over-HTTP) endpoint — the same API surface Cursor IDE's own UI calls to render its own usage screen. It takes an empty body and returns the real, current, dollar-based usage data — the numbers the legacy REST endpoint stopped returning.

Required headers, captured verbatim from real traffic:

| Header | Value | Notes |
|---|---|---|
| `Authorization` | `Bearer <cursorAuth/accessToken>` | The real auth — everything else here is just making the request *look* like it came from the IDE. |
| `connect-protocol-version` | `1` | Connect RPC framing. |
| `content-type` | `application/proto` | |
| `x-cursor-checksum` | see below | Looks like auth, isn't. |
| `x-cursor-client-type` | `ide` | |
| `x-cursor-team-id` | optional | From `authInfo.teamId` in `~/.cursor/cli-config.json` if present. |
| `x-session-id`, `x-client-key` | random | Cursor IDE generates these per-session; a random UUID / random hex string is accepted fine. |

### 3. `x-cursor-checksum` is not a secret

It looks like an auth mechanism. It isn't one — it's the **"Jyh cipher"**, an intentionally weak, hardcoded-key XOR-with-feedback obfuscation of a coarse (~16-minute-resolution) timestamp, concatenated with the machine's local telemetry IDs (`telemetry.machineId` / `telemetry.macMachineId` from `storage.json`, same directory as `state.vscdb`). This was independently reverse-engineered and published by someone else entirely — see [`eisbaw/cursor_api_demo`](https://github.com/eisbaw/cursor_api_demo)'s `TASK-18-jyh-cipher.md` for the full writeup, including the explicit finding that **the server only checks the header is present and well-formed, not that it's cryptographically correct** — it's fingerprinting/anti-replay theater, not authentication. Open Island's implementation (`CursorChecksum` in `Sources/OpenIslandCore/CursorUsage.swift`) is a direct Swift port of the documented algorithm.

### 4. The response is parsed as text, not structured protobuf

There's no published `.proto` schema for `GetCurrentPeriodUsage`. Rather than reverse-engineer field numbers and wire types, Open Island regex-matches the human-readable summary sentences Cursor embeds directly in the encoded response — the same strings Cursor IDE's own UI renders verbatim:

```
"You've used 48% of your included total usage"
"You've used 0% of your included API usage"
```

This is the deliberately more fragile of the two possible approaches (a wording change would break it; proper field-based parsing would survive one), traded for needing zero protobuf tooling to maintain. If the strings stop matching, `CursorUsageResponseParser` degrades to an empty snapshot — no chip shown, not a crash, not a stale number.

## Verification

Confirmed three separate ways before landing:

1. **Live against a reference product's real traffic** — `mitmproxy` capture, real request/response pairs, human-readable percentages visible directly in the captured bytes.
2. **Independently, from scratch** — a bare `curl` request built with nothing but the local `state.vscdb`/`storage.json` files and the documented checksum algorithm, no reference product involved, returned the same real data.
3. **In the actual Swift implementation** — `CursorUsageLoader.load()` run directly against this machine's real Cursor install returns the same numbers the manual tests did.

## Implementation

- `Sources/OpenIslandCore/CursorUsage.swift` — `CursorLocalSession` (reads the three local files), `CursorChecksum` (the Jyh cipher), `CursorUsageLoader` (orchestrates the HTTP call), `CursorUsageResponseParser` (regex extraction). Extensive doc comments at the top of the file cover the same ground as this doc, closer to the code.
- Wired into the existing Claude/Codex usage-badge pattern in `HookInstallationCoordinator.swift` / `AppModel.swift` — a `showCursorUsage` toggle (matching Codex's, since like Codex this needs no install/connect step to serve as an implicit opt-in) gates a 300s polling loop calling `CursorUsageLoader.load()`.
- `Tests/OpenIslandCoreTests/CursorUsageTests.swift` — checksum shape, response parsing (including the "no match → empty snapshot" path), and `CursorLocalSession` credential reading against fixture SQLite/JSON files, plus `CursorUsageLoader` behavior with a mocked transport (no local session → zero network calls; 401 → nil, not an error).

## Caveats for future maintainers

- This is an internal, undocumented Cursor API. It could change or start requiring something this integration doesn't send (Cursor's own IDE evolves independently of this project). Every failure mode here — missing local files, non-200 response, unparseable body — degrades to "no data shown," never a crash or a stale/wrong number.
- The checksum's second segment (derived from `telemetry.macMachineId`) doesn't need to be byte-identical to what a real Cursor IDE instance would compute — per the published security analysis, the server doesn't validate it, only checks it's present and shaped correctly. Don't spend time trying to make it "more correct."
- If Cursor ever ships a real personal-usage REST/GraphQL API, prefer switching to it — this integration exists only because nothing better was available at the time.
