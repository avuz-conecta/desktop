# Windows Uninstall Cleanup — Design

Date: 2026-06-30
Status: Approved
Scope: `installer.iss` (Inno Setup)

## Problem

Uninstalling Avuz Conecta on Windows leaves three defects:

1. **App not closed automatically.** The running tray app survives uninstall.
2. **Files remain in Program Files.** Leftover files after uninstall.
3. **Explorer sidebar pin survives.** The navigation-pane entry stays in the Explorer left bar.

## Root Cause

The shipping Windows installer is **Inno Setup** (`installer.iss` at repo root), built by `admin/win/build-installer.ps1` Step 5 via `ISCC.exe`. (The Craft NSIS blueprint, the CPack `cmake/modules/NSIS.template.in`, and the WiX MSI under `admin/win/msi/` all exist in the tree but are not the maintained shipping path.)

The installer runs in 32-bit mode (no `ArchitecturesInstallIn64BitMode`), so it installs to `C:\Program Files (x86)\Avuz Conecta`, even though the app is x64.

Diagnosed against `installer.iss`:

- **Issue 1.** `KillRunningProcesses()` exists but is called only from `PrepareToInstall` and only when the `cleandata` task is selected. It never runs at uninstall. Uninstall relies on `CloseApplications=yes` (Windows Restart Manager). The client is a tray app (`hide()` on close), so it does not respond to the Restart Manager shutdown and is not closed.
- **Issue 2.** Downstream of Issue 1. `[UninstallDelete] {app}` cannot delete the locked `avuzconecta.exe` and its loaded Qt DLLs while the process runs, so `{app}` is not emptied.
- **Issue 3.** `installer.iss` contains no code touching `HKCU\...\Explorer\Desktop\NameSpace` or the backing CLSID. The navigation-pane entries written at runtime by `NavigationPaneHelper::updateCloudStorageRegistry` (`src/gui/navigationpanehelper.cpp`) survive uninstall.

The installer registers no shell-extension DLLs (no `regsvr32` in `installer.iss` or `build-installer.ps1`). The client uses the Cloud Filter API (CfApi), whose shell integration is backed by the OS `cldapi.dll`, not by app DLLs loaded into `explorer.exe`. Therefore `{app}` is locked only by the running tray exe — killing it frees `{app}`; no explorer restart is required.

## Design

All changes are in `installer.iss`. No new toolchain, no change to `build-installer.ps1`. The installer stays 32-bit mode; the install directory is unchanged.

### 1. Close app at uninstall (fixes Issue 1, unblocks Issue 2)

Add an `InitializeUninstall()` event function (runs before any file removal) that calls a new `CloseAvuzProcesses()` helper. The helper is **graceful-then-force** and **Avuz-only**:

1. Graceful: `taskkill /IM avuzconecta.exe` and `/IM avuzconectadev.exe` (sends WM_CLOSE, no `/F`).
2. Poll: wait up to 10 s for exit, checking `ProcessRunning(...)` via `tasklist` every 500 ms.
3. Force fallback: for any exe still alive, `taskkill /F /IM ...`.
4. Settle: `Sleep(1000)` so the OS releases file handles.

The poll replaces a fixed sleep. The graceful step is best-effort: the tray app traps WM_CLOSE to minimize, so in practice the force fallback usually does the close — this is acceptable and intended.

The uninstall path does **not** kill `nextcloud.exe` (per the Avuz-only decision — never disturb a separately-installed Nextcloud client). The existing install-time `KillRunningProcesses()` (full list, including `nextcloud.exe`) is left unchanged and still runs only when the `cleandata` migration task is selected.

### 2. `{app}` removal (Issue 2)

No change. The existing `[UninstallDelete] Type: filesandordirs; Name: "{app}"` succeeds once the process is dead.

### 3. Navigation-pane CLSID cleanup (fixes Issue 3)

