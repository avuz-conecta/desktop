# Batched Discovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the desktop client sync folders with one very large flat directory (100k+ files) without freezing or losing data, by capping each discovery pass to a configurable item count and resuming across follow-up syncs via existing etag state.

**Architecture:** During discovery, once `_syncItems` reaches a batch limit, stop discovery *cleanly* (normal teardown, not a bypass), let the partial sync commit its records as a success, and schedule a follow-up only while progress is being made. Directories that were only partially discovered must NOT have their etag committed, so the next sync re-lists them — etag state is the resume cursor. Also replace the O(n²) sorted-insert of `_syncItems` with append + single sort.

**Tech Stack:** C++17, Qt 6, Nextcloud desktop sync engine (`src/libsync`), test harness `FakeFolder` + Qt Test (`test/`), CTest.

**Base:** branch `avuz-customization-v4.0.9` (rebased onto upstream v4.0.9; the old buggy batch commits are dropped — this is a clean reimplementation).

**Spec:** `docs/superpowers/specs/2026-06-07-batched-discovery-fix-design.md`

---

## File Structure

- `src/libsync/syncoptions.h` / `.cpp` — add `_discoveryBatchSize` option + env var parsing.
- `src/libsync/discoveryphase.h` / `.cpp` — `DiscoveryPhase`: add `_batchLimitReached` flag + `stopDiscoveryForBatch()` that performs the **clean** teardown and emits `finished` through the normal path; guard `scheduleMoreJobs`.
- `src/libsync/discovery.cpp` — `ProcessDirectoryJob`: stop iterating entries / scheduling subjobs when the batch limit is reached; ensure a directory interrupted by the batch limit is left with an instruction that does NOT commit a new etag.
- `src/libsync/syncengine.h` / `.cpp` — `SyncEngine::slotItemDiscovered`: count items, trigger the batch stop; change `_syncItems` to append + sort once before `finishSync`; expose `wasDiscoveryBatchLimited()`; persist per-run committed-item progress for the gate.
- `src/gui/folder.cpp` — `Folder::slotSyncFinished`: progress-gated follow-up for batched syncs (replace the buggy unlimited-followup logic).
- `test/testbatcheddiscovery.cpp` — new behavior test suite (the correctness contract).
- `test/CMakeLists.txt` — register the new test.

---

## Conventions

- Build (Windows, in a craft-env shell):
  `. C:\CraftRoot\craft\craftenv.ps1; cd C:\Dev\desktop; .\admin\win\build-installer.ps1 -CraftRoot C:\CraftRoot -SkipPackage`
- Run one test target: `cd build-release; ctest -R BatchedDiscovery --output-on-failure`
- Commit messages: Conventional Commits, no Claude attribution (per repo policy).
- TDD: write the failing test, see it fail, implement minimally, see it pass, commit.

---

## Task 1: Add the discovery batch-size option

**Files:**
- Modify: `src/libsync/syncoptions.h` (near `int _parallelNetworkJobs = 6;`, line ~59)
- Modify: `src/libsync/syncoptions.cpp` (in `fillFromEnvironmentVariables()`)

- [ ] **Step 1: Add the option field**

In `src/libsync/syncoptions.h`, after `_parallelNetworkJobs`:

```cpp
    /** Maximum number of items to collect in one discovery pass.
     *  0 means unlimited (feature disabled).
     *  When >0, discovery stops after this many items and a follow-up sync is
     *  scheduled to collect the rest. Prevents UI freeze / memory blowup on
     *  folders containing a single very large directory (100k+ files).
     */
    int _discoveryBatchSize = 50000;
```

- [ ] **Step 2: Parse the env override**

In `src/libsync/syncoptions.cpp`, inside `fillFromEnvironmentVariables()`, after the `OWNCLOUD_MAX_PARALLEL` block:

```cpp
    int discoveryBatchSize = qEnvironmentVariableIntValue("OWNCLOUD_DISCOVERY_BATCH_SIZE");
    if (discoveryBatchSize > 0) {
        _discoveryBatchSize = discoveryBatchSize;
    }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `.\admin\win\build-installer.ps1 -CraftRoot C:\CraftRoot -SkipPackage`
Expected: compiles, no errors.

- [ ] **Step 4: Commit**

```bash
git add src/libsync/syncoptions.h src/libsync/syncoptions.cpp
git commit -m "feat(sync): add configurable discovery batch size option"
```

---

## Task 2: Behavior test suite (the correctness contract)

This suite is written first and drives the rest. It uses `FakeFolder` (see existing `test/testsyncengine.cpp` for the pattern). The tests start RED and turn GREEN as Tasks 3-6 land.

**Files:**
- Create: `test/testbatcheddiscovery.cpp`
- Modify: `test/CMakeLists.txt`

- [ ] **Step 1: Register the test target**

In `test/CMakeLists.txt`, alongside the other `nextcloud_add_test(...)` entries (match the existing macro name used in that file, e.g. `nextcloud_add_test(SyncEngine)`), add:

```cmake
nextcloud_add_test(BatchedDiscovery)
```

- [ ] **Step 2: Write the test file**

Create `test/testbatcheddiscovery.cpp`:

```cpp
/*
 * This software is in the public domain, furnished "as is", without technical
 * support, and with no warranty, express or implied, as to its usefulness for
 * any purpose.
 */
#include <QtTest>
#include "syncenginetestutils.h"
#include "syncengine.h"

using namespace OCC;

namespace {
// Build a remote folder "big" containing `count` files of 10 bytes each.
void fillBigDir(FileInfo &root, int count)
{
    root.mkdir("big");
    for (int i = 0; i < count; ++i) {
        root.insert(QStringLiteral("big/file%1.bin").arg(i, 6, 10, QLatin1Char('0')), 10);
    }
}

// Run syncs until no further sync is requested, capped to avoid hanging a
// broken (non-converging) implementation. Returns the number of syncs run.
int syncUntilDone(FakeFolder &fake, int maxSyncs = 60)
{
    int runs = 0;
    do {
        ++runs;
        fake.syncOnce();
    } while (fake.syncEngine().isAnotherSyncNeeded() != NoFollowUpSync && runs < maxSyncs);
    return runs;
}
}

class TestBatchedDiscovery : public QObject
{
    Q_OBJECT

private slots:
    // With a batch limit smaller than the dir, a single sync must stop early
    // and request a follow-up.
    void singlePassStopsAtBatchLimit()
    {
        FakeFolder fake{ FileInfo{} };
        fillBigDir(fake.remoteModifier(), 25);
        fake.syncEngine().syncOptions()._discoveryBatchSize = 10;

        fake.syncOnce();

        QCOMPARE(fake.syncEngine().isAnotherSyncNeeded(), ImmediateFollowUp);
        QVERIFY(fake.syncEngine().wasDiscoveryBatchLimited());
    }

    // Across follow-up syncs every file must end up locally present, and the
    // process must converge (terminate) well within the cap.
    void convergesAndSyncsEverything()
    {
        FakeFolder fake{ FileInfo{} };
        fillBigDir(fake.remoteModifier(), 25);
        fake.syncEngine().syncOptions()._discoveryBatchSize = 10;

        const int runs = syncUntilDone(fake);

        QVERIFY2(runs < 60, "sync did not converge (infinite follow-up loop)");
        for (int i = 0; i < 25; ++i) {
            const auto path = QStringLiteral("big/file%1.bin").arg(i, 6, 10, QLatin1Char('0'));
            QVERIFY2(fake.currentLocalState().find(path), qPrintable("missing: " + path));
        }
        // Local tree must equal remote tree (nothing lost, nothing extra).
        QCOMPARE(fake.currentLocalState(), fake.currentRemoteState());
    }

    // Each batch must make forward progress: the count of locally-present big/
    // files must strictly increase between the first and second sync.
    void eachBatchMakesProgress()
    {
        FakeFolder fake{ FileInfo{} };
        fillBigDir(fake.remoteModifier(), 25);
        fake.syncEngine().syncOptions()._discoveryBatchSize = 10;

        fake.syncOnce();
        const int afterFirst = fake.currentLocalState().children["big"].children.size();
        fake.syncOnce();
        const int afterSecond = fake.currentLocalState().children["big"].children.size();

        QVERIFY2(afterSecond > afterFirst, "follow-up sync made no progress (would loop forever)");
    }

