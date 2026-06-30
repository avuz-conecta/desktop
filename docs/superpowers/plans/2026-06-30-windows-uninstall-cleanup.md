# Windows Uninstall Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Avuz Conecta Windows uninstaller close the running app, fully remove `{app}`, and remove the Explorer sidebar pin.

**Architecture:** All changes live in `installer.iss` (Inno Setup). Add an uninstall-time process kill and a navigation-pane registry cleanup, plus 64-bit registry view. No new toolchain, no change to `build-installer.ps1`.

**Tech Stack:** Inno Setup 6 (`ISCC.exe`), Pascal Script `[Code]` section.

## Global Constraints

- Only file touched: `installer.iss` (repo root).
- Nav-pane match: `ApplicationName` equal to `Avuz Conecta` or `Avuz ConectaDev` only. Never match `Nextcloud`.
- Registry scope: `HKEY_CURRENT_USER` only.
- Process names to kill: `avuzconecta.exe`, `AvuzConecta.exe`, `avuzconectadev.exe`.
- No automated test harness exists for `.iss`. Verification is the manual Windows checklist in each task. The build/verify runs on Windows via `admin\win\build-installer.ps1`.
- Spec: `docs/superpowers/specs/2026-06-30-windows-uninstall-cleanup-design.md`.

---

### Task 1: Force-close app at uninstall + 64-bit registry view

Fixes Issue 1 (app not closed) and unblocks Issue 2 (`{app}` leftovers). Once the process is dead, the existing `[UninstallDelete] {app}` removes the directory.

**Files:**
- Modify: `installer.iss` — `[Setup]` section and `[Code]` section.

**Interfaces:**
- Consumes: existing `KillRunningProcesses()` procedure in `[Code]`.
- Produces: `InitializeUninstall(): Boolean` event function; extended `KillRunningProcesses()` that also kills `avuzconectadev.exe`. Task 2 adds a separate uninstall event function and does not depend on these.

- [ ] **Step 1: Add 64-bit install mode to `[Setup]`**

In `[Setup]`, immediately after the `CloseApplicationsFilter=*.exe` line, add:

```ini
ArchitecturesInstallIn64BitMode=x64
```

- [ ] **Step 2: Add the dev exe to `KillRunningProcesses`**

In `[Code]`, replace the existing `KillRunningProcesses` body so it also kills the dev build. Final procedure:

```pascal
procedure KillRunningProcesses();
var
  ResultCode: Integer;
begin
  Exec('taskkill.exe', '/F /IM avuzconecta.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec('taskkill.exe', '/F /IM AvuzConecta.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec('taskkill.exe', '/F /IM avuzconectadev.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec('taskkill.exe', '/F /IM nextcloud.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;
```

- [ ] **Step 3: Add `InitializeUninstall` to force-close on every uninstall**

In `[Code]`, after `KillRunningProcesses`, add:

```pascal
function InitializeUninstall(): Boolean;
begin
  KillRunningProcesses();
  Sleep(1500);
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
3. Assert: app process is gone (Task Manager shows no `avuzconecta.exe`).
4. Assert: `C:\Program Files\Avuz Conecta` is gone (no leftover files).

- [ ] **Step 6: Commit**

```bash
git add installer.iss
git commit -m "fix(win): force-close app on uninstall so files are removed"
```

---

### Task 2: Remove Explorer navigation-pane entries on uninstall

Fixes Issue 3 (sidebar pin survives). Enumerate the user's NameSpace CLSIDs, match Avuz `ApplicationName`, delete the entry plus its backing CLSID keys.

**Files:**
- Modify: `installer.iss` — `[Code]` section.

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `RemoveNavigationPaneEntries()` procedure and `CurUninstallStepChanged(CurUninstallStep: TUninstallStep)` event procedure.

- [ ] **Step 1: Add the cleanup procedure**

In `[Code]`, add `RemoveNavigationPaneEntries`. It snapshots the NameSpace subkeys, then for each matching CLSID deletes the NameSpace key (removes the visible pin), both CLSID views, and the HideDesktopIcons value:

```pascal
procedure RemoveNavigationPaneEntries();
const
  NavNameSpaceKey = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace';
  HideDesktopIconsKey = 'Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel';
var
  Clsids: TArrayOfString;
  I: Integer;
  AppName: String;
begin
  if not RegGetSubkeyNames(HKEY_CURRENT_USER, NavNameSpaceKey, Clsids) then
    exit;
  for I := 0 to GetArrayLength(Clsids) - 1 do
  begin
    if RegQueryStringValue(HKEY_CURRENT_USER, NavNameSpaceKey + '\' + Clsids[I], 'ApplicationName', AppName) then
    begin
      if (AppName = 'Avuz Conecta') or (AppName = 'Avuz ConectaDev') then
      begin
        RegDeleteKeyIncludingSubkeys(HKEY_CURRENT_USER, NavNameSpaceKey + '\' + Clsids[I]);
        RegDeleteKeyIncludingSubkeys(HKEY_CURRENT_USER, 'Software\Classes\CLSID\' + Clsids[I]);
        RegDeleteKeyIncludingSubkeys(HKEY_CURRENT_USER, 'Software\Classes\Wow6432Node\CLSID\' + Clsids[I]);
        RegDeleteValue(HKEY_CURRENT_USER, HideDesktopIconsKey, Clsids[I]);
      end;
    end;
  end;
end;
```

- [ ] **Step 2: Wire it to the uninstall step**

In `[Code]`, add:

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
5. Assert in `regedit`, all gone: `Desktop\NameSpace\{clsid}`; `Software\Classes\CLSID\{clsid}`; `Software\Classes\Wow6432Node\CLSID\{clsid}`; the `{clsid}` value under `HideDesktopIcons\NewStartPanel`.

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

- **Spec coverage:** Issue 1 → Task 1 (Steps 2-3). Issue 2 → Task 1 (existing `[UninstallDelete]` succeeds after kill; verified Step 5.4). Issue 3 → Task 2. 64-bit view decision → Task 1 Step 1. Avuz-only match → Task 2 Step 1. HKCU-only → Task 2 (all ops `HKEY_CURRENT_USER`). Non-goals (no explorer restart, no SyncRootManager) → not implemented, as specified.
- **Placeholder scan:** none — all code blocks complete, all commands exact.
- **Type consistency:** `KillRunningProcesses` named identically in Task 1 Steps 2-3. `RemoveNavigationPaneEntries` named identically in Task 2 Steps 1-2. Inno built-ins used: `RegGetSubkeyNames`, `RegQueryStringValue`, `RegDeleteKeyIncludingSubkeys`, `RegDeleteValue`, `InitializeUninstall`, `CurUninstallStepChanged`, `TUninstallStep`/`usUninstall`.