Add a `CurUninstallStepChanged(CurUninstallStep)` procedure. On `usUninstall`, call `RemoveNavigationPaneEntries()`, which snapshots the subkeys of:

`HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace`

For each `{clsid}` subkey, read its `ApplicationName` value. If it equals `Avuz Conecta` or `Avuz ConectaDev`, delete:

- `...\Desktop\NameSpace\{clsid}` — removes the visible sidebar pin (this key is **not** WOW6432 redirected; a plain delete works) — via Inno `RegDeleteKeyIncludingSubkeys`.
- value `{clsid}` under `...\Explorer\HideDesktopIcons\NewStartPanel` — via Inno `RegDeleteValue`.
- backing CLSID in **both** registry views — via `reg.exe`:
  - `reg delete "HKCU\Software\Classes\CLSID\{clsid}" /reg:64 /f`
  - `reg delete "HKCU\Software\Classes\CLSID\{clsid}" /reg:32 /f`

`reg.exe /reg:64` reaches the native 64-bit `Software\Classes\CLSID` view that the x64 client wrote, regardless of the 32-bit installer's bitness; `/reg:32` covers the `Wow6432Node\CLSID` copy the client also wrote. This avoids flipping the installer to 64-bit mode (which would relocate the install dir and orphan the existing `(x86)` install with a duplicate Add/Remove Programs entry, because Inno's upgrade record is keyed per registry view).

### Decisions

- **Stay 32-bit installer / install dir unchanged.** Use `reg.exe /reg:64` for the one redirected key rather than `ArchitecturesInstallIn64BitMode=x64`, to avoid relocation and duplicate-uninstall-entry migration.
- **Uninstall kill scope: Avuz only.** `avuzconecta.exe`, `avuzconectadev.exe`. Never `nextcloud.exe` at uninstall.
- **Close graceful-then-force**, with a poll for exit before the force fallback.
- **Nav-pane match: Avuz names only.** `Avuz Conecta` or `Avuz ConectaDev`. Never `Nextcloud`.
- **Registry scope: HKCU only.** Correct when the user is a local admin (common single-user Windows). Caveat: if the uninstaller is elevated by a different admin account, `HKCU` resolves to that account's hive and the logged-in user's entries are missed. Accepted; out of scope to scan all hives.

## Non-Goals (YAGNI)

- No `explorer.exe` restart — unnecessary, no app DLLs locked in explorer.
- No `SOFTWARE\...\Explorer\SyncRootManager` / CfApi sync-root cleanup — separate concern, owned by the app's `unregisterSyncRoot`.
- No additional `{userappdata}` config wipe beyond the existing `[UninstallDelete]` and `cleandata` task.

## Known Gaps (accepted)

- **Pre-rebrand survivors.** A user who ran an early Avuz build still branded `Nextcloud` has nav entries with `ApplicationName = Nextcloud`. The Avuz-only match does not remove them, so such a stale pin can survive. Accepted to avoid clobbering a coexisting real Nextcloud client.
- **Cross-account elevation.** See registry-scope caveat above.

## Verification

No test harness exists for `.iss` scripts. Verification is a manual Windows checklist.

Primary (app running at uninstall):

1. Install Avuz Conecta. Launch it. Add/sync a folder so the sidebar pin appears in Explorer.
2. Confirm in `regedit`: under `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace` a `{clsid}` has `ApplicationName = Avuz Conecta`.
3. Uninstall while the app runs.
4. Assert: (a) app process gone; (b) the install dir (`C:\Program Files (x86)\Avuz Conecta`) gone; (c) sidebar pin gone; (d) all gone in `regedit`: `Desktop\NameSpace\{clsid}`; `Software\Classes\CLSID\{clsid}` in both 64-bit and 32-bit (`Wow6432Node`) views; the `{clsid}` value under `HideDesktopIcons\NewStartPanel`.

Regression (app already closed at uninstall):

5. Install, launch, close the app, uninstall. Assert (a)–(d) above still hold; no errors.
