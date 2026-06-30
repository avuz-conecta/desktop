# Windows Uninstall Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Avuz Conecta Windows uninstaller close the running app, fully remove `{app}`, and remove the Explorer sidebar pin.

**Architecture:** All changes live in `installer.iss` (Inno Setup). Add an uninstall-time graceful-then-force process close and a navigation-pane registry cleanup. Installer stays 32-bit mode (install dir unchanged); the one WOW-redirected registry key is cleaned via `reg.exe /reg:64`. No new toolchain, no change to `build-installer.ps1`.

**Tech Stack:** Inno Setup 6 (`ISCC.exe`), Pascal Script `[Code]` section, `taskkill.exe` / `tasklist` / `reg.exe`.

## Global Constraints

- Only file touched: `installer.iss` (repo root).
- Installer stays 32-bit mode. Do NOT add `ArchitecturesInstallIn64BitMode`. Install dir stays `C:\Program Files (x86)\Avuz Conecta`.
- Uninstall process kill: Avuz only — `avuzconecta.exe`, `avuzconectadev.exe`. Never `nextcloud.exe` at uninstall.
- Install-time `KillRunningProcesses()` (full list, incl. `nextcloud.exe`) stays as-is — it runs only for the `cleandata` migration task. Do not touch it.
- Close is graceful-then-force: `taskkill /IM` (WM_CLOSE) → poll up to 10 s → `taskkill /F /IM` fallback.
- Nav-pane match: `ApplicationName` equal to `Avuz Conecta` or `Avuz ConectaDev` only. Never match `Nextcloud`.
- Registry scope: `HKEY_CURRENT_USER` only.
- No automated test harness exists for `.iss`. Verification is the manual Windows checklist in each task. The build/verify runs on Windows via `admin\win\build-installer.ps1`.
- Spec: `docs/superpowers/specs/2026-06-30-windows-uninstall-cleanup-design.md`.

---

### Task 1: Close app at uninstall (graceful-then-force)

Fixes Issue 1 (app not closed) and unblocks Issue 2 (`{app}` leftovers). Once the process is dead, the existing `[UninstallDelete] {app}` removes the directory.

**Files:**
- Modify: `installer.iss` — `[Code]` section.

**Interfaces:**
- Consumes: nothing.
- Produces: `ProcessRunning(const ExeName: String): Boolean`; `CloseAvuzProcesses()`; `InitializeUninstall(): Boolean`. Task 2 adds a separate uninstall event function and does not depend on these. The existing `KillRunningProcesses()` and `PrepareToInstall()` are left untouched.

- [ ] **Step 1: Add the `ProcessRunning` helper**

In `[Code]`, after the existing `KillRunningProcesses` procedure, add:

```pascal
function ProcessRunning(const ExeName: String): Boolean;
var
  ResultCode: Integer;
begin
  Result := Exec('cmd.exe',
    '/C tasklist /FI "IMAGENAME eq ' + ExeName + '" /NH | findstr /I "' + ExeName + '" >nul',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode) and (ResultCode = 0);
end;
```

- [ ] **Step 2: Add the `CloseAvuzProcesses` helper**

Immediately after `ProcessRunning`, add the graceful-then-force closer (Avuz exes only):

```pascal
procedure CloseAvuzProcesses();
var
  ResultCode, Waited: Integer;
begin
  // Graceful WM_CLOSE (no /F). Tray app may ignore; force fallback below.
  Exec('taskkill.exe', '/IM avuzconecta.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec('taskkill.exe', '/IM avuzconectadev.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);

  // Poll up to 10 s for graceful exit.
  Waited := 0;
  while (Waited < 10000) and (ProcessRunning('avuzconecta.exe') or ProcessRunning('avuzconectadev.exe')) do
  begin
    Sleep(500);
    Waited := Waited + 500;
  end;

  // Force fallback for whatever is still alive.
  if ProcessRunning('avuzconecta.exe') then
    Exec('taskkill.exe', '/F /IM avuzconecta.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  if ProcessRunning('avuzconectadev.exe') then
    Exec('taskkill.exe', '/F /IM avuzconectadev.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);

  // Settle so the OS releases file handles before file removal.
  Sleep(1000);
end;
```

- [ ] **Step 3: Add `InitializeUninstall` to close on every uninstall**

Immediately after `CloseAvuzProcesses`, add:

```pascal
function InitializeUninstall(): Boolean;
begin
  CloseAvuzProcesses();
  Result := True;
end;
```

- [ ] **Step 4: Compile the installer**

Run (Windows):

```
"C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer.iss
```

Expected: compiles with no errors; produces `AvuzConecta-4.0.9-setup.exe`. (Requires `build-release\bin` populated — run `admin\win\build-installer.ps1` first if needed.)

- [ ] **Step 5: Manual verify**

1. Install. Launch Avuz Conecta (leave it running in the tray).
2. Run the uninstaller.
3. Assert: app process gone (Task Manager shows no `avuzconecta.exe`).
4. Assert: `C:\Program Files (x86)\Avuz Conecta` gone (no leftover files).

- [ ] **Step 6: Commit**

```bash
git add installer.iss
git commit -m "fix(win): close app on uninstall so files are removed"
```

---

### Task 2: Remove Explorer navigation-pane entries on uninstall

