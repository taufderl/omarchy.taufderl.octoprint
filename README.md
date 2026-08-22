# OctoPrint

A bar widget for the Omarchy Quattro shell that shows live 3D print status —
job progress, time remaining, and tool/bed temperatures — from a self-hosted
[OctoPrint](https://octoprint.org/) instance.

Icon-only in the bar when idle; shows the completion percentage while a
print is actually running. Click for the full panel: state, file name,
progress bar, time remaining, and temperatures.

The bar icon is 🐙 — a nod to OctoPrint's own "Tentacle logo" branding —
kept fixed rather than swapped per print state; status is conveyed through
color and the completion percentage instead. State-specific icons (⚙
printing, ✅ operational, ⏸ paused, ⚠ error, 🔌 disconnected, 🛑 cancelling)
show inline
next to the state text inside the panel instead.

## Data source

This plugin polls your own OctoPrint instance directly — no third-party
service involved. Two REST endpoints, once per poll:

```
GET /api/job
GET /api/printer
```

Authenticated with a single `X-Api-Key` header. Generate a key in OctoPrint
itself under **Settings → API**. No CORS configuration is needed on the
OctoPrint side.

`/api/printer` returns HTTP 409 when no printer is connected — that's
OctoPrint's normal, documented behavior for "server up, printer not
attached/powered," not an error. The panel just shows less data (state only,
no temperatures) rather than an error banner in that case.

**Security note:** the host and API key are stored in plaintext at
`~/.local/state/omarchy/taufderl.octoprint/settings.json`, `chmod 600`'d after
every write (readable only by your user) — a dedicated file, not
`~/.config/omarchy/shell.json`, so they don't end up mixed in with the rest
of your bar config if you ever share or back that up. Omarchy still exposes
no dedicated secret-storage mechanism to third-party plugins beyond that, so
use a key scoped to this purpose if OctoPrint's user/key management supports
it, same caution as any other locally-stored API key. (Upgrading from an
older version that stored these in `shell.json`: they're migrated
automatically on first load and removed from `shell.json` once moved.) The
settings editor (⚙ in the panel) repeats this warning inline, along with a
warning whenever the configured URL is plain `http://` rather than `https://`
— the API key is sent in that request's headers on every poll, so plain HTTP
means anyone on that network segment can read it. Configured host values are
validated as a bare `http://`/`https://` origin (no embedded credentials,
path, or query string) before use.

## Install

```sh
omarchy plugin add https://github.com/taufderl/omarchy.taufderl.octoprint.git --enable
```

## Configure

`host` and `apiKey` are set through the ⚙ in the panel only (which lets you
type the API key without it staying visible on screen) — they're kept out of
`~/.config/omarchy/shell.json` and Setup → Plugins' generic editor entirely,
since they're credentials rather than ordinary bar-layout settings; see the
Security note above for where they actually live.

`pollSeconds` is an ordinary setting, editable through Setup → Plugins or
directly in `~/.config/omarchy/shell.json` on the widget's `bar.layout`
entry:

| Setting | Description | Default |
|---|---|---|
| `host` | OctoPrint URL, e.g. `http://octopi.local` (no trailing slash) — set via the panel's ⚙ | *(required)* |
| `apiKey` | OctoPrint API key — set via the panel's ⚙ | *(required)* |
| `pollSeconds` | How often to re-poll (minimum 10, comfortably above the request timeout) | `15` |

Move it around the bar with:

```sh
omarchy bar move taufderl.octoprint --section right
```

## Remove

```sh
omarchy plugin remove taufderl.octoprint
```
