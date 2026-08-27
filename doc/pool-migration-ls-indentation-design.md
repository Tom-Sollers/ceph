# `ceph osd pool ls detail --show-migration-chain` — Indentation Design

## The core idea

Use indentation to show where each pool sits in the migration journey:

- **Root pool** — no indent. This is where the data started.
- **Intermediate stub pools** — one level of indent (4 spaces). All stubs sit at the same depth
  regardless of how many there are. They are completed hops — data has already left them.
- **Active pool (tip)** — two levels of indent (8 spaces). This is the current destination for all
  I/O. Its deeper indent makes it instantly stand out as "the end of the line".

Per-pool sub-fields (migration role, status, progress, snaps) are always indented one level
**deeper** than their owning pool line, exactly as today's snap/removed_snaps lines already are.

This gives a visual shape that reads naturally top-to-bottom as the migration journey, with the
active pool clearly "furthest along":

```
pool 0  'mypool'       ...   (root — no indent)
    pool 1  'mypool_v2'    ...   (stub — 1 level)
    pool 2  'mypool_v3'    ...   (stub — 1 level)
        pool 3  'mypool_v4'    ...   [ACTIVE]   (tip — 2 levels)
```

Separate chains are separated by a blank line and a chain header. Standalone (non-migrating)
pools are printed after all chains, exactly as today.

---

## Scenario

Two independent chains plus one standalone pool:

```
Chain A:  1 (mypool) -> 2 (mypool_v2) -> 3 (mypool_v3) -> 4 (mypool_v4)   [active]
Chain B:  5 (volumes) -> 6 (volumes_ec)                                     [active]
Standalone: 7 (images)
```

- 1 → 2: complete
- 2 → 3: complete
- 3 → 4: in_progress (49/128 PGs migrating)
- 5 → 6: in_progress (12/64 PGs migrating)

---

## Plain text output

```
migration chain (root_pool_id 1, active_pool_id 4):
pool 1 [root]   'mypool'     replicated size 3 min_size 2 crush_rule 0 object_hash rjenkins pg_num 128 pgp_num 128 last_change 42 flags hashpspool stripe_width 0 application rbd
    migration_target 2  migration_status complete  progress 100%
    snap 1 'mysnap' 2024-01-01 00:00:00.000000
    pool 2 [stub]   'mypool_v2'  replicated size 3 min_size 2 crush_rule 1 object_hash rjenkins pg_num 128 pgp_num 128 last_change 67 flags hashpspool stripe_width 0 application rbd
        migration_src 1  migration_target 3  migration_status complete  progress 100%
    pool 3 [stub]   'mypool_v3'  replicated size 3 min_size 2 crush_rule 1 object_hash rjenkins pg_num 128 pgp_num 128 last_change 89 flags hashpspool stripe_width 0 application rbd
        migration_src 2  migration_target 4  migration_status complete  progress 100%
        pool 4 [active] 'mypool_v4'  replicated size 3 min_size 2 crush_rule 2 object_hash rjenkins pg_num 128 pgp_num 128 last_change 104 flags hashpspool stripe_width 0 application rbd
            migration_src 3  migration_status in_progress  progress 62%  migrating_pgs 49/128

migration chain (root_pool_id 5, active_pool_id 6):
pool 5 [root]   'volumes'    replicated size 3 min_size 2 crush_rule 0 object_hash rjenkins pg_num 64 pgp_num 64 last_change 55 flags hashpspool stripe_width 0 application rbd
    migration_target 6  migration_status in_progress  progress 81%  migrating_pgs 12/64
        pool 6 [active] 'volumes_ec' erasure profile default ec_data_shard_count 4 ec_coding_shard_count 2 size 6 min_size 5 crush_rule 3 object_hash rjenkins pg_num 64 pgp_num 64 last_change 98 flags hashpspool stripe_width 4096 application rbd
            migration_src 5  migration_status in_progress  progress 81%  migrating_pgs 12/64

pool 7 'images' replicated size 3 min_size 2 crush_rule 0 object_hash rjenkins pg_num 32 pgp_num 32 last_change 10 flags hashpspool stripe_width 0 application rbd
```