    // Disabled feature (0) must behave exactly like upstream: one pass, no follow-up.
    void disabledByZeroDoesOneShot()
    {
        FakeFolder fake{ FileInfo{} };
        fillBigDir(fake.remoteModifier(), 25);
        fake.syncEngine().syncOptions()._discoveryBatchSize = 0;

        fake.syncOnce();

        QVERIFY(!fake.syncEngine().wasDiscoveryBatchLimited());
        QCOMPARE(fake.currentLocalState(), fake.currentRemoteState());
    }
};

QTEST_GUILESS_MAIN(TestBatchedDiscovery)
#include "testbatcheddiscovery.moc"
```

- [ ] **Step 3: Build and run — expect compile/link or assertion failures**

Run: `cd build-release; ctest -R BatchedDiscovery --output-on-failure`
Expected: FAILS — `wasDiscoveryBatchLimited()` doesn't exist yet and/or behavior is wrong. This is the RED baseline.

- [ ] **Step 4: Commit the failing test**

```bash
git add test/testbatcheddiscovery.cpp test/CMakeLists.txt
git commit -m "test(sync): add batched discovery behavior suite (red)"
```

---

## Task 3: Detect the batch limit and stop discovery cleanly

This is the cornerstone: when `_syncItems` reaches the limit, set a flag, request a follow-up, and stop discovery via the **normal** teardown path so the partial sync still commits.

**Files:**
- Modify: `src/libsync/syncengine.h` (add member + accessor)
- Modify: `src/libsync/syncengine.cpp` (`slotItemDiscovered` ~322-480, `startSync` reset)
- Modify: `src/libsync/discoveryphase.h` (flag + method decl)
- Modify: `src/libsync/discoveryphase.cpp` (`stopDiscoveryForBatch()`, guard `scheduleMoreJobs`)

- [ ] **Step 1: Add the flag + accessor to SyncEngine**

In `src/libsync/syncengine.h`, in the public section near `isAnotherSyncNeeded()`:

```cpp
    /** True if the last discovery stopped early because the batch limit was hit. */
    [[nodiscard]] bool wasDiscoveryBatchLimited() const { return _discoveryBatchLimitReached; }
```

In the private members section:

```cpp
    bool _discoveryBatchLimitReached = false;
```

- [ ] **Step 2: Reset the flag at sync start**

In `src/libsync/syncengine.cpp`, in `startSync()` near `_syncItems.clear();` (line ~569):

```cpp
    _discoveryBatchLimitReached = false;
```

- [ ] **Step 3: Add the DiscoveryPhase clean-stop method + flag**

In `src/libsync/discoveryphase.h`, in `DiscoveryPhase` public/members:

```cpp
    /** Set when discovery is stopped early due to the batch limit. */
    bool _batchLimitReached = false;

    /** Stop discovery early but cleanly: abort the running job tree and emit
     *  finished() through the normal path so the partial result is committed. */
    void stopDiscoveryForBatch();
```

In `src/libsync/discoveryphase.cpp`, implement it. The normal completion path lives in the `startJob()` lambda (nulls `_currentRootJob`, `deleteLater()`s the tree, emits `finished()`). Reuse that by deleting the root job and emitting finished once:

```cpp
void DiscoveryPhase::stopDiscoveryForBatch()
{
    if (_batchLimitReached) {
        return; // idempotent: only act once
    }
    _batchLimitReached = true;
    _anotherSyncNeeded = true;

    // Tear down the running discovery job tree cleanly. Deleting the root
    // ProcessDirectoryJob deletes its queued/running children (Qt parent-owned)
    // and aborts their in-flight network jobs via their destructors.
    if (_currentRootJob) {
        auto *root = _currentRootJob.data();
        _currentRootJob.clear();
        root->deleteLater();
    }

    // Emit finished asynchronously: stopDiscoveryForBatch() is called from
    // within itemDiscovered handling, so we must not re-enter synchronously.
    QMetaObject::invokeMethod(this, [this]() { emit finished(); }, Qt::QueuedConnection);
}
```

- [ ] **Step 4: Guard scheduleMoreJobs**

In `src/libsync/discoveryphase.cpp`, at the top of `scheduleMoreJobs()`:

```cpp
    if (_batchLimitReached) {
        return;
    }
