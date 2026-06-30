# Windows Uninstall Cleanup — Design

Date: 2026-06-30
Status: Approved
Scope: `installer.iss` (Inno Setup)

## Problem

Uninstalling Avuz Conecta on Windows leaves three defects:

1. **App not closed automatically.** The running tray app survives uninstall.
2. **Files remain in `C:\Program Files\Avuz Conecta`.** Leftover files after uninstall.
3. **Explorer sidebar pin survives.** The navigation-pane entry stays in the Explorer left bar.

## Root Cause

The shipping Windows installer is **Inno Setup** (`installer.iss` at repo root), built by `admin/win/build-installer.ps1` Step 5 via `ISCC.exe`. (The Craft NSIS blueprint, the CPack `cmake/modules/NSIS.template.in`, and the WiX MSI under `admin/win/msi/` all exist in the tree but are not the maintained shipping path.)

Diagnosed against `installer.iss`:

- **Issue 1.** `KillRunningProcesses()` exists but is called only from `PrepareToInstall` and only when the `cleandata` task is selected. It never runs at uninstall. Uninstall relies on `CloseApplications=yes` (Windows Restart Manager). A Qt tray app commonly ignores the Restart Manager shutdown message, so it is not closed.
- **Issue 2.** Downstream of Issue 1. `[UninstallDelete] {app}` cannot delete the locked `avuzconecta.exe` and its loaded Qt DLLs while the process runs, so `{app}` is not emptied.
- **Issue 3.** `installer.iss` contains no code touching `HKCU\...\Explorer\Desktop\NameSpace` or the backing CLSID. The navigation-pane entries written at runtime by `NavigationPaneHelper::updateCloudStorageRegistry` (`src/gui/navigationpanehelper.cpp`) survive uninstall.

The installer registers no shell-extension DLLs (no `regsvr32` in `installer.iss` or `build-installer.ps1`). The client uses the Cloud Filter API (CfApi), whose shell integration is backed by the OS `cldapi.dll`, not by app DLLs loaded into `explorer.exe`. Therefore `{app}` is locked only by the running tray exe — killing it frees `{app}`; no explorer restart is required.

## Design

All changes are in `installer.iss`. No toolchain change.

### 1. Force-close app at uninstall (fixes Issue 1, unblocks Issue 2)

Add an `InitializeUninstall()` function. It runs before any file removal. It force-kills the app processes, then waits briefly:

- `taskkill /F /IM avuzconecta.exe`
- `taskkill /F /IM AvuzConecta.exe`
- `taskkill /F /IM avuzconectadev.exe`
- `Sleep(1500)`
- return `True`

This reuses the existing `KillRunningProcesses` shape already in the file. Runs on every uninstall, not only when `cleandata` is selected.

### 2. `{app}` removal (Issue 2)

No change. The existing `[UninstallDelete] Type: filesandordirs; Name: "{app}"` succeeds once the process is dead.

### 3. Navigation-pane CLSID cleanup (fixes Issue 3)

Add a `CurUninstallStepChanged(CurUninstallStep)` procedure. On `usUninstall`, enumerate the subkeys of:

`HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace`

For each `{clsid}` subkey, read its `ApplicationName` value. If it equals `Avuz Conecta` or `Avuz ConectaDev`, delete:

- `Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\{clsid}` — removes the visible sidebar pin (this key is not WOW6432 redirected)
- `Software\Classes\CLSID\{clsid}`
- `Software\Classes\Wow6432Node\CLSID\{clsid}`
- value `{clsid}` under `Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel`

This mirrors the write-set in `navigationpanehelper.cpp` and the removal loop in `cmake/modules/NSIS.template.in`.

Add `ArchitecturesInstallIn64BitMode=x64` to `[Setup]` so the elevated, otherwise-32-bit uninstaller's HKCU registry operations hit the 64-bit view. The client writes both the native CLSID and the explicit `Wow6432Node` copy; deleting both paths covers both views.

### Decisions

- **Match scope: Avuz names only.** Remove entries whose `ApplicationName` is `Avuz Conecta` or `Avuz ConectaDev`. Do not match legacy `Nextcloud`, to avoid clobbering a separately-installed Nextcloud client's sidebar.
- **Registry scope: HKCU only.** Correct when the user is a local admin (common single-user Windows). Caveat: if the uninstaller is elevated by a different admin account, `HKCU` resolves to that account's hive and the logged-in user's entries are missed. Accepted; out of scope to scan all hives.

## Non-Goals (YAGNI)

- No `explorer.exe` restart — unnecessary, no app DLLs locked in explorer.
- No `SOFTWARE\...\Explorer\SyncRootManager` / CfApi sync-root cleanup — separate concern, owned by the app's `unregisterSyncRoot`.
- No additional `{userappdata}` config wipe beyond the existing `[UninstallDelete]` and `cleandata` task.

## Verification

No test harness exists for `.iss` scripts. Verification is a manual Windows checklist.

Primary (app running at uninstall):

1. Install Avuz Conecta. Launch it. Confirm the sidebar pin appears in Explorer.
2. Confirm `HKCU\...\Desktop\NameSpace` has a `{clsid}` with `ApplicationName = Avuz Conecta`.
3. Uninstall while the app runs.
4. Assert: (a) app process gone; (b) `C:\Program Files\Avuz Conecta` gone; (c) sidebar pin gone; (d) `Desktop\NameSpace\{clsid}`, `Classes\CLSID\{clsid}` (both views), and the `HideDesktopIcons\NewStartPanel` value all gone.

Regression (app already closed at uninstall):

5. Install, launch, close the app, uninstall. Assert (a)–(d) above still hold; no errors.
