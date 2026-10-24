# Working on SubPacer

How to build, release and debug it. What it does for its users is in the [README](../README.md); connecting it to a
proxy in [PROXY.md](PROXY.md).

## Build from source

Needs Swift 6.2 (Xcode 26 or its command line tools).

```sh
git clone https://github.com/kcazin/SubPacer.git
cd SubPacer
./build.sh                    # builds for this Mac, signs ad hoc, installs ~/Applications/SubPacer.app
open ~/Applications/SubPacer.app
```

Builds from `./build.sh` are versioned `0.0.0-dev` and never update themselves.

## Releases

`./build.sh --release 0.1.0` builds the universal app (Apple silicon and Intel) and `dist/SubPacer-0.1.0.zip`, and
prints its SHA-256. Publish it as the asset of a GitHub release tagged `v0.1.0`: the updater looks for
`SubPacer-<version>.zip` on the latest release and checks it against the digest GitHub reports.

## Demo accounts

```sh
SUBPACER_DEMO=1 ~/Applications/SubPacer.app/Contents/MacOS/SubPacer
```

runs on made-up accounts (two Claude, one Codex) with a week of synthetic history. The forecasting runs on it
unchanged; nothing is saved.

## Debug snapshots

```sh
SUBPACER_SNAPSHOT=/tmp/panel.png ~/Applications/SubPacer.app/Contents/MacOS/SubPacer
```

renders the panel once to a PNG and prints the parsed quota (including account emails) to stdout. Add
`SUBPACER_SETTINGS=1` for the settings view, `SUBPACER_APPEARANCE=dark|light`, `SUBPACER_MENUBAR=/tmp/menubar.png` to
also save the menu bar label, or `SUBPACER_DEMO=1` for the demo accounts. Settings can be overridden for the run as
arguments, for example `-menuBarStyle gauge -show.tonight YES`. Run it from the app bundle: macOS grants network
access per app, so a bare `.build/debug/SubPacer` may not reach a proxy on your network.

The README's images are made this way, from the demo accounts: `python3 docs/make-images.py` (needs Pillow) after
`./build.sh` writes them to `docs/images/`.

## Adding a provider

Implement `QuotaProvider` in `Providers.swift` (the request URL and headers, using `$TOKEN$` where the proxy should
insert the account's token, plus a parser) and add it to `QuotaProviders.all`.
