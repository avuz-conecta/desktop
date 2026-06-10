# Large-Sync Notice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a non-blocking tray notice ("Syncing thousands of files — the app may be slow during the sync.") while the current sync has more than a threshold number of items, with a pt-BR translation.

**Architecture:** Add a derived boolean property `largeSyncInProgress` to `SyncStatusSummary` (the existing C++ model behind the tray sync display), bind a small notice label to it in `SyncStatus.qml`, and ship the pt-BR string in `client_pt_BR.ts`. No sync-engine changes.

**Tech Stack:** C++17, Qt 6 (QObject properties), QML, Qt Linguist `.ts` translations. Tests: Qt Test + CTest on the mac build (`cmake -S . -B build -G Ninja -DCMAKE_PREFIX_PATH=/opt/homebrew -DBUILD_TESTING=ON`).

**Spec:** `docs/superpowers/specs/2026-06-10-large-sync-notice-design.md`

---

## File Structure

- `src/gui/tray/syncstatussummary.h` — add property, signal, getter, threshold member, test friend.
- `src/gui/tray/syncstatussummary.cpp` — init threshold, implement getter, emit on change from the two setters.
- `src/gui/tray/SyncStatus.qml` — notice label bound to the new property.
- `translations/client_pt_BR.ts` — pt-BR translation entry.
- `test/testsyncstatussummary.cpp` (new) + `test/CMakeLists.txt` — unit test for the property.

---

## Task 1: `largeSyncInProgress` property on SyncStatusSummary

**Files:**
- Modify: `src/gui/tray/syncstatussummary.h`
- Modify: `src/gui/tray/syncstatussummary.cpp`
- Create: `test/testsyncstatussummary.cpp`
- Modify: `test/CMakeLists.txt`

- [ ] **Step 1: Write the failing test**

Create `test/testsyncstatussummary.cpp`:

```cpp
/*
 * This software is in the public domain, furnished "as is", without technical
 * support, and with no warranty, express or implied, as to its usefulness for
 * any purpose.
 */
#include <QtTest>
#include "syncstatussummary.h"

using namespace OCC;

class TestSyncStatusSummary : public QObject
{
    Q_OBJECT

private slots:
    void notLargeWhenBelowThreshold()
    {
        SyncStatusSummary summary;
        summary.setSyncingForTesting(true);
        summary.setTotalFilesForTesting(10);
        QVERIFY(!summary.largeSyncInProgress());
    }

    void largeWhenSyncingAndAboveThreshold()
    {
        SyncStatusSummary summary;
        QSignalSpy spy(&summary, &SyncStatusSummary::largeSyncInProgressChanged);
        summary.setSyncingForTesting(true);
        summary.setTotalFilesForTesting(20001);
        QVERIFY(summary.largeSyncInProgress());
        QCOMPARE(spy.count(), 1); // emitted exactly once on the transition
    }

    void notLargeWhenNotSyncingEvenIfManyFiles()
    {
        SyncStatusSummary summary;
        summary.setTotalFilesForTesting(50000);
        summary.setSyncingForTesting(false);
        QVERIFY(!summary.largeSyncInProgress());
    }

    void clearsWhenSyncStops()
    {
        SyncStatusSummary summary;
        summary.setSyncingForTesting(true);
        summary.setTotalFilesForTesting(30000);
        QVERIFY(summary.largeSyncInProgress());
        summary.setSyncingForTesting(false);
        QVERIFY(!summary.largeSyncInProgress());
    }
};

QTEST_GUILESS_MAIN(TestSyncStatusSummary)
#include "testsyncstatussummary.moc"
```

- [ ] **Step 2: Register the test**

In `test/CMakeLists.txt`, after the line `nextcloud_add_test(SetUserStatusDialog)` (a GUI-linking test in that file; if absent, place it next to another `nextcloud_add_test(...)` that links the GUI), add:

```cmake
nextcloud_add_test(SyncStatusSummary)
```

- [ ] **Step 3: Run the test to verify it fails to build**

Run: `cmake -S . -B build -G Ninja -DCMAKE_PREFIX_PATH=/opt/homebrew -DBUILD_TESTING=ON -DCMAKE_BUILD_TYPE=Debug && ninja -C build SyncStatusSummaryTest`
Expected: FAIL — `largeSyncInProgress`, `setSyncingForTesting`, `setTotalFilesForTesting`, and the signal don't exist yet.

