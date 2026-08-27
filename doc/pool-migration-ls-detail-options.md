# `ceph osd pool ls detail --show-migration-chain` — Output Design Options

## Context and constraints

**Without the flag (current behaviour):** only the tip of each migration chain is shown. Source and
intermediate pools are hidden. This is the behaviour from commit `a5e78ab8450`.

**With `--show-migration-chain`:** every pool in every chain is shown in **full detail** (same
`pg_pool_t` dump as a normal pool entry), so operators can inspect the config, crush rule,
pg_num, EC profile etc. of every pool in the cascade. The output must also make the chain
topology — who points to whom — and the current acting pool obvious at a glance.

**Key requirements addressed here that were missing from the previous design:**

1. There can be **multiple independent chains** (e.g. pools 1→2→3 form one chain, pools 4→5→6
   form another). Each chain must be clearly grouped and shown separately.
2. Every pool in a chain must be shown with **full detail** — the same data as an ordinary
   `pool <id> '<name>' replicated ...` line plus its tab-indented snap/removed\_snaps lines.
3. The **current acting pool** (the tip — the pool all I/O is directed at) must be unambiguous.
4. The topology (which pool migrated to which) must be legible without ASCII art.
5. Everything must translate cleanly to JSON.

---

## Data model recap

Each [`pg_pool_t`](../src/osd/osd_types.h) carries:

| Field | Meaning |
|---|---|
| `migration_target` (optional int64) | Set on a **source** pool — points to the pool it is migrating into |
| `migration_src` (optional int64) | Set on a **target** pool — points to the pool it was migrated from |
| `migrating_pgs` (set\<pg\_t\>) | PGs still in-flight for this hop |
| `lowest_migrated_pg` (uint32) | Lowest PG seed that has already completed |

`is_migration_src()` is true when `migration_target` is set (i.e. this pool is feeding into
another). The tip of a chain has no `migration_target`. Completed source stubs have
`migration_src` cleared but `migration_target` still set, so chain membership can only be found by
forward scan: find all pools whose `migration_target` points to a given pool ID.

**Progress per hop:** `(pg_num - migrating_pgs.size()) * 100 / pg_num`

**Migration status values:** `complete`, `in_progress`, `waiting`, `stalled_toofull`,
`stalled_unfound`, `stalled_error`

---

## Scenario used in all examples

Two independent chains plus one standalone pool:

```
Chain A:  pool 1 (mypool)  -->  pool 2 (mypool_v2)  -->  pool 3 (mypool_v3)  [tip, current acting]
Chain B:  pool 4 (volumes) -->  pool 5 (volumes_ec)                            [tip, current acting]
Standalone: pool 6 (images)                                                    [no migration]
```

- Pool 1 → 2: **complete** (all PGs moved)
- Pool 2 → 3: **in_progress** (49 of 128 PGs still migrating)
- Pool 4 → 5: **in_progress** (12 of 64 PGs still migrating)
- Pool 3 and pool 5 are the current acting pools for their respective chains.

---

## Option 1 — Migration chains printed as grouped blocks, then standalone pools

The output is split into two clearly labelled sections. Migration chains come first: each chain is
its own block, pools printed in order root→tip, each with **full detail**. The tip line is
annotated `[current acting pool]`. A header line opens each chain block. Standalone pools follow
in a separate section identical to today's output.

### Plain text (`ls detail --show-migration-chain`)

```
=== migration chains ===

--- chain A  (root pool id: 1, 3 pools, 2 hops) ---

pool 1 'mypool' replicated size 3 min_size 2 crush_rule 0 object_hash rjenkins pg_num 128 pgp_num 128 last_change 42 flags hashpspool stripe_width 0 application rbd
    migration_role source  migration_target 2  migration_status complete  progress 100%
    snap 1 'snap-foo' 2024-01-01 00:00:00.000000

pool 2 'mypool_v2' replicated size 3 min_size 2 crush_rule 1 object_hash rjenkins pg_num 128 pgp_num 128 last_change 86 flags hashpspool stripe_width 0 application rbd
    migration_role source  migration_src 1  migration_target 3  migration_status complete  progress 100%

pool 3 'mypool_v3' replicated size 3 min_size 2 crush_rule 2 object_hash rjenkins pg_num 128 pgp_num 128 last_change 101 flags hashpspool stripe_width 0 application rbd  [current acting pool]
    migration_role current_acting  migration_src 2  migration_status in_progress  progress 62%  migrating_pgs 49/128

--- chain B  (root pool id: 4, 2 pools, 1 hop) ---

pool 4 'volumes' replicated size 3 min_size 2 crush_rule 0 object_hash rjenkins pg_num 64 pgp_num 64 last_change 55 flags hashpspool stripe_width 0 application rbd
    migration_role source  migration_target 5  migration_status in_progress  progress 81%  migrating_pgs 12/64

pool 5 'volumes_ec' erasure profile default ec_data_shard_count 4 ec_coding_shard_count 2 size 6 min_size 5 crush_rule 3 object_hash rjenkins pg_num 64 pgp_num 64 last_change 98 flags hashpspool stripe_width 4096 application rbd  [current acting pool]
    migration_role current_acting  migration_src 4  migration_status in_progress  progress 81%  migrating_pgs 12/64

=== standalone pools ===

pool 6 'images' replicated size 3 min_size 2 crush_rule 0 object_hash rjenkins pg_num 32 pgp_num 32 last_change 10 flags hashpspool stripe_width 0 application rbd
```