### Role labels and indentation rules

The role label is placed between `pool <id>` and `'<name>'` — it sits right on the pool line,
so it is visible without reading any sub-fields at all.  The label is fixed-width and
bracket-wrapped so it doesn't break the existing pattern of `pool <id> '<name>' <detail>`:

```
pool <id> [root]   '<name>' <pg_pool_t detail...>
pool <id> [stub]   '<name>' <pg_pool_t detail...>
pool <id> [active] '<name>' <pg_pool_t detail...>
pool <id> '<name>' <pg_pool_t detail...>           (standalone — no label)
```

`[root]` and `[stub]` are padded to the same width as `[active]` with a trailing space so the
pool names align in the common case.

| Pool role | Label | Pool line indent | Sub-field indent |
|---|---|---|---|
| Root | `[root]  ` | 0 spaces | 4 spaces |
| Stub (intermediate) | `[stub]  ` | 4 spaces | 8 spaces |
| Active (tip) | `[active]` | 8 spaces | 12 spaces |
| Standalone (no migration) | _(none)_ | 0 spaces | 4 spaces (snaps etc.) |

The chain header line (`migration chain (root_pool_id N, active_pool_id M):`) sits at 0 indent
and introduces each chain block. A blank line separates chains from each other and from standalone
pools.

### Why stubs are all at 4 spaces (not stepped)

The alternative would be to step each hop one level deeper than the last:

```
pool 1 ...       (root)
    pool 2 ...   (hop 1)
        pool 3 ...   (hop 2)
            pool 4 ...   (active)
```

This looks clean for short chains but becomes unreadable for longer ones — a 6-hop chain would
have the active pool at 24 spaces of indent, and the pool detail line (which is already ~100
characters long) would wrap badly on any terminal.

Keeping all stubs at one level and only the active pool at two levels solves this: no matter how
many hops there are, the active pool is always exactly 8 spaces in, and the output never wraps
due to indentation alone.

The role labels reinforce this even further: you can scan for `[active]` in any output and
immediately find the acting pool without needing to understand the indentation at all. This also
makes `grep '\[active\]'` a useful one-liner for scripting.

---

## JSON output

JSON does not have visual indentation, so the concept maps to a `migration_role` field and a
`chain_depth` integer that encodes the same information:

| Pool role | `migration_role` | `chain_depth` |
|---|---|---|
| Root | `"root"` | `0` |
| Stub (intermediate) | `"stub"` | `1` |
| Active (tip) | `"active"` | `2` |
| Standalone | `null` | `null` |

Each chain is a top-level object in a `migration_chains` array. Each chain object contains a
`pools` array ordered root → active. Every pool entry carries the full `pg_pool_t` fields plus
the migration annotation fields. Standalone pools are in a separate `pools` array at the root.