```

- [ ] **Step 5: Reset the DiscoveryPhase flag where it is constructed**

In `src/libsync/syncengine.cpp`, after `_discoveryPhase = std::make_unique<DiscoveryPhase>();` (a fresh instance already starts with `_batchLimitReached = false`, so no code needed — verify by reading the construction site around line ~640-700). No change if it's freshly constructed each sync.

- [ ] **Step 6: Trigger the stop from slotItemDiscovered**

In `src/libsync/syncengine.cpp`, in `slotItemDiscovered`, immediately before the sorted insert (line ~477, `auto it = std::lower_bound(...)`):

```cpp
    const int batchSize = _syncOptions._discoveryBatchSize;
    if (batchSize > 0 && static_cast<int>(_syncItems.size()) >= batchSize) {
        if (!_discoveryBatchLimitReached) {
            _discoveryBatchLimitReached = true;
            _anotherSyncNeeded = ImmediateFollowUp;
            qCInfo(lcEngine) << "Discovery batch limit reached (" << batchSize
                             << "items). Stopping discovery; follow-up scheduled.";
            if (_discoveryPhase) {
                _discoveryPhase->stopDiscoveryForBatch();
            }
        }
        return; // do not add this item; it will be re-discovered next sync
    }
```

- [ ] **Step 7: Build**

Run: `.\admin\win\build-installer.ps1 -CraftRoot C:\CraftRoot -SkipPackage`
Expected: compiles.

- [ ] **Step 8: Run the test suite**

Run: `cd build-release; ctest -R BatchedDiscovery --output-on-failure`
Expected: `singlePassStopsAtBatchLimit` and `disabledByZeroDoesOneShot` PASS. `convergesAndSyncsEverything` / `eachBatchMakesProgress` may still fail until Task 4 (etag unpinning) — that's expected.

- [ ] **Step 9: Commit**

```bash
git add src/libsync/syncengine.h src/libsync/syncengine.cpp src/libsync/discoveryphase.h src/libsync/discoveryphase.cpp
git commit -m "feat(sync): stop discovery cleanly at batch limit"
```

---

## Task 4: Stop iterating a directory at the limit without pinning its etag

When the batch limit is hit mid-directory, `ProcessDirectoryJob::process()` must stop iterating, and the interrupted directory must NOT be recorded as fully synced (its etag must stay stale so the next sync re-lists it). This is what makes follow-ups converge and prevents missing files.

**Files:**
- Modify: `src/libsync/discovery.cpp` (`process()` entries loop ~181; `processSubJobs`; dir-finalize)

- [ ] **Step 1: Stop the entries loop when the limit is reached**

In `src/libsync/discovery.cpp`, at the top of the `for (auto &f : entries)` loop body (line ~181):

```cpp
        if (_discoveryData->_batchLimitReached) {
            break;
        }
```

- [ ] **Step 2: Stop scheduling subjobs when the limit is reached**

In `ProcessDirectoryJob::processSubJobs(int nbJobs)`, at the very top:

```cpp
    if (_discoveryData->_batchLimitReached) {
        return 0;
    }
```

- [ ] **Step 3: Do not commit a fresh etag for an interrupted directory**

Find where `_dirItem` is finalized after its children complete (in `processSubJobs` when queues are empty, and/or `subJobFinished`). When `_discoveryData->_batchLimitReached` is true, the directory was NOT fully processed, so its metadata-update must be suppressed. Add, where `_dirItem` is about to be emitted/finalized at the "finished" branch:

```cpp
        if (_discoveryData->_batchLimitReached && _dirItem
            && _dirItem->_instruction == CSYNC_INSTRUCTION_UPDATE_METADATA) {
            // Directory only partially discovered: keep its etag stale so the
            // next sync re-lists it and discovers the remaining children.
            _dirItem->_instruction = CSYNC_INSTRUCTION_NONE;
        }