**Why this works:**
- The `=== migration chains ===` / `=== standalone pools ===` headers make the two sections
  impossible to miss.
- The `--- chain A ---` / `--- chain B ---` sub-headers group each independent chain clearly.
- Every pool line is the full unmodified `pg_pool_t` stream output — nothing is hidden.
- The `[current acting pool]` annotation on the tip line is the single source of truth.
- The `migration_role` / `migration_status` / `progress` lines are tab-indented just like `snap`
  and `removed_snaps` lines already are, so they fit the existing visual grammar.

### JSON (`--format=json --show-migration-chain`)

```json
{
  "migration_chains": [
    {
      "chain_id": 1,
      "root_pool_id": 1,
      "current_acting_pool_id": 3,
      "current_acting_pool_name": "mypool_v3",
      "total_hops": 2,
      "pools": [
        {
          "pool_id": 1,
          "pool_name": "mypool",
          "migration_role": "source",
          "migration_target": 2,
          "migration_status": "complete",
          "progress_pct": 100,
          "migrating_pgs": 0,
          "is_current_acting_pool": false,
          "type": 1, "size": 3, "min_size": 2, "crush_rule": 0,
          "pg_num": 128, "pg_placement_num": 128,
          "flags_names": "hashpspool",
          "application_metadata": { "rbd": {} }
        },
        {
          "pool_id": 2,
          "pool_name": "mypool_v2",
          "migration_role": "source",
          "migration_src": 1,
          "migration_target": 3,
          "migration_status": "complete",
          "progress_pct": 100,
          "migrating_pgs": 0,
          "is_current_acting_pool": false,
          "type": 1, "size": 3, "min_size": 2, "crush_rule": 1,
          "pg_num": 128, "pg_placement_num": 128,
          "flags_names": "hashpspool",
          "application_metadata": { "rbd": {} }
        },
        {
          "pool_id": 3,
          "pool_name": "mypool_v3",
          "migration_role": "current_acting",
          "migration_src": 2,
          "migration_status": "in_progress",
          "progress_pct": 62,
          "migrating_pgs": 49,
          "pg_num": 128,
          "is_current_acting_pool": true,
          "type": 1, "size": 3, "min_size": 2, "crush_rule": 2,
          "pg_num": 128, "pg_placement_num": 128,
          "flags_names": "hashpspool",
          "application_metadata": { "rbd": {} }
        }
      ]
    },
    {
      "chain_id": 4,
      "root_pool_id": 4,
      "current_acting_pool_id": 5,
      "current_acting_pool_name": "volumes_ec",
      "total_hops": 1,
      "pools": [
        {
          "pool_id": 4,
          "pool_name": "volumes",
          "migration_role": "source",
          "migration_target": 5,
          "migration_status": "in_progress",
          "progress_pct": 81,
          "migrating_pgs": 12,
          "pg_num": 64,
          "is_current_acting_pool": false,
          "type": 1, "size": 3, "min_size": 2, "crush_rule": 0,
          "pg_num": 64, "pg_placement_num": 64,
          "flags_names": "hashpspool",
          "application_metadata": { "rbd": {} }
        },
        {
          "pool_id": 5,
          "pool_name": "volumes_ec",
          "migration_role": "current_acting",
          "migration_src": 4,
          "migration_status": "in_progress",
          "progress_pct": 81,
          "migrating_pgs": 12,
          "pg_num": 64,
          "is_current_acting_pool": true,
          "type": 2, "erasure_code_profile": "default",
          "ec_data_shard_count": 4, "ec_coding_shard_count": 2,
          "size": 6, "min_size": 5, "crush_rule": 3,
          "pg_num": 64, "pg_placement_num": 64,
          "flags_names": "hashpspool",
          "application_metadata": { "rbd": {} }
        }
      ]
    }
  ],
  "standalone_pools": [
    {
      "pool_id": 6,
      "pool_name": "images",
      "is_current_acting_pool": false,
      "type": 1, "size": 3, "min_size": 2, "crush_rule": 0,
      "pg_num": 32, "pg_placement_num": 32,
      "flags_names": "hashpspool",
      "application_metadata": { "rbd": {} }
    }
  ]
}
```

