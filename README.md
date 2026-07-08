# ccsm-gc2cc

One-line Windows installer for:

- `@bakapiano/ccsm`
- `gc2cc` with both `ccp` and `cxp`
- ccsm CLI registrations for `ccp` and `cxp`

## Install

Run in PowerShell:

```powershell
irm https://bakapiano.github.io/ccsm-gc2cc/install.ps1 | iex
```

The script delegates the proxy/service setup to the canonical gc2cc installer:

```powershell
https://bakapiano.github.io/gc2cc/install.ps1 -InstallClis ccp,cxp -NonInteractive
```

Then it installs ccsm through npm and runs:

```powershell
ccp ccsm
cxp ccsm
```

That writes the wrapper entries into `~/.ccsm/config.json`, so ccsm can launch
Claude Code through `ccp` and Codex through `cxp`. If ccsm is already running,
the installer stops it before writing the CLI config and starts it again after,
so the running backend cannot save an older config over the new entries.

## Notes

- Windows only.
- gc2cc may trigger UAC because it installs a Windows service.
- First install may ask for GitHub Copilot device-code auth.
- Re-running the one-liner is intended to be upgrade-safe.