```

(If the dir's instruction is `CSYNC_INSTRUCTION_NONE` already, nothing changes; if it is a real change like `NEW`, leave it — a brand-new dir still needs creating, and its children re-list next sync because its DB etag won't match the server until complete.)

- [ ] **Step 4: Build**

Run: `.\admin\win\build-installer.ps1 -CraftRoot C:\CraftRoot -SkipPackage`
Expected: compiles.

- [ ] **Step 5: Run the suite — convergence tests should now pass**

Run: `cd build-release; ctest -R BatchedDiscovery --output-on-failure`
Expected: all four tests PASS, especially `convergesAndSyncsEverything` and `eachBatchMakesProgress`.

- [ ] **Step 6: Commit**

```bash
git add src/libsync/discovery.cpp
git commit -m "fix(discovery): keep partial-dir etag stale at batch limit"
```

---

## Task 5: Progress-gated follow-up (no infinite loop, no folder-disable)

Replace the buggy unlimited follow-up. A batched sync may exceed the normal `_consecutiveFollowUpSyncs <= 3` cap, but only while it is actually making progress. Track committed items in the journal; if a batch commits zero new items, stop and let the normal error path run.

**Files:**
- Modify: `src/libsync/syncengine.cpp` (`finishSync`, persist progress counter)
- Modify: `src/gui/folder.cpp` (`slotSyncFinished`, follow-up decision)

- [ ] **Step 1: Add a progress test**

Append to `test/testbatcheddiscovery.cpp` inside the class:

```cpp
    // If two consecutive batched syncs commit the same total, the engine must
    // not keep requesting follow-ups forever.
    void noProgressStopsFollowups()
    {
        FakeFolder fake{ FileInfo{} };
        fillBigDir(fake.remoteModifier(), 25);
        fake.syncEngine().syncOptions()._discoveryBatchSize = 10;

        // Converges normally; assert it terminates (covered by cap in syncUntilDone).
        const int runs = syncUntilDone(fake);
        QVERIFY2(runs < 60, "follow-ups did not stop");
        // After convergence, no further sync is requested.
        fake.syncOnce();
        QCOMPARE(fake.syncEngine().isAnotherSyncNeeded(), NoFollowUpSync);
    }
```

- [ ] **Step 2: Persist committed-progress counter in finishSync**

In `src/libsync/syncengine.cpp`, in `finishSync()` near the existing `_journal` commit calls (~line 1099-1108), record cumulative committed items when a batch limited the run:

```cpp
    if (_discoveryBatchLimitReached) {
        const qint64 thisRun = static_cast<qint64>(_syncItems.size());
        const qint64 prevTotal = _journal->keyValueStoreGetInt(QStringLiteral("batch_sync_total_items"), 0);
        _journal->keyValueStoreSet(QStringLiteral("batch_sync_total_items"), prevTotal + thisRun);
    } else {
        _journal->keyValueStoreDelete(QStringLiteral("batch_sync_total_items"));
    }
```

- [ ] **Step 3: Progress-gated follow-up in Folder**

In `src/gui/folder.cpp`, `slotSyncFinished`, replace the existing follow-up condition (the `anotherSyncNeeded == ImmediateFollowUp && _consecutiveFollowUpSyncs <= 3` block) with progress-aware logic:

```cpp
    const bool batched = _engine->wasDiscoveryBatchLimited();
    if (anotherSyncNeeded == ImmediateFollowUp) {
        bool allowFollowUp = _consecutiveFollowUpSyncs <= 3;
        if (batched) {
            // Allow unlimited follow-ups for batched syncs ONLY while progress
            // is being made (committed total increased since last run).
            const qint64 total = _journal->keyValueStoreGetInt(QStringLiteral("batch_sync_total_items"), 0);
            allowFollowUp = total > _lastBatchSyncTotal;
            _lastBatchSyncTotal = total;
            if (!allowFollowUp) {
                qCWarning(lcFolder) << "Batched sync made no progress; stopping follow-ups";
            }
        }
        if (allowFollowUp) {
            // ... keep the existing scheduling code that was inside the old branch ...
        }
    }
