# Batched Discovery Fix — Design

Date: 2026-06-07
Status: approved design, pending implementation
Branch base: fork `avuz-customization-v4.0.3` (Avuz Conecta, NC desktop fork)

## Context

Avuz Conecta (NC desktop fork) cannot sync large folders (e.g. COCO `train2017`, ~118k files in one flat dir) against the branded instance `conectahmls32.avuz.app` (Nextcloud v33, S3 primary storage, behind Cloudflare → NPM → docker nginx+php-fpm).

Two distinct problems were conflated as "can't sync huge data":

1. **Server PROPFIND timeout (FIXED, server-side).** Listing the 118k-file dir exceeded a ~25-30s timeout → reverse proxy returned **504 Gateway Timeout** → discovery errored → endless follow-up. Fixed by raising php `request_terminate_timeout`/`max_execution_time` to 3600 and NPM `proxy_read_timeout` to 3600. (Cloudflare 100s cap is the next ceiling; durable fix = warm `oc_filecache`.) NOT an S3 rate limit — desktop discovery reads `oc_filecache`, not S3.

2. **Client-side scaling failure on the full change-set (the subject of this spec).** Even with the 504 gone, the client cannot process the whole change-set at once.

## What we proved (evidence)

From debug logs of a batched run (`OWNCLOUD_DISCOVERY_BATCH_SIZE=2000`):

- **Zero real per-file/server errors.** `INSTRUCTION_ERROR: 0`, no 4xx/5xx on files.
- **1649× `Wiping virtual file without db entry`** (discovery.cpp:1490) after ~1843 placeholders created. Each cycle: create placeholders → unclean batch stop → DB records NOT committed → next sync sees on-disk placeholders with no DB entry → **wipes them** → recreates → wipes → infinite churn, zero net progress. This is the user-observed "starts from 0 even with files already mapped."
- Earlier: unclean stop marks syncs failed → "too many synchronization errors" → folder **auto-disabled**.
- batch=0 + VFS on 118k → **hard UI freeze** (app not responding). Confirms the client genuinely needs work-chunking; VFS alone does not save it.

### Current batch implementation bugs (commits dbffc2e959, 65d4b15396)
- `DiscoveryPhase::stopDiscoveryAndFinish` emits `finished` via a **bypass** (`QMetaObject::invokeMethod(..., Qt::QueuedConnection)`) instead of the normal teardown (discoveryphase.cpp:277-292) → `_currentRootJob` never nulled, in-flight `LsColJob` PROPFINDs never aborted, sync ends in an unclean/failed state → records not committed.
- folder.cpp:1334 removed the `_consecutiveFollowUpSyncs <= 3` cap for batched syncs → **unlimited follow-ups**, no brake.
- No resume mechanism; re-discovers from root each follow-up.
- Partial-dir etag pinning risk (discovery.cpp:868 `ParentNotChanged`) → silent missing files.
- `_syncItems` sorted-insert via `std::lower_bound`+`insert` (syncengine.cpp:494) = **O(n²)** within a batch.

## Community check (upstream)

- Large-folder freeze is long-standing and **still open** upstream: nextcloud/desktop #6792 (open), #9275 (open, >100k files), #691.
- Upstream has **no** client-side batched/chunked discovery; no PR to adopt. Our batching is novel → permanent fork divergence (rebase burden).
- #9279 (infinite loop on large + external storage) closed as fixed by **server v33** + VFS, not client changes. Users report v33 + client **4.0.6** + VFS syncing 600k files fine.
- Our fork is **v4.0.3**, missing relevant client fixes: 4.0.4 #9215 (inode/local-DB consistency), 4.0.5 #9258 ("crash when too many sync errors occurred" — our exact disable path). Server is already v33.

## Decision

**Rebase the fork onto upstream v4.0.6, then reimplement batching cleanly.**

### Phase 0 — Rebase to v4.0.6
- 24 custom commits: 22 isolated branding/installer/theme (mostly new files, low conflict) + 2 buggy batch commits (the two most recent).
- Drop the 2 batch commits by rebasing the commit below them:
  `git fetch upstream --tags && git branch backup/avuz-v4.0.3-pre-rebase && git rebase --onto v4.0.6 v4.0.3 76c9a61893`
- No interactive rebase (env restriction); batch commits are left behind by construction.

### Phase 0.5 — Re-validate baseline (checkpoint, may cancel Phase 1)
Build → clean slate (client config + sync folder + `.sync_*.db`) → VFS → sync the 118k dir on the v33 server. If it works like upstream's 600k report, custom batching may be unnecessary — reassess before building. If it still freezes, proceed.

### Phase 1 — Batching design (Option A: keep batching, fix it)

Insight: **etag state IS the resume cursor.** NC already skips unchanged dirs via etag (`ParentNotChanged`). If each batch commits cleanly and partially-discovered dirs are left unpinned, native etag-skip resumes automatically — no custom cursor needed.

Four parts:

1. **Clean committed stop (cornerstone).** When the batch limit is hit, stop discovery via the *normal* teardown (null `_currentRootJob`, `deleteLater` the job tree, abort in-flight `LsColJob`s) and let the sync finish as a **success** so propagation runs and journal records commit for the batch. Route through the existing success path (syncengine.cpp finishSync → propagator per-item `setFileRecord` → `commit("All Finished")`).

2. **Do not pin partial dirs (prevents data loss + enables resume).** Any directory whose children were cut off by the batch limit must NOT get its etag written to the DB. Left stale → re-listed next sync → remaining children discovered. Fully-completed dirs commit normally. This is the core new logic.

3. **Progress gate (kills the infinite loop).** Track committed-new-items per batch. Schedule a follow-up only if `progress > 0`. Zero progress → stop and surface a real error instead of looping (no more folder auto-disable).

4. **Sort-once (bonus, verified safe).** `_syncItems`: append O(1) during discovery, `std::sort` once before `finishSync`. Verified the only mid-discovery consumer is the insert itself; line 1078 already `Q_ASSERT(std::is_sorted(...))`, so sort before that. Removes the O(n²) within each batch.

#### What this fixes
- `Wiping virtual file without db entry` churn → records commit.
- Infinite follow-ups / folder-disable → progress gate.
- Silent missing files → no etag pinning.
- Per-batch CPU → O(n log n).

## Out of scope (YAGNI)
- Custom resume cursor (etag state replaces it).
- Changing non-batch discovery behavior.
- Memory ceiling beyond what the batch cap already provides.
- Server LogNormalizer bug (`occ files:scan` crash) — separate server-image issue, tracked elsewhere.

## Testing strategy
- Behavior tests, not implementation. Reproduce on a synthetic large tree (or a fixture mirroring the >batch-size flat dir).
- Assert: across follow-up syncs, committed item count **monotonically increases** and converges; no `Wiping virtual file without db entry`; follow-ups stop when complete; a partially-discovered dir is re-listed (not etag-skipped) until fully done; no silent missing files vs server listing.
- Regression: normal (sub-batch) syncs unaffected.

## Risks / open questions
- Exact hook point to mark a dir "incomplete" so its etag isn't written (Phase 1 part 2) — needs code-level design in the plan.
- Confirm clean teardown of `DiscoveryPhase` doesn't drop already-discovered (committable) items.
- Fork divergence from upstream — document the batching patch clearly for future rebases.