**Pros:**
- Multiple chains are naturally separated — chain A and chain B are impossible to confuse.
- Every pool has full detail — nothing summarised.
- `is_current_acting_pool` at every pool level and also at chain level (`current_acting_pool_id`).
- Standalone pools are still reachable as `.standalone_pools[]`.
- JSON maps directly to what `pg_pool_t::dump()` already emits; just add the extra migration fields.

**Cons:**
- JSON root shape changes from a bare `.pools[]` array to an object with two keys.
- Requires the most implementation work of the three options.

---

## Option 2 — All pools in one flat list, chain membership shown via annotations

Keep a single flat `pools` array (root shape unchanged). Every pool in a chain is shown with full
detail. Chain membership and topology is conveyed by three added fields on each pool entry:
`chain_id` (= root pool ID, `null` for standalone), `chain_hop` (1-based position in the chain),
and `is_current_acting_pool`. Source pools appear before their target in the list (ordered by pool
ID, which naturally puts root first since it has the lowest ID). A header comment before each
chain group separates the groups in plain text.

### Plain text (`ls detail --show-migration-chain`)

```
# chain A  root=1  tip=3 (mypool_v3)  [current acting]
pool 1 'mypool' replicated size 3 min_size 2 crush_rule 0 object_hash rjenkins pg_num 128 pgp_num 128 last_change 42 flags hashpspool stripe_width 0 application rbd
    chain_id 1  chain_hop 1/3  migration_role source  migration_target 2  migration_status complete  progress 100%
    snap 1 'snap-foo' 2024-01-01 00:00:00.000000

pool 2 'mypool_v2' replicated size 3 min_size 2 crush_rule 1 object_hash rjenkins pg_num 128 pgp_num 128 last_change 86 flags hashpspool stripe_width 0 application rbd
    chain_id 1  chain_hop 2/3  migration_role source  migration_src 1  migration_target 3  migration_status complete  progress 100%

pool 3 'mypool_v3' replicated size 3 min_size 2 crush_rule 2 object_hash rjenkins pg_num 128 pgp_num 128 last_change 101 flags hashpspool stripe_width 0 application rbd  [current acting pool]
    chain_id 1  chain_hop 3/3  migration_role current_acting  migration_src 2  migration_status in_progress  progress 62%  migrating_pgs 49/128

# chain B  root=4  tip=5 (volumes_ec)  [current acting]
pool 4 'volumes' replicated size 3 min_size 2 crush_rule 0 object_hash rjenkins pg_num 64 pgp_num 64 last_change 55 flags hashpspool stripe_width 0 application rbd
    chain_id 4  chain_hop 1/2  migration_role source  migration_target 5  migration_status in_progress  progress 81%  migrating_pgs 12/64

pool 5 'volumes_ec' erasure profile default ec_data_shard_count 4 ec_coding_shard_count 2 size 6 min_size 5 crush_rule 3 object_hash rjenkins pg_num 64 pgp_num 64 last_change 98 flags hashpspool stripe_width 4096 application rbd  [current acting pool]
    chain_id 4  chain_hop 2/2  migration_role current_acting  migration_src 4  migration_status in_progress  progress 81%  migrating_pgs 12/64

pool 6 'images' replicated size 3 min_size 2 crush_rule 0 object_hash rjenkins pg_num 32 pgp_num 32 last_change 10 flags hashpspool stripe_width 0 application rbd
```

### JSON (`--format=json --show-migration-chain`)

