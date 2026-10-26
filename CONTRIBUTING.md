# Contributing

## Ground rules

* **One file to run.** `New-QuickLinuxVM.ps1` must remain a single, self-contained script that people
  can download with `irm` and run. That means no modules and no extra files at runtime.
* **PowerShell 5.1 compatible.** Don't use ternaries, `??`, `::new()`-only APIs or PowerShell 7-only
  cmdlets. The script must be pure ASCII, because Windows PowerShell reads BOM-less files as ANSI.
* **Safe by default.** Every state change goes through `Invoke-QdStep`, so `-WhatIf` and `-Confirm`
  keep working. Register an undo action (`Register-QdUndo -Data @{...} -Script { param($d) ... }`)
  for everything a run creates.
* **No secrets.** Passwords only arrive as SecureString or PSCredential, and only crypt hashes reach
  the guest.
* **Supported guests:** Ubuntu, Fedora and NixOS only.
* **Prove it, don't assume it.** A new runtime dependency (tool, template, URL) must be *exercised* by
  `-Check`/preflight, not just located. "The command exists" is not enough: run it on a probe input.

## Adding a menu entry

Append to `$script:QdMenu` (never reorder it, so menu numbers stay stable). Then add a resolver that
returns the image URL, the checksum file URL and a cache file name. Finally, add the id to the
`-Distro` ValidateSet and to the tests.

## Checks

```powershell
./tools/Invoke-StaticAnalysis.ps1         # analyzer + offline Pester
./tools/Invoke-StaticAnalysis.ps1 -Live   # + live mirror resolution
```

Changes that touch Hyper-V or cluster code should say in the pull request which Windows Server
version and topology (standalone or cluster) you tested on.