```json
{
  "migration_chains": [
    {
      "chain_id": 1,
      "root_pool_id": 1,
      "active_pool_id": 4,
      "active_pool_name": "mypool_v4",
      "total_pools": 4,
      "pools": [
        {
          "pool_id": 1,
          "pool_name": "mypool",
          "migration_role": "root",
          "chain_depth": 0,
          "migration_target": 2,
          "migration_status": "complete",
          "progress_pct": 100,
          "migrating_pgs": 0,
          "is_active_pool": false,
          "type": 1,
          "size": 3,
          "min_size": 2,
          "crush_rule": 0,
          "pg_num": 128,
          "pg_placement_num": 128,
          "flags_names": "hashpspool",
          "stripe_width": 0,
          "application_metadata": { "rbd": {} }
        },
        {
          "pool_id": 2,
          "pool_name": "mypool_v2",
          "migration_role": "stub",
          "chain_depth": 1,
          "migration_src": 1,
          "migration_target": 3,
          "migration_status": "complete",
          "progress_pct": 100,
          "migrating_pgs": 0,
          "is_active_pool": false,
          "type": 1,
          "size": 3,
          "min_size": 2,
          "crush_rule": 1,
          "pg_num": 128,
          "pg_placement_num": 128,
          "flags_names": "hashpspool",
          "stripe_width": 0,
          "application_metadata": { "rbd": {} }
        },
        {
          "pool_id": 3,
          "pool_name": "mypool_v3",
          "migration_role": "stub",
          "chain_depth": 1,
          "migration_src": 2,
          "migration_target": 4,
          "migration_status": "complete",
          "progress_pct": 100,
          "migrating_pgs": 0,
          "is_active_pool": false,
          "type": 1,
          "size": 3,
          "min_size": 2,
          "crush_rule": 1,
          "pg_num": 128,
          "pg_placement_num": 128,
          "flags_names": "hashpspool",
          "stripe_width": 0,
          "application_metadata": { "rbd": {} }
        },
        {
          "pool_id": 4,
          "pool_name": "mypool_v4",
          "migration_role": "active",
          "chain_depth": 2,
          "migration_src": 3,
          "migration_status": "in_progress",
          "progress_pct": 62,
          "migrating_pgs": 49,
          "is_active_pool": true,
          "type": 1,
          "size": 3,
          "min_size": 2,
          "crush_rule": 2,
          "pg_num": 128,
          "pg_placement_num": 128,
          "flags_names": "hashpspool",
          "stripe_width": 0,
          "application_metadata": { "rbd": {} }
        }
      ]
    },
    {
      "chain_id": 5,
      "root_pool_id": 5,
      "active_pool_id": 6,
      "active_pool_name": "volumes_ec",
      "total_pools": 2,
      "pools": [
        {
          "pool_id": 5,
          "pool_name": "volumes",
          "migration_role": "root",
          "chain_depth": 0,
          "migration_target": 6,
          "migration_status": "in_progress",
          "progress_pct": 81,
          "migrating_pgs": 12,
          "is_active_pool": false,
          "type": 1,
          "size": 3,
          "min_size": 2,
          "crush_rule": 0,
          "pg_num": 64,
          "pg_placement_num": 64,
          "flags_names": "hashpspool",
          "stripe_width": 0,
          "application_metadata": { "rbd": {} }
        },
        {
          "pool_id": 6,
          "pool_name": "volumes_ec",
          "migration_role": "active",
          "chain_depth": 2,
          "migration_src": 5,
          "migration_status": "in_progress",
          "progress_pct": 81,
          "migrating_pgs": 12,
          "is_active_pool": true,
          "type": 2,
          "erasure_code_profile": "default",
          "ec_data_shard_count": 4,
          "ec_coding_shard_count": 2,
          "size": 6,
          "min_size": 5,
          "crush_rule": 3,
          "pg_num": 64,
          "pg_placement_num": 64,
          "flags_names": "hashpspool",
          "stripe_width": 4096,
          "application_metadata": { "rbd": {} }
        }
      ]
    }
  ],
  "pools": [
    {
      "pool_id": 7,
      "pool_name": "images",
      "type": 1,
      "size": 3,
      "min_size": 2,
      "crush_rule": 0,
      "pg_num": 32,
      "pg_placement_num": 32,
      "flags_names": "hashpspool",
      "stripe_width": 0,
      "application_metadata": { "rbd": {} }
    }
  ]
}
```

### Note on the two-root-key JSON shape

The JSON has `migration_chains` and `pools` at the root. This is a deliberate break from the
plain `.pools[]` root. The reason: merging chains and standalone pools into a single array
requires mixed entry shapes (`entry_type: "chain"` vs `entry_type: "pool"`) which is harder to
consume. The two-key shape means:

- `jq '.pools[]'` — all standalone pools, same as today without the flag
- `jq '.migration_chains[]'` — all chains
- `jq '.migration_chains[].pools[] | select(.is_active_pool)'` — just the active pool of every chain
- `jq '.migration_chains[].pools[] | select(.migration_role == "stub")'` — all stubs across all chains

This is only emitted when `--show-migration-chain` is used. Without the flag the output is the
existing flat `.pools[]` array and is unchanged.

---

## Edge cases

