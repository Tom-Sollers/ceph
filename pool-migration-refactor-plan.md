# Pool Migration Refactor Plan

## Top-Level Overview

The pool migration code added to `OSDMonitor` has several correctness bugs stemming from one root cause: **mixing `osdmap.pools` (the committed map) with `pending_inc.new_pools` (the pending increment) without consistently going through the helper functions that correctly layer pending changes on top of the committed map.**

There are also a number of secondary bugs: a double-declaration compile error in `prepare_pg_migrated_pool`, a shadow-variable that causes incorrect behavior in the "pool complete" branch, incorrect handling of `pending_inc.old_pools` (deleted pools) in several places, and a truncated pool-delete section that was mid-edit.

The refactor must **not** change observable migration behaviour — it corrects the implementation so it behaves as already intended while being safe against mid-migration pool deletions.

---

## Helper Contract (background for all sub-tasks)

`OSDMonitor` owns two layered helpers that correctly hide the pending increment:

| Helper | What it checks |
|---|---|
| `have_pg_pool(id)` | Returns false if `pending_inc.old_pools` contains the id (deletion pending), true if `pending_inc.new_pools` contains it, otherwise delegates to `osdmap.have_pg_pool`. |
| `get_pg_pool(id)` (const) | Returns the `pending_inc.new_pools` version if present, otherwise falls back to `osdmap.get_pg_pool`. Never mutates. |
| `get_pg_pool(id)` (mutable) | Copies from `osdmap` into `pending_inc.new_pools` if not already staged, then returns a mutable reference to the staged entry. |

All migration code **must** use these helpers instead of going directly to `osdmap.get_pools()`, `osdmap.get_pg_pool()`, etc.

---

## Sub-Tasks

---

### Sub-Task 1 — Fix compile error: duplicate `source_p` declaration in `prepare_pg_migrated_pool`

**Status:** `[ ] pending`

**Intent**  
There is a ghost `pg_pool_t source_p;` declaration on line 4290 followed immediately by `pg_pool_t source_p = get_pg_pool(...)` on line 4295. This is a redefinition in the same scope and will not compile. The uninitialised first declaration must be removed.

**Expected Outcomes**
- One declaration of `source_p` in `prepare_pg_migrated_pool`, initialised from `get_pg_pool`.
- Code compiles without error.

**Todo List**
1. Delete line 4290 (`pg_pool_t source_p;`).

**Relevant Context**
- [`OSDMonitor::prepare_pg_migrated_pool`](src/mon/OSDMonitor.cc:4285)
- Lines 4290 and 4295.

---

### Sub-Task 2 — Fix shadow variable and double-write bug in `prepare_pg_migrated_pool` (migration complete branch)

**Status:** `[ ] pending`

**Intent**  
When a pool migration completes (lines 4311–4322), the code does:

```cpp
pg_pool_t target_p = get_pg_pool(...)  // outer copy, line 4308 — value copy, NOT mutable ref
...
if (source_p.lowest_migrated_pg == 0 && source_p.migrating_pgs.empty()) {
    pg_pool_t& target_p = get_pg_pool(...)  // inner mutable ref, line 4313 — SHADOWS outer
    target_p.unset_flag(...)
    ...
    pending_inc.new_pools[...] = target_p;  // line 4322 — unnecessary, get_pg_pool mutable already staged it
```

Two problems:
1. The outer `target_p` on line 4308 is a value copy from `get_pg_pool` (const overload), so any changes to it are silently discarded. The inner shadow declaration on line 4313 was added to work around this, but it causes confusion.
2. Line 4322 manually writes `target_p` back to `pending_inc.new_pools` even though the mutable `get_pg_pool` already staged it. This is harmless but misleading.

Also, in the `else` branch (lines 4325–4343), `target_p` refers to the outer value copy on line 4308 — which is stale if any earlier code in the same prepare cycle already modified the target pool via `get_pg_pool` (mutable). This could cause a read-your-own-writes hazard.

Fix: remove the outer value copy on line 4308, keep only the inner mutable reference in the completion branch, and obtain the target pool via the mutable `get_pg_pool` in the scheduling branch too (or simply use `const` reference for read-only access in scheduling).

**Expected Outcomes**
- Single, unambiguous variable `target_p` that is always obtained via `get_pg_pool` (using the appropriate const/mutable overload for the access pattern).
- No redundant write-back to `pending_inc.new_pools`.
- No stale snapshot of target pool in the scheduling branch.

