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
the wrappers update it through ccsm's own `/api/config` endpoint rather than
stopping it or editing the file behind its back. The installer invokes the
wrappers and `ccsm.cmd` by their installed paths, so it does not rely on the
current shell already having refreshed PATH after npm/gc2cc installation.

## Notes

- Windows only.
- gc2cc may trigger UAC because it installs a Windows service.
- First install may ask for GitHub Copilot device-code auth.
- Re-running the one-liner is intended to be upgrade-safe.
