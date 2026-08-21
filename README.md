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

**Security note:** the API key is stored in plaintext in
`~/.config/omarchy/shell.json`, like every other inline plugin setting in
Omarchy — there's no secret-storage mechanism available to third-party
plugins. Use a key scoped to this purpose if OctoPrint's user/key management
supports it, same caution as any other locally-stored API key.

## Install

```sh
omarchy plugin add https://github.com/taufderl/omarchy.taufderl.octoprint.git --enable
```

## Configure

Settings are edited through Setup → Plugins, or via the ⚙ in the panel
(which additionally lets you type the API key without it staying visible on
screen), or directly in `~/.config/omarchy/shell.json` on the widget's
`bar.layout` entry:

| Setting | Description | Default |
|---|---|---|
| `host` | OctoPrint URL, e.g. `http://octopi.local` (no trailing slash) | *(required)* |
| `apiKey` | OctoPrint API key | *(required)* |
| `pollSeconds` | How often to re-poll (keep ≥ 5 — this is your own LAN device, not a rate-limited public API) | `15` |

Move it around the bar with:

```sh
omarchy bar move taufderl.octoprint --section right
```

## Remove

```sh
omarchy plugin remove taufderl.octoprint
```