Fixes Issue 3 (sidebar pin survives). Enumerate the user's NameSpace CLSIDs, match Avuz `ApplicationName`, delete the entry plus its backing CLSID keys in both registry views.

**Files:**
- Modify: `installer.iss` — `[Code]` section.

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `RemoveNavigationPaneEntries()` procedure and `CurUninstallStepChanged(CurUninstallStep: TUninstallStep)` event procedure.

- [ ] **Step 1: Add the cleanup procedure**

In `[Code]`, add `RemoveNavigationPaneEntries`. It snapshots the NameSpace subkeys, then for each Avuz-matching CLSID deletes the NameSpace key (removes the visible pin), the HideDesktopIcons value, and the backing CLSID key in both 64-bit and 32-bit views:

```pascal
procedure RemoveNavigationPaneEntries();
const
  NavNameSpaceKey = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace';
  HideDesktopIconsKey = 'Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel';
var
  Clsids: TArrayOfString;
  I, ResultCode: Integer;
  AppName, Clsid: String;
begin
  if not RegGetSubkeyNames(HKEY_CURRENT_USER, NavNameSpaceKey, Clsids) then
    exit;
  for I := 0 to GetArrayLength(Clsids) - 1 do
  begin
    Clsid := Clsids[I];
    if RegQueryStringValue(HKEY_CURRENT_USER, NavNameSpaceKey + '\' + Clsid, 'ApplicationName', AppName) then
    begin
      if (AppName = 'Avuz Conecta') or (AppName = 'Avuz ConectaDev') then
      begin
        // Visible pin + desktop-hide flag (not WOW6432 redirected).
        RegDeleteKeyIncludingSubkeys(HKEY_CURRENT_USER, NavNameSpaceKey + '\' + Clsid);
        RegDeleteValue(HKEY_CURRENT_USER, HideDesktopIconsKey, Clsid);
        // Backing CLSID in both registry views (x64 client wrote native + Wow6432Node).
        Exec('reg.exe', 'delete "HKCU\Software\Classes\CLSID\' + Clsid + '" /reg:64 /f', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
        Exec('reg.exe', 'delete "HKCU\Software\Classes\CLSID\' + Clsid + '" /reg:32 /f', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
      end;
    end;
  end;
end;
```

- [ ] **Step 2: Wire it to the uninstall step**

Immediately after `RemoveNavigationPaneEntries`, add:

```pascal
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    RemoveNavigationPaneEntries();
end;
```

- [ ] **Step 3: Compile the installer**

Run (Windows):

```
"C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer.iss
```

Expected: compiles with no errors.

- [ ] **Step 4: Manual verify (primary — app running)**

1. Install, launch Avuz Conecta, add/sync a folder so the sidebar pin appears in Explorer.
2. Confirm in `regedit`: under `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace` a `{clsid}` has `ApplicationName = Avuz Conecta`.
3. Uninstall while the app runs.
4. Assert: sidebar pin gone from Explorer.
5. Assert in `regedit`, all gone: `Desktop\NameSpace\{clsid}`; `Software\Classes\CLSID\{clsid}` in both the 64-bit view and the 32-bit `Wow6432Node\CLSID\{clsid}` view; the `{clsid}` value under `HideDesktopIcons\NewStartPanel`.

- [ ] **Step 5: Manual verify (regression — app already closed)**

1. Install, launch, close the app, then uninstall.
2. Assert: uninstall completes with no error; `{app}` gone; sidebar pin and the registry locations from Step 4.5 gone.

- [ ] **Step 6: Commit**

```bash
git add installer.iss
git commit -m "fix(win): remove Explorer sidebar entries on uninstall"
```

---

## Self-Review

- **Spec coverage:** Issue 1 → Task 1 (Steps 1-3). Issue 2 → Task 1 (existing `[UninstallDelete]` succeeds after close; verified Step 5.4). Issue 3 → Task 2. Stay-32-bit / `reg.exe /reg:64` decision → Task 2 Step 1. Graceful-then-force + poll → Task 1 Step 2. Avuz-only uninstall kill → Task 1 Step 2 (only `avuzconecta`/`avuzconectadev`). Install-time `nextcloud.exe` kill untouched → constraint honored, no task modifies `KillRunningProcesses`/`PrepareToInstall`. Avuz-only nav match → Task 2 Step 1. HKCU-only → Task 2 (all Inno reg ops `HKEY_CURRENT_USER`; `reg.exe` paths `HKCU\`). Non-goals (no explorer restart, no SyncRootManager) and accepted gaps (pre-rebrand, cross-account) → not implemented, as specified.
- **Placeholder scan:** none — all code blocks complete, all commands exact.
- **Type consistency:** `ProcessRunning` / `CloseAvuzProcesses` defined in Task 1 and called within Task 1 only; `RemoveNavigationPaneEntries` defined and wired in Task 2. Inno built-ins used: `Exec`, `Sleep`, `RegGetSubkeyNames`, `RegQueryStringValue`, `RegDeleteKeyIncludingSubkeys`, `RegDeleteValue`, `GetArrayLength`, `TArrayOfString`, `InitializeUninstall`, `CurUninstallStepChanged`, `TUninstallStep`/`usUninstall`. Note: `InitializeUninstall` and `CurUninstallStepChanged` are distinct event functions, so defining both is valid.
