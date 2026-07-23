# ccsm-gc2cc

One-line Windows installer for:

- `@bakapiano/ccsm`
- `gc2cc` with both `ccp` and `cxp`
- replacement of ccsm's built-in Claude/Codex entries with `ccp`/`cxp`
- `ccp` as the ccsm default CLI (`-DefaultCli cxp` is also supported)
- first-run interactive `ccp config` / `cxp config` when their config files do
  not exist yet
- explicit use of the global npm source for every npm package install

## Install

Run in PowerShell:

```powershell
irm https://bakapiano.github.io/ccsm-gc2cc/install.ps1 | iex
```

The script delegates the proxy/service setup to the canonical gc2cc installer:

```powershell
https://bakapiano.github.io/gc2cc/install.ps1 -InstallClis ccp,cxp -NonInteractive
```

Then it runs missing first-run configs, installs ccsm through npm, replaces
ccsm's built-in Claude/Codex commands, and sets the default CLI:

```powershell
ccp config   # only when ~/.local/share/gc2cc/ccp.json is missing
cxp config   # only when ~/.local/share/gc2cc/cxp.json is missing
# ccsm built-in "Claude Code" -> %LOCALAPPDATA%\gc2cc\bin\ccp.cmd
# ccsm built-in "OpenAI Codex" -> %LOCALAPPDATA%\gc2cc\bin\cxp.cmd
# defaultCliId -> claude (ccp)
```

If ccsm is already running, the installer updates it through ccsm's own
`/api/config` endpoint. If it is offline, the installer edits
`~/.ccsm/config.json` directly. Existing custom CLIs are preserved, while old
duplicate `ccp` / `cxp` entries are removed. The installer uses installed
absolute paths, so it does not rely on the current shell already having
refreshed PATH after npm/gc2cc installation.

The installer reads `npm config get registry --location=global`, prints the
resolved source, passes it into the gc2cc installer, and explicitly supplies it
to every npm package install via `--registry`. On this machine that resolves to
the configured corporate npm source rather than npmjs.org. Use `-NpmRegistry`
only when running the downloaded script with arguments and intentionally
overriding the global setting.

## Notes

- Windows only.
- gc2cc may trigger UAC because it installs a Windows service.
- First install may ask for GitHub Copilot device-code auth.
- Re-running the one-liner is intended to be upgrade-safe.