### Single-hop chain (root + active, no stubs)

```
migration chain (root_pool_id 5, active_pool_id 6):
pool 5 [root]   'volumes'    replicated size 3 min_size 2 crush_rule 0 object_hash rjenkins pg_num 64 pgp_num 64 last_change 55 flags hashpspool stripe_width 0 application rbd
    migration_target 6  migration_status in_progress  progress 81%  migrating_pgs 12/64
        pool 6 [active] 'volumes_ec' erasure profile default ec_data_shard_count 4 ec_coding_shard_count 2 size 6 min_size 5 crush_rule 3 object_hash rjenkins pg_num 64 pgp_num 64 last_change 98 flags hashpspool stripe_width 4096 application rbd
            migration_src 5  migration_status in_progress  progress 81%  migrating_pgs 12/64
```

Root at 0, no stubs, active at 8. The jump from 0 to 8 is intentional — it makes the active pool
stand out even in a two-pool chain. `chain_depth` in JSON is still `0` for root and `2` for
active.

### Migration complete (all PGs moved, stubs only, no active hop yet assigned)

If for some reason the active pool's migration is fully complete and the chain has not yet been
collapsed, the active pool still shows `[active]` with `progress 100%`. This is correct —
the pool is still the acting pool until the chain is torn down.

### All pools in a chain are stubs (chain fully complete, pending cleanup)

These pools all have `migration_target` set and `migrating_pgs` empty. The tip has no
`migration_target` and is shown as active. Same output structure, status = `complete` on all hops.

---

## Implementation sketch

### Plain text path — `OSDMap::print_pools()`

[`src/osd/OSDMap.cc:4423`](../src/osd/OSDMap.cc) currently skips `is_migration_src()` pools.
With `--show-migration-chain`:

1. Before the pool loop, build a `map<int64_t, vector<int64_t>>` of chains keyed by root pool ID.
   Walk: for each tip (not `is_migration_src()`), scan backwards via `migration_target` links to
   collect the full ordered chain root → tip.
2. For each chain, emit the `migration chain (...)` header line, then loop through the ordered
   pool vector and print each pool with the appropriate indent prefix:
   - position 0 (root): `""`
   - positions 1..N-2 (stubs): `"    "` (4 spaces)
   - position N-1 (active): `"        "` (8 spaces)
3. Each pool's sub-fields (migration\_role, snap, removed\_snaps) are printed at `pool_indent + "    "`.
4. After all chains, print standalone pools at 0 indent as today.

### JSON path — `OSDMonitor::preprocess_command()`

[`src/mon/OSDMonitor.cc:6418`](../src/mon/OSDMonitor.cc) — the `osd pool ls` handler:

1. Same chain-building step as above.
2. Open `migration_chains` array; for each chain open a chain object, write envelope fields
   (`chain_id`, `root_pool_id`, `active_pool_id`, `active_pool_name`, `total_pools`), then open
   a `pools` array and emit each pool's full `pg_pool_t::dump()` output plus the extra fields
   (`migration_role`, `chain_depth`, `is_active_pool`, `migration_status`, `progress_pct`,
   `migrating_pgs`).
3. Close `migration_chains`. Open `pools` array and emit standalone pools as today.

### `migration_role` values

| Value | Plain text label | Meaning |
|---|---|---|
| `"root"` | `[root]  ` | First pool in the chain — no `migration_src`, has `migration_target` |
| `"stub"` | `[stub]  ` | Intermediate pool — has both `migration_src` and `migration_target` |
| `"active"` | `[active]` | Tip of the chain — has `migration_src`, no `migration_target` |
| absent/null | _(no label)_ | Not part of a migration chain |

### Progress calculation

```
progress_pct = (pg_num - migrating_pgs.size()) * 100 / pg_num
```

A pool with `is_migration_src() == true` and `migrating_pgs.empty()` is `complete`.
Use `PG_STATE_MIGRATION_WAIT` / `TOOFULL` / `UNFOUND` / `ERROR` from
[`src/osd/osd_types.h:1083`](../src/osd/osd_types.h) to report stalled states.