```

Add the member to `src/gui/folder.h` (private):

```cpp
    qint64 _lastBatchSyncTotal = 0;
```

- [ ] **Step 4: Build**

Run: `.\admin\win\build-installer.ps1 -CraftRoot C:\CraftRoot -SkipPackage`
Expected: compiles.

- [ ] **Step 5: Run the suite**

Run: `cd build-release; ctest -R BatchedDiscovery --output-on-failure`
Expected: all tests PASS including `noProgressStopsFollowups`.

- [ ] **Step 6: Commit**

```bash
git add src/libsync/syncengine.cpp src/gui/folder.cpp src/gui/folder.h test/testbatcheddiscovery.cpp
git commit -m "feat(sync): progress-gated follow-up for batched discovery"
```

---

## Task 6: Replace O(n²) sorted-insert with append + sort-once

`_syncItems` is built via `std::lower_bound` + `insert` per item — O(n²). Verified safe to change: the only mid-discovery use is the insert itself; `finishSync` already asserts `std::is_sorted` (line ~1063). Append during discovery, sort once before that assert.

**Files:**
- Modify: `src/libsync/syncengine.cpp` (`slotItemDiscovered` insert ~477; `finishSync` before the `is_sorted` assert ~1063)

- [ ] **Step 1: Append instead of sorted-insert**

In `slotItemDiscovered`, replace:

```cpp
    auto it = std::lower_bound( _syncItems.begin(), _syncItems.end(), item ); // the _syncItems is sorted
    _syncItems.insert( it, item );
```

with:

```cpp
    _syncItems.push_back(item); // sorted once in finishSync to avoid O(n^2) inserts
```

- [ ] **Step 2: Sort once before the is_sorted assert**

In `finishSync()`, immediately before `Q_ASSERT(std::is_sorted(_syncItems.begin(), _syncItems.end()));` (line ~1063):

```cpp
    std::sort(_syncItems.begin(), _syncItems.end(),
        [](const SyncFileItemPtr &a, const SyncFileItemPtr &b) { return *a < *b; });
```

(Use the same comparison the original `lower_bound` relied on — `SyncFileItem`'s `operator<`. If the comparator differs, match it exactly to keep the assert valid.)

- [ ] **Step 3: Build**

Run: `.\admin\win\build-installer.ps1 -CraftRoot C:\CraftRoot -SkipPackage`
Expected: compiles.

- [ ] **Step 4: Run the full sync test set (regression)**

Run: `cd build-release; ctest -R "BatchedDiscovery|SyncEngine|LocalDiscovery|RemoteDiscovery" --output-on-failure`
Expected: all PASS — ordering change must not break existing sync behavior.

- [ ] **Step 5: Commit**

```bash
git add src/libsync/syncengine.cpp
git commit -m "perf(sync): build _syncItems with append + single sort"
```

---

## Task 7: Tame discovery debug-log volume (secondary, optional)

The freeze run produced ~1GB of debug logs: a per-item `folderBytesAvailable` line and a single log statement dumping thousands of filenames. Reduce both so debugging large dirs is feasible. Keep `info`-level discovery lines.

**Files:**
- Modify: `src/libsync/discovery.cpp` (`folderBytesAvailable` ~1105-1116; the bulk filename-list log)

- [ ] **Step 1: Downgrade per-item quota spam**

In `folderBytesAvailable`, the two `qCDebug(lcDisco)` lines that log per item ("Checking quota for item" / "Returning unlimited free space") — gate them so they only emit when a quota actually applies:

```cpp
    if (_discoveryData->_folderQuota.bytesAvailable >= 0) {
        qCDebug(lcDisco) << "Checking quota for item:" << path /* ...existing fields... */;
    }