```json
{
  "pools": [
    {
      "pool_id": 1,
      "pool_name": "mypool",
      "chain_id": 1,
      "chain_hop": 1,
      "chain_total_pools": 3,
      "migration_role": "source",
      "migration_target": 2,
      "migration_status": "complete",
      "progress_pct": 100,
      "migrating_pgs": 0,
      "is_current_acting_pool": false,
      "type": 1, "size": 3, "min_size": 2, "crush_rule": 0,
      "pg_num": 128, "pg_placement_num": 128,
      "flags_names": "hashpspool",
      "application_metadata": { "rbd": {} }
    },
    {
      "pool_id": 2,
      "pool_name": "mypool_v2",
      "chain_id": 1,
      "chain_hop": 2,
      "chain_total_pools": 3,
      "migration_role": "source",
      "migration_src": 1,
      "migration_target": 3,
      "migration_status": "complete",
      "progress_pct": 100,
      "migrating_pgs": 0,
      "is_current_acting_pool": false,
      "type": 1, "size": 3, "min_size": 2, "crush_rule": 1,
      "pg_num": 128, "pg_placement_num": 128,
      "flags_names": "hashpspool",
      "application_metadata": { "rbd": {} }
    },
    {
      "pool_id": 3,
      "pool_name": "mypool_v3",
      "chain_id": 1,
      "chain_hop": 3,
      "chain_total_pools": 3,
      "migration_role": "current_acting",
      "migration_src": 2,
      "migration_status": "in_progress",
      "progress_pct": 62,
      "migrating_pgs": 49,
      "pg_num": 128,
      "is_current_acting_pool": true,
      "type": 1, "size": 3, "min_size": 2, "crush_rule": 2,
      "pg_num": 128, "pg_placement_num": 128,
      "flags_names": "hashpspool",
      "application_metadata": { "rbd": {} }
    },
    {
      "pool_id": 4,
      "pool_name": "volumes",
      "chain_id": 4,
      "chain_hop": 1,
      "chain_total_pools": 2,
      "migration_role": "source",
      "migration_target": 5,
      "migration_status": "in_progress",
      "progress_pct": 81,
      "migrating_pgs": 12,
      "is_current_acting_pool": false,
      "type": 1, "size": 3, "min_size": 2, "crush_rule": 0,
      "pg_num": 64, "pg_placement_num": 64,
      "flags_names": "hashpspool",
      "application_metadata": { "rbd": {} }
    },
    {
      "pool_id": 5,
      "pool_name": "volumes_ec",
      "chain_id": 4,
      "chain_hop": 2,
      "chain_total_pools": 2,
      "migration_role": "current_acting",
      "migration_src": 4,
      "migration_status": "in_progress",
      "progress_pct": 81,
      "migrating_pgs": 12,
      "pg_num": 64,
      "is_current_acting_pool": true,
      "type": 2, "erasure_code_profile": "default",
      "ec_data_shard_count": 4, "ec_coding_shard_count": 2,
      "size": 6, "min_size": 5, "crush_rule": 3,
      "pg_num": 64, "pg_placement_num": 64,
      "flags_names": "hashpspool",
      "application_metadata": { "rbd": {} }
    },
    {
      "pool_id": 6,
      "pool_name": "images",
      "chain_id": null,
      "migration_role": null,
      "is_current_acting_pool": false,
      "type": 1, "size": 3, "min_size": 2, "crush_rule": 0,
      "pg_num": 32, "pg_placement_num": 32,
      "flags_names": "hashpspool",
      "application_metadata": { "rbd": {} }
    }
  ]
}
```

**Pros:**
- JSON root stays `.pools[]` — the fewest breaking changes for existing scripts.
- `chain_id` + `chain_hop` let any script group and order chains with a single `jq` call.
- Full detail on every pool, no summarisation.
- Flat — easy to iterate.

**Cons:**
- Chain grouping in plain text relies on the `# chain A` comment line — not as visually loud as
  the section headers in Option 1.
- Pool ID ordering naturally puts roots first only if pool IDs were assigned in migration order
  (which they are in practice, since a migration target pool is always created after the source).

---

## Option 3 — Nested: chain pools printed *inside* their chain entry, standalone pools alongside

A middle ground. The top-level array contains two kinds of entries: `chain` entries (which embed
their full pool list) and `pool` entries (standalone). In plain text this maps to a header line
for each chain followed by the full pool blocks indented one level, then standalone pools at the
top level. This keeps JSON root as a single array while still grouping chains explicitly.

### Plain text (`ls detail --show-migration-chain`)