**Todo List**
1. Remove the outer value copy `pg_pool_t target_p = get_pg_pool(...)` (line 4308).
2. In the migration-complete branch, keep (or rename for clarity) the inner `get_pg_pool` mutable reference.
3. Remove the now-redundant explicit `pending_inc.new_pools[...] = target_p` write-back on line 4322 (since mutable `get_pg_pool` stages it automatically).
4. In the scheduling `else` branch, obtain a fresh `const` reference via `get_pg_pool` (const overload) for read access to target's pg_num.

**Relevant Context**
- [`prepare_pg_migrated_pool`](src/mon/OSDMonitor.cc:4285) — lines 4308–4347.

---

### Sub-Task 3 — Fix `preprocess_pg_migrated_pool`: reads from `osdmap` not pending state

**Status:** `[ ] pending`

**Intent**  
`preprocess_pg_migrated_pool` reads pool state directly via `have_pg_pool` and `get_pg_pool` which go through the pending layer — this is correct — but on line 4265 it calls `get_pg_pool` which returns a **value copy** (`pg_pool_t pi = get_pg_pool(...)`). The migration state checked on line 4272 (`pi.migrating_pgs.contains(...)`) may be stale if pending changes have been made but not yet committed. This is a race condition specific to having multiple operations in one batch.

In addition, `preprocess_*` functions run before a proposal is committed; the intent of preprocess is to quickly drop duplicates. It should use the committed `osdmap` state only (not pending), or clearly use the helper. Currently line 4265 uses the helper correctly. However the function should be documented to clarify which view it is operating on.

This sub-task audits and documents the preprocess function to ensure it is consistently using the right view, and adds a comment explaining why this is safe/correct.

**Expected Outcomes**
- Clear comment in `preprocess_pg_migrated_pool` explaining that it reads from the helper layer (pending-aware).
- No accidental direct `osdmap.*` calls in the preprocess function.

**Todo List**
1. Review all pool-state reads in `preprocess_pg_migrated_pool` and replace any direct `osdmap.have_pg_pool` / `osdmap.get_pg_pool` calls with the `have_pg_pool` / `get_pg_pool` helpers.
2. Add a brief comment explaining the read source.

**Relevant Context**
- [`preprocess_pg_migrated_pool`](src/mon/OSDMonitor.cc:4243) — lines 4243–4282.

---

### Sub-Task 4 — Fix `insert_new_removed_snap`: reads from `osdmap` bypassing pending state

**Status:** `[ ] pending`

**Intent**  
`insert_new_removed_snap` (line 4400) calls `have_pg_pool` and `get_pg_pool` (helpers, correct) on line 4402 and 4408. So the outer pool lookup is fine. But on line 4422, when it reads the `target_pi` it also uses the helper (`get_pg_pool`), which is correct.

However, the logic does **not** handle the case where the target pool is *being deleted* in the same pending batch (`pending_inc.old_pools`). The `have_pg_pool` helper already handles that on line 4413, so pool existence is guarded. This appears correct.

One remaining issue: when `target_pi.migration_src` is set (line 4423), the code reads `source_pool = target_pi.migration_src.value()` and then checks `have_pg_pool(source_pool)`. But it does not verify that `source_pool`'s current `migration_target` still points to `target_pool`. This matters if there was a cascade rerouting (as done in `prepare_new_pool` line 8626). The snap should only be trimmed on the source if it is still the active source.

**Expected Outcomes**
- Snap trimming on the source pool is gated on the source pool's `migration_target` still pointing back to the target (confirming it is still the active migration pair, not a stale pointer after a cascade reroute).

**Todo List**
1. In `insert_new_removed_snap`, when propagating the snap removal to the source pool (lines 4423–4429), add a check that `get_pg_pool(source_pool).migration_target == target_pool` before inserting into `new_removed_snaps[source_pool]`.

**Relevant Context**
- [`insert_new_removed_snap`](src/mon/OSDMonitor.cc:4400) — lines 4400–4435.

---

### Sub-Task 5 — Fix `prepare_new_pool` transitive migration: iterates `osdmap.get_pools()` without checking pending state

**Status:** `[ ] pending`

**Intent**  
The transitive migration pointer update loop in `prepare_new_pool` (lines 8621–8631) iterates `osdmap.get_pools()` to find any pool whose `migration_target` points to the source pool. However:

1. `osdmap.get_pools()` only returns **committed** pools. If a new pool was added earlier in the same pending batch (in `pending_inc.new_pools` but not yet in `osdmap`), it will be missed.
2. For each matching pool it calls `const pg_pool_t& current = get_pg_pool(pool_id)` (const, correct for read) and then immediately calls mutable `pg_pool_t& temp_pool = get_pg_pool(pool_id)` (mutable). The first call can be dropped since the mutable call returns the same pending state.
3. The `have_pg_pool(pool_id)` guard is present, but iterating only `osdmap.get_pools()` misses pools newly created in the current proposal.

Fix: Change the iteration to also cover `pending_inc.new_pools` entries, or build a combined view. Since transitive cascades involving a pool created in the same proposal are an edge case, at minimum add a comment explaining this limitation. Better: iterate both `osdmap.get_pools()` and `pending_inc.new_pools` (deduplicated, old_pools excluded).

**Expected Outcomes**
- The cascade pointer update loop visits all pools that exist or will exist after this proposal, not just committed pools.
- Duplicate const+mutable `get_pg_pool` call is collapsed to a single mutable call.

**Todo List**
1. Build a combined pool ID set from `osdmap.get_pools()` keys plus `pending_inc.new_pools` keys, minus `pending_inc.old_pools`.
2. Replace the `osdmap.get_pools()` iteration loop with an iteration over this combined set.
3. Remove the redundant const `get_pg_pool` call; use only the mutable overload in the loop body.

**Relevant Context**
- [`prepare_new_pool`](src/mon/OSDMonitor.cc:8618) — lines 8618–8632.

---

### Sub-Task 6 — Fix and complete the truncated pool-delete migration section

**Status:** `[ ] pending`

**Intent**  
The `osd pool delete`/`osd pool rm` handler at line 14326 is truncated mid-line at:

```cpp
if (current_pool->is_migrating()) {
    target_pool = c  // <<< truncated
```

This needs to be completed correctly. Based on the design intent (redirect pool deletion to the migration target, as commented on lines 14329–14330), the logic should:

1. If the pool being deleted is a **migration source** (`is_migration_src()` — i.e., `migration_target` is set), redirect deletion to the target pool's ID. This is because the target pool is the "live" destination; deleting the source during migration should cancel the migration and clean up.
2. If the pool being deleted is a **migration target** (`is_migration_target()` — i.e., `migration_src` is set), we need to also clean up the source pool's migration state (`migration_target.reset()`, `migrating_pgs.clear()`).
3. In either case the pool being asked for deletion should be checked in `pending_inc.old_pools` too (use `have_pg_pool` not direct `osdmap` call).

The code currently reads `current_pool = osdmap.get_pg_pool(pool)` directly from osdmap (not the helper). This should use the helper layer in case the pool state has been modified in the current pending batch.

**Expected Outcomes**
- Pool delete correctly completes its logic whether the pool is a migration source or target.
- Migration state is cleaned up on the partner pool when a migration-participating pool is deleted.
- Direct `osdmap.get_pg_pool` call replaced with `have_pg_pool` / `get_pg_pool` helper call.
- File is no longer truncated; all braces and logic are closed correctly.

**Todo List**
1. Restore the truncated line and complete the if-block, following the design intent in the comments.
2. Handle the source-pool-deleted case: clear `migration_target`, `migrating_pgs`, and `lowest_migrated_pg` on the source pool (via `get_pg_pool` mutable helper staged into `pending_inc`).
3. Handle the target-pool-deleted case: clear `migration_src` on the source pool.
4. Replace `osdmap.get_pg_pool(pool)` on line 14326 with the `get_pg_pool` helper.
5. Ensure all pool existence checks use `have_pg_pool` (not `osdmap.have_pg_pool`).

**Relevant Context**
- Pool delete section: [`OSDMonitor.cc:14313`](src/mon/OSDMonitor.cc:14313)
- `is_migration_src()`, `is_migration_target()` methods in [`osd_types.h:1687-1688`](src/osd/osd_types.h:1687).

---

## Cross-Cutting Concerns

- After all sub-tasks, do a final grep pass for any remaining direct `osdmap.get_pg_pool` / `osdmap.have_pg_pool` calls within migration-specific code paths to confirm all have been migrated to helpers.
- Verify `preprocess_pg_migrated_pool` and `prepare_pg_migrated_pool` both correctly guard against `pending_inc.old_pools` (pool deleted in same batch).