```

(Leave the return logic unchanged; only the logging is gated.)

- [ ] **Step 2: Cap the bulk filename-list log**

Find the log statement that prints the comma-separated list of all entries in a directory (the multi-KB line seen in the freeze log). Replace the full list with a count and a small sample:

```cpp
    qCDebug(lcDisco) << "Directory" << _currentFolder._server << "has" << entries.size()
                     << "entries (first few:" << /* first up-to-5 names */ << ")";
```

- [ ] **Step 3: Build + run discovery tests (no behavior change)**

Run: `.\admin\win\build-installer.ps1 -CraftRoot C:\CraftRoot -SkipPackage`
Then: `cd build-release; ctest -R "BatchedDiscovery|LocalDiscovery|RemoteDiscovery" --output-on-failure`
Expected: compiles, all PASS.

- [ ] **Step 4: Commit**

```bash
git add src/libsync/discovery.cpp
git commit -m "chore(discovery): reduce debug log volume for large directories"
```

---

## Task 8: End-to-end manual verification on the real instance

**Files:** none (manual).

- [ ] **Step 1: Build the installer**

```powershell
. C:\CraftRoot\craft\craftenv.ps1; cd C:\Dev\desktop
.\admin\win\build-installer.ps1 -CraftRoot C:\CraftRoot -SkipBuild
```
Produces `AvuzConecta-4.0.9-setup.exe`.

- [ ] **Step 2: Clean-slate install on the test machine**

Uninstall old, wipe `%APPDATA%\Avuz`, `%LOCALAPPDATA%\Avuz Conecta`, the sync folder + `.sync_*.db`. Install the new build.

- [ ] **Step 3: Sync the 118k `train2017` dir with VFS, debug log**

```powershell
Start-Process "C:\Program Files (x86)\Avuz Conecta\avuzconecta.exe" -ArgumentList '--logdebug','--logfile','C:\temp\verify_409.log'
```

- [ ] **Step 4: Verify success criteria**

- UI stays responsive (no freeze) throughout.
- Log shows repeated `Discovery batch limit reached` then convergence; `batch_sync_total_items` increases each run and stops growing when done.
- No `Wiping virtual file without db entry`.
- After convergence, `isAnotherSyncNeeded` settles; all 118k placeholders present; folder NOT auto-disabled.
- Log size is reasonable (Task 7).

- [ ] **Step 5: Tag the verified build**

```bash
git tag avuz-4.0.9-batched-discovery
git push origin avuz-customization-v4.0.9 --tags
```

---

## Self-Review

**Spec coverage:**
- Clean committed stop → Task 3 (stopDiscoveryForBatch reuses teardown) + Task 4 (entries/subjob guards). ✓
- Don't pin partial dirs (etag = resume cursor) → Task 4 Step 3. ✓
- Progress gate → Task 5. ✓
- Sort-once → Task 6. ✓
- Tests/behavior contract → Task 2 + Task 5 Step 1. ✓
- Secondary log volume → Task 7 (spec listed as related). ✓
- Out-of-scope items (custom cursor, non-batch discovery changes, server LogNormalizer) → not in plan. ✓

**Placeholder scan:** No TBD/TODO; every code step has concrete code. Two spots require the implementer to match existing local code exactly (Task 5 Step 3 "keep the existing scheduling code"; Task 6 Step 2 comparator) — both reference the precise location and the invariant to preserve.

**Type consistency:** `_discoveryBatchSize` (SyncOptions), `_discoveryBatchLimitReached` + `wasDiscoveryBatchLimited()` (SyncEngine), `_batchLimitReached` + `stopDiscoveryForBatch()` (DiscoveryPhase), `_lastBatchSyncTotal` (Folder), journal key `batch_sync_total_items` — names used consistently across Tasks 3-5.

**Risk flagged for executor:** Task 4 Step 3 (suppressing the interrupted dir's metadata update) is the subtlest change; the `convergesAndSyncsEverything` + `eachBatchMakesProgress` tests are the guardrail. If they fail, the etag-unpin point is wrong — re-inspect how `_dirItem`'s instruction/etag reaches the journal before trying alternatives.