```
chain A  (root pool id: 1  current acting: mypool_v3 id=3  hops: 2)
    pool 1 'mypool' replicated size 3 min_size 2 crush_rule 0 object_hash rjenkins pg_num 128 pgp_num 128 last_change 42 flags hashpspool stripe_width 0 application rbd
        migration_role source  migration_target 2  migration_status complete  progress 100%
        snap 1 'snap-foo' 2024-01-01 00:00:00.000000
    pool 2 'mypool_v2' replicated size 3 min_size 2 crush_rule 1 object_hash rjenkins pg_num 128 pgp_num 128 last_change 86 flags hashpspool stripe_width 0 application rbd
        migration_role source  migration_src 1  migration_target 3  migration_status complete  progress 100%
    pool 3 'mypool_v3' replicated size 3 min_size 2 crush_rule 2 object_hash rjenkins pg_num 128 pgp_num 128 last_change 101 flags hashpspool stripe_width 0 application rbd  [current acting pool]
        migration_role current_acting  migration_src 2  migration_status in_progress  progress 62%  migrating_pgs 49/128

chain B  (root pool id: 4  current acting: volumes_ec id=5  hops: 1)
    pool 4 'volumes' replicated size 3 min_size 2 crush_rule 0 object_hash rjenkins pg_num 64 pgp_num 64 last_change 55 flags hashpspool stripe_width 0 application rbd
        migration_role source  migration_target 5  migration_status in_progress  progress 81%  migrating_pgs 12/64
    pool 5 'volumes_ec' erasure profile default ec_data_shard_count 4 ec_coding_shard_count 2 size 6 min_size 5 crush_rule 3 object_hash rjenkins pg_num 64 pgp_num 64 last_change 98 flags hashpspool stripe_width 4096 application rbd  [current acting pool]
        migration_role current_acting  migration_src 4  migration_status in_progress  progress 81%  migrating_pgs 12/64

pool 6 'images' replicated size 3 min_size 2 crush_rule 0 object_hash rjenkins pg_num 32 pgp_num 32 last_change 10 flags hashpspool stripe_width 0 application rbd
```

### JSON (`--format=json --show-migration-chain`)

```json
{
  "pools": [
    {
      "entry_type": "chain",
      "chain_id": 1,
      "root_pool_id": 1,
      "current_acting_pool_id": 3,
      "current_acting_pool_name": "mypool_v3",
      "total_hops": 2,
      "chain_pools": [
        {
          "pool_id": 1,
          "pool_name": "mypool",
          "migration_role": "source",
          "migration_target": 2,
          "migration_status": "complete",
          "progress_pct": 100,
          "migrating_pgs": 0,
          "is_current_acting_pool": false,
          "type": 1, "size": 3, "min_size": 2, "crush_rule": 0,
          "pg_num": 128, "pg_placement_num": 128,
          "flags_names": "hashpspool",
          "application_metadata": { "rbd": {} }
        },
        {
          "pool_id": 2,
          "pool_name": "mypool_v2",
          "migration_role": "source",
          "migration_src": 1,
          "migration_target": 3,
          "migration_status": "complete",
          "progress_pct": 100,
          "migrating_pgs": 0,
          "is_current_acting_pool": false,
          "type": 1, "size": 3, "min_size": 2, "crush_rule": 1,
          "pg_num": 128, "pg_placement_num": 128,
          "flags_names": "hashpspool",
          "application_metadata": { "rbd": {} }
        },
        {
          "pool_id": 3,
          "pool_name": "mypool_v3",
          "migration_role": "current_acting",
          "migration_src": 2,
          "migration_status": "in_progress",
          "progress_pct": 62,
          "migrating_pgs": 49,
          "is_current_acting_pool": true,
          "type": 1, "size": 3, "min_size": 2, "crush_rule": 2,
          "pg_num": 128, "pg_placement_num": 128,
          "flags_names": "hashpspool",
          "application_metadata": { "rbd": {} }
        }
      ]
    },
    {
      "entry_type": "chain",
      "chain_id": 4,
      "root_pool_id": 4,
      "current_acting_pool_id": 5,
      "current_acting_pool_name": "volumes_ec",
      "total_hops": 1,
      "chain_pools": [
        {
          "pool_id": 4,
          "pool_name": "volumes",
          "migration_role": "source",
          "migration_target": 5,
          "migration_status": "in_progress",
          "progress_pct": 81,
          "migrating_pgs": 12,
          "is_current_acting_pool": false,
          "type": 1, "size": 3, "min_size": 2, "crush_rule": 0,
          "pg_num": 64, "pg_placement_num": 64,
          "flags_names": "hashpspool",
          "application_metadata": { "rbd": {} }
        },
        {
          "pool_id": 5,
          "pool_name": "volumes_ec",
          "migration_role": "current_acting",
          "migration_src": 4,
          "migration_status": "in_progress",
          "progress_pct": 81,
          "migrating_pgs": 12,
          "is_current_acting_pool": true,
          "type": 2, "erasure_code_profile": "default",
          "ec_data_shard_count": 4, "ec_coding_shard_count": 2,
          "size": 6, "min_size": 5, "crush_rule": 3,
          "pg_num": 64, "pg_placement_num": 64,
          "flags_names": "hashpspool",
          "application_metadata": { "rbd": {} }
        }
      ]
    },
    {
      "entry_type": "pool",
      "pool_id": 6,
      "pool_name": "images",
      "chain_id": null,
      "is_current_acting_pool": false,
      "type": 1, "size": 3, "min_size": 2, "crush_rule": 0,
      "pg_num": 32, "pg_placement_num": 32,
      "flags_names": "hashpspool",
      "application_metadata": { "rbd": {} }
    }
  ]
}
```

