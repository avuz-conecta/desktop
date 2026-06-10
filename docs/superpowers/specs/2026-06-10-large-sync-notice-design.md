# Large-Sync Notice — Design

Date: 2026-06-10
Status: approved design, pending implementation
Branch: `avuz-customization-v4.0.9`

## Context

After the performance work this session, the desktop client syncs very large
folders (100k+ files) correctly and with a responsive GUI, but the initial bulk
sync still has short periodic "lag then release" bursts (inherent CfApi
placeholder-creation + per-item DB work, now chunked to 250/turn). For an
extreme one-time onboarding (e.g. 142k files in one directory) this can read as
"the app is broken" even though it is working.

Industry-standard mitigation: show a non-blocking notice that sets expectations
during a large sync ("this may take a while / the app may be slower"). This
spec covers that notice. It does NOT change sync behavior.

Most end users of this fork are Brazilian, so a pt-BR translation is a required
deliverable, not an afterthought.

## Requirements

- Show an informational notice in the tray while the current sync is "large".
- "Large" = the current sync has more than a threshold number of items.
  - Threshold default: **20000**. Overridable via env var
    `OWNCLOUD_LARGE_SYNC_NOTICE_THRESHOLD` (for tuning without a rebuild).
- Trigger on **any** sync over the threshold (initial or later), not just the
  first sync. No persisted "first sync" state.
- The notice is **non-modal, non-dismissable, self-clearing**: it appears when a
  sync crosses the threshold and disappears when that sync finishes (or its item
  count drops below the threshold). It blocks nothing.
- English source string + **pt-BR translation** shipped.

## Design

### 1. Trigger — `SyncStatusSummary` (C++, `src/gui/tray/syncstatussummary.{h,cpp}`)

This model already backs the tray sync display and tracks `_totalFiles`
(total items in the current sync) and a `syncing` state.

- Add a threshold read once at construction:
  `_largeSyncThreshold = qEnvironmentVariableIntValue("OWNCLOUD_LARGE_SYNC_NOTICE_THRESHOLD")`,
  falling back to `20000` when unset/<=0.
- Add `Q_PROPERTY(bool largeSyncInProgress READ largeSyncInProgress NOTIFY largeSyncInProgressChanged)`.
- `largeSyncInProgress()` returns `syncing() && _totalFiles > _largeSyncThreshold`.
- Emit `largeSyncInProgressChanged()` from the same places that already update
  `syncing`/`_totalFiles` (the existing `setSyncing(...)` and `setTotalFiles(...)`
  setters), only when the derived value actually changes (cache the last emitted
  bool to avoid signal spam).
- Purely derived state — no new storage, no engine changes.

### 2. UI — `SyncStatus.qml` (`src/gui/tray/SyncStatus.qml`)

- Add a small notice row below the existing status line: an info icon + a
  wrapping `Label`, with `visible: syncStatus.largeSyncInProgress`
  (`syncStatus` is the existing model alias in this file).
- Text via `qsTr(...)`:
  `"Syncing thousands of files — the app may be slow during the sync."`
- Style: muted/secondary text consistent with the existing tray styling
  (`Style` constants already used in this file). No new colors invented.

### 3. Translation — `translations/client_pt_BR.ts`

- Add a `<message>` under the `SyncStatus` context with:
  - source: the exact English string above
  - translation:
    `"Sync de milhares de arquivos, o aplicativo pode ficar lento durante o sync"`
- The build already globs `translations/client_*.ts` and compiles to `.qm`
  (CMakeLists.txt:345); the fork forces pt-BR via `AvuzTheme`, so the string is
  picked up automatically once present.

## Out of scope (YAGNI)

- System/OS toast notifications.
- "First sync only" detection / persisted per-folder state.
- A dismiss button or user preference to hide it.
- Any change to sync/discovery/propagation behavior.

## Testing

- **Unit (headless, mac):** a small test on `SyncStatusSummary` —
  set `syncing=true` + `_totalFiles` below/above the threshold and assert
  `largeSyncInProgress` flips correctly and emits `largeSyncInProgressChanged`
  exactly on transitions; assert it is false when `syncing=false` regardless of
  count. (Use the existing setters; if they are private, drive them through the
  same `ProgressInfo`/sync-status path the tests already use, or add a
  test-only friend/hook consistent with existing test patterns.)
- **Manual (Windows):** start a >20k sync, confirm the notice appears in the
  tray during the sync and disappears when it finishes; confirm pt-BR text under
  the enforced locale.

## Risks / open questions

- `SyncStatusSummary` setters' exact names/visibility — confirm at
  implementation time and hook the signal emission there.
- QML `qsTr` context name must match the `.ts` `<context><name>` (the QML file
  base name, `SyncStatus`) for the pt-BR string to resolve.