- [ ] **Step 4: Add the property/signal/getter + test hooks to the header**

In `src/gui/tray/syncstatussummary.h`:

After the `totalFiles` Q_PROPERTY line (`Q_PROPERTY(qint64 totalFiles READ totalFiles NOTIFY totalFilesChanged)`), add:

```cpp
    Q_PROPERTY(bool largeSyncInProgress READ largeSyncInProgress NOTIFY largeSyncInProgressChanged)
```

In the `public:` getters block (after `[[nodiscard]] qint64 totalFiles() const;`), add:

```cpp
    [[nodiscard]] bool largeSyncInProgress() const;

    // Test-only setters (the production setters are private and driven by sync signals).
    void setSyncingForTesting(bool value) { setSyncing(value); }
    void setTotalFilesForTesting(qint64 value) { setTotalFiles(value); }
```

In the `signals:` block (after `void totalFilesChanged();`), add:

```cpp
    void largeSyncInProgressChanged();
```

In the `private:` members (after `qint64 _totalFiles = 0;`), add:

```cpp
    int _largeSyncThreshold = 20000;
    bool _largeSyncInProgress = false;
```

Add a private helper declaration near the other `set*` helpers (after `void setTotalFiles(const qint64 value);`):

```cpp
    void updateLargeSyncInProgress();
```

- [ ] **Step 5: Implement in the .cpp**

In `src/gui/tray/syncstatussummary.cpp`:

In the constructor body (`SyncStatusSummary::SyncStatusSummary(QObject *parent)`), after the base initialisation, read the optional env override:

```cpp
    const auto thresholdOverride = qEnvironmentVariableIntValue("OWNCLOUD_LARGE_SYNC_NOTICE_THRESHOLD");
    if (thresholdOverride > 0) {
        _largeSyncThreshold = thresholdOverride;
    }
```

Add the getter and helper (place next to `totalFiles()`):

```cpp
bool SyncStatusSummary::largeSyncInProgress() const
{
    return _largeSyncInProgress;
}

void SyncStatusSummary::updateLargeSyncInProgress()
{
    const auto newValue = _isSyncing && _totalFiles > _largeSyncThreshold;
    if (newValue != _largeSyncInProgress) {
        _largeSyncInProgress = newValue;
        emit largeSyncInProgressChanged();
    }
}
```

In `setSyncing(bool value)`, replace:

```cpp
    _isSyncing = value;
    emit syncingChanged();
}
```

with:

```cpp
    _isSyncing = value;
    emit syncingChanged();
    updateLargeSyncInProgress();
}
```

In `setTotalFiles(const qint64 value)`, replace:

```cpp
    if (value != _totalFiles) {
        _totalFiles = value;
        emit totalFilesChanged();
    }
}
```

with:

```cpp
    if (value != _totalFiles) {
        _totalFiles = value;
        emit totalFilesChanged();
        updateLargeSyncInProgress();
    }
}
```

- [ ] **Step 6: Build + run the test**

Run: `ninja -C build SyncStatusSummaryTest && ctest --test-dir build -R SyncStatusSummary --output-on-failure`
Expected: PASS (4 tests).

- [ ] **Step 7: Commit**

```bash
git add src/gui/tray/syncstatussummary.h src/gui/tray/syncstatussummary.cpp test/testsyncstatussummary.cpp test/CMakeLists.txt
git commit -m "feat(tray): add largeSyncInProgress property to SyncStatusSummary"
```

---

## Task 2: Show the notice in SyncStatus.qml

**Files:**
- Modify: `src/gui/tray/SyncStatus.qml`

- [ ] **Step 1: Add the notice label**

In `src/gui/tray/SyncStatus.qml`, inside the `ColumnLayout { id: syncProgressLayout ... }`, immediately AFTER the existing detail label block:

```qml
        EnforcedPlainTextLabel {
            id: syncProgressDetailText
            // ... existing properties ...
            text: syncStatus.syncStatusDetailString
            visible: syncStatus.syncStatusDetailString !== ""
        }
```

add:

```qml
        EnforcedPlainTextLabel {
            id: largeSyncNoticeText
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            font.pixelSize: Style.subLinePixelSize
            color: Style.ncSecondaryTextColor
            text: qsTr("Syncing thousands of files — the app may be slow during the sync.")
            visible: syncStatus.largeSyncInProgress
        }
```

(Match `font.pixelSize`/`color` to whatever the neighbouring `syncProgressDetailText` uses if those exact `Style` names differ in this file — use the same ones it uses, do not invent new style constants.)

- [ ] **Step 2: Build the GUI to verify QML compiles/loads**

Run: `ninja -C build BatchedDiscoveryTest`
Expected: builds (this links `nextcloudCore`, which bundles the QML; a QML syntax error would fail the resource compile).

- [ ] **Step 3: Commit**

```bash
git add src/gui/tray/SyncStatus.qml
git commit -m "feat(tray): show large-sync notice in SyncStatus"
```

---

## Task 3: pt-BR translation

**Files:**
- Modify: `translations/client_pt_BR.ts`

- [ ] **Step 1: Add the SyncStatus context message**

In `translations/client_pt_BR.ts`, find the `<context>` whose `<name>SyncStatus</name>` (the QML file's translation context). If it exists, add a `<message>` inside it; if no such context exists, add a new one at the end of the `<TS>` element before `</TS>`:

```xml
<context>
    <name>SyncStatus</name>
    <message>
        <source>Syncing thousands of files — the app may be slow during the sync.</source>
        <translation>Sync de milhares de arquivos, o aplicativo pode ficar lento durante o sync</translation>
    </message>
</context>
```

(The `<source>` must match the `qsTr(...)` string from Task 2 byte-for-byte, including the em dash `—`.)

- [ ] **Step 2: Verify the .ts is well-formed XML**

Run: `python3 -c "import xml.dom.minidom,sys; xml.dom.minidom.parse('translations/client_pt_BR.ts'); print('ok')"`
Expected: prints `ok`.

- [ ] **Step 3: Commit**

```bash
git add translations/client_pt_BR.ts
git commit -m "i18n(pt-BR): translate large-sync notice"
```

---

## Task 4: Manual verification on Windows

**Files:** none.

- [ ] **Step 1: Build + install**

```powershell
git pull
. C:\CraftRoot\craft\craftenv.ps1
cd C:\Dev\desktop
.\admin\win\build-installer.ps1 -CraftRoot C:\CraftRoot
```

- [ ] **Step 2: Verify behaviour**

- Start a sync with > 20000 items (e.g. the train2017 folder).
- Confirm the notice appears in the tray sync area during the sync, in pt-BR
  (`Sync de milhares de arquivos, o aplicativo pode ficar lento durante o sync`).
- Confirm it disappears when the sync finishes.
- Optional: set `setx OWNCLOUD_LARGE_SYNC_NOTICE_THRESHOLD 100 /M`, restart, sync
  a small folder, confirm the notice now appears (threshold override works).

---

## Self-Review

**Spec coverage:**
- Trigger `syncing && totalFiles > threshold`, env-overridable default 20000 → Task 1. ✓
- Any sync over threshold, no first-sync state → Task 1 (pure derived). ✓
- Non-modal/non-dismissable/self-clearing notice in tray → Task 2 (`visible:` binding). ✓
- EN source + pt-BR → Task 2 (qsTr) + Task 3 (.ts). ✓
- Unit test for the property + manual Windows check → Task 1 Steps 1-6 + Task 4. ✓
- Out-of-scope items (toasts, first-sync state, dismiss, engine changes) → not in plan. ✓

**Placeholder scan:** No TBD/TODO. Two spots ask the implementer to match existing neighbouring values (the QML `Style.*` font/color names, and the `.ts` context location) rather than invent — both reference the precise neighbour to copy from.

**Type consistency:** `largeSyncInProgress` (getter + property + member `_largeSyncInProgress`), `largeSyncInProgressChanged` (signal), `_largeSyncThreshold`, `updateLargeSyncInProgress`, `setSyncingForTesting`/`setTotalFilesForTesting`, env var `OWNCLOUD_LARGE_SYNC_NOTICE_THRESHOLD` — used consistently across tasks. The qsTr source string in Task 2 matches the `.ts` `<source>` in Task 3.