**Pros:**
- JSON root stays a single `.pools[]` array.
- Chain entries and standalone pool entries clearly distinguished by `entry_type`.
- Chain pools are nested inside their chain entry — grouping is explicit and
  `jq '.pools[] | select(.entry_type=="chain") | .chain_pools[]'` gets all chain pool detail.
- `current_acting_pool_id` is on the chain envelope — immediately visible without scanning members.
- Plain text indentation visually groups chain members without any headers outside the pool block.

**Cons:**
- `entry_type` means the array has mixed-shape entries — scripts iterating `.pools[]` and
  expecting to find `pool_id` at the top level will need to handle `entry_type == "chain"`.
- One extra level of nesting in JSON vs Option 2.

---

## Comparison

| | Option 1 (two sections) | Option 2 (flat list) | Option 3 (nested) |
|---|---|---|---|
| Multiple chains clearly separated | Yes — named section per chain | Yes — `# chain X` headers in text, `chain_id` in JSON | Yes — chain envelope entry |
| Full pool detail on every pool | Yes | Yes | Yes |
| Current acting pool unambiguous | `[current acting pool]` tag + `current_acting_pool_id` on chain | `[current acting pool]` tag + `is_current_acting_pool: true` | Both, at chain and pool level |
| JSON root shape | **Changes** to `{migration_chains, standalone_pools}` | `.pools[]` unchanged | `.pools[]` unchanged, mixed entry types |
| Topology (who → who) visible | Yes — pools printed root→tip in order | Yes — `chain_hop` + `migration_target`/`migration_src` | Yes — `chain_pools[]` in order |
| Easiest to script in jq | Medium (`migration_chains[].pools[]`) | High (`pools[] \| select(.chain_id==X)`) | Medium (`pools[] \| select(.entry_type=="chain") \| .chain_pools[]`) |
| Implementation complexity | Highest | Lowest | Medium |

---

## Implementation notes (all options)

- **Flag:** add `name=show_migration_chain,type=CephBool,req=false` to the `osd pool ls` command
  in [`src/mon/MonCommands.h:1130`](../src/mon/MonCommands.h).

- **Chain reconstruction:** because completed source stubs have `migration_src` cleared, chains
  must be built by a forward scan. For each pool that is **not** `is_migration_src()` (the tips),
  walk backwards: collect all pools whose `migration_target` points at the tip, then find the
  pool pointing at each of those, and so on, until you reach a pool with no pool pointing at it.
  That is the root. This produces the ordered list root → tip. The root-finding scan already
  exists in [`src/osd/OSDMap.cc:4455`](../src/osd/OSDMap.cc) — extend it to walk the full chain.

- **Progress:** `progress_pct = (pg_num - migrating_pgs.size()) * 100 / pg_num`. A source hop
  with `migrating_pgs.empty()` is `complete`. Use `PG_STATE_MIGRATION_WAIT/TOOFULL/UNFOUND/ERROR`
  from [`src/osd/osd_types.h:1083`](../src/osd/osd_types.h) to set the `stalled_*` status values.

- **Plain text full detail:** the `!f && detail == "detail"` branch calls
  `OSDMap::print_pools()` in [`src/osd/OSDMap.cc:4423`](../src/osd/OSDMap.cc). With the flag set,
  this function needs to emit chain headers and include source pools it currently skips, using the
  same `pdata` stream operator and snap/removed\_snaps tab-indented lines it already uses.

- **`migration_role` values:** `source` (has `migration_target`, not the tip),
  `current_acting` (is the tip — no `migration_target`), `null`/absent (not migrating).
