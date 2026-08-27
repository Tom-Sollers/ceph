# Pool migration display — agreed design

This document captures the design agreed by Tom and Jamie on 2026-08-25, based on
the actual running output Jamie produced and the review of Ceph's existing tier
precedent.  It supersedes the earlier options documents.

---

## What the team agreed

1. **`osd pool ls` (plain, no detail):** show the label prefix on the pool name line
   and use indentation to show chain membership.  Active pool at column 0, stub pools
   indented by 4 spaces.  No flag required — this is always shown when a migration is
   active.

2. **`osd pool ls detail`:** same label prefix and indentation as the plain view, but
   each entry is the full `pg_pool_t` detail line.  The pool ID shown is the **real**
   pool ID of each pool, not the root's ID (Tom's point at 2:03 PM: "if the flag is
   added then the pools will use their real numbers").

3. **JSON / `--format=json`:** follow Jamie's suggestion at 4:01 PM — attach the stub
   pools as an array called `migration_chain` on the **active pool's** entry.  This is
   the same pattern as CRUSH tree's `children` array on the parent node.

4. **`migration_src` / `migration_target` in the detail line:** these already appear
   in `pg_pool_t::dump()` for JSON.  For the plain-text detail line
   (`operator<<(ostream, pg_pool_t)`) they are currently silent.  The agreed approach
   (Tom at 5:03 PM: "option A looks better and is a lot more readable") is to add
   them inline on the detail line, following the exact same pattern as `tier_of` and
   `tiers` — always shown when non-null, no new flag needed.

5. **`--show-migration-chain` flag:** the flag is dropped from the design.  The chain
   information is always shown when a migration is active, via the label/indent on `ls`
   and via the inline fields + `migration_chain` array on `ls detail`.

---

## Agreed output — `osd pool ls`

Based directly on Jamie's running output:

```
.mgr
test_pool_3
    stub_pool test_pool_2
    stub_pool test_pool_1
another_pool
another_migration_target
    stub_pool another_migration_source
```

Rules:
- Active pool (tip): printed at column 0 with its plain name — no prefix label needed
  because it already dominates the view by being at column 0.
- Stub pools: indented 4 spaces, prefixed with `stub_pool `.
- Standalone pools: column 0, no prefix, no change from today.
- Stubs are printed **in descending pool-ID order** (most recent hop first) directly
  below their active pool.  This matches Jamie's output: `test_pool_2` (id 3) before
  `test_pool_1` (id 2).

> **Note on "root_pool":** the team considered a `root_pool` prefix or a separate root
> indent level, but Jamie's actual running output does not use one — the root is just
> the first stub in the indented list.  The active pool at column 0 provides the anchor;
> the stubs in order tell you the history.

---

## Agreed output — `osd pool ls detail`

Based on Jamie's running output with real pool IDs:

```
pool 1 active_pool '.mgr' replicated size 3 min_size 1 crush_rule 0 object_hash rjenkins pg_num 1 pgp_num 1 autoscale_mode off last_change 16 flags hashpspool stripe_width 0 application mgr read_balance_score 5.00
pool 4 active_pool 'test_pool_3' replicated size 3 min_size 1 crush_rule 0 object_hash rjenkins pg_num 32 pgp_num 32 autoscale_mode off last_change 24 flags hashpspool stripe_width 0 read_balance_score 1.56
    pool 3 stub_pool 'test_pool_2' replicated size 3 min_size 1 crush_rule 0 object_hash rjenkins pg_num 32 pgp_num 32 autoscale_mode off last_change 29 flags hashpspool stripe_width 0 read_balance_score 1.56
    pool 2 stub_pool 'test_pool_1' replicated size 3 min_size 1 crush_rule 0 object_hash rjenkins pg_num 32 pgp_num 32 autoscale_mode off last_change 32 flags hashpspool stripe_width 0 read_balance_score 1.56
pool 5 active_pool 'another_pool' replicated size 3 min_size 1 crush_rule 0 object_hash rjenkins pg_num 1 pgp_num 1 autoscale_mode off last_change 16 flags hashpspool stripe_width 0 application mgr read_balance_score 5.00
```

Rules:
- Format: `pool <real_pid> <label> '<name>' <pg_pool_t detail line>`
- Label for active/standalone: `active_pool` (no indent).
- Label for stubs: `stub_pool` (4-space indent).
- Each pool uses its **own real pool ID**, not the root's ID.
- The `pg_pool_t` detail line already includes `migration_src` / `migration_target`
  inline when the fields are present (see "inline fields" section below).
- Stubs printed in descending pool-ID order directly below their active pool.
- Standalone pools show `active_pool` label (they are their own active pool).

### The inline migration fields (Option A)

Inside `operator<<(ostream&, const pg_pool_t&)` in
[`src/osd/osd_types.cc`](../src/osd/osd_types.cc), `tier_of` and `tiers` are already
emitted conditionally when non-zero/non-empty.  The same pattern applies to migration:

```
// existing tier pattern (lines 2543–2546):
if (!p.tiers.empty())
    out << " tiers " << p.tiers;
if (p.is_tier())
    out << " tier_of " << p.tier_of;

// migration — same pattern to add:
if (p.migration_target.has_value())
    out << " migration_target " << *p.migration_target;
if (p.migration_src.has_value())
    out << " migration_src " << *p.migration_src;
```

This means the fields appear in the detail line automatically on both the active pool
and the stub pool entries, at no extra cost, and with no new flag.  `pg_pool_t::dump()`
already emits them to JSON, so the JSON formatter path needs no change here.

---

## Agreed output — JSON (`--format=json-pretty`)

Jamie's suggestion (4:01 PM): attach all stubs/sources as an array on the current
(active) pool.  The pattern is the CRUSH tree's `children` array on parent nodes.

```json
{
  "pools": [
    {
      "pool_id": 1,
      "pool_name": ".mgr",
      "migration_role": "active",
      "type": 1, "size": 3,
      "...": "... all normal pg_pool_t fields ..."
    },
    {
      "pool_id": 4,
      "pool_name": "test_pool_3",
      "migration_role": "active",
      "migration_chain": [
        {
          "pool_id": 3,
          "pool_name": "test_pool_2",
          "migration_role": "stub",
          "migration_src": 2,
          "migration_target": 4,
          "type": 1, "size": 3,
          "...": "... all normal pg_pool_t fields ..."
        },
        {
          "pool_id": 2,
          "pool_name": "test_pool_1",
          "migration_role": "stub",
          "migration_target": 4,
          "type": 1, "size": 3,
          "...": "... all normal pg_pool_t fields ..."
        }
      ],
      "type": 1, "size": 3,
      "...": "... all normal pg_pool_t fields ..."
    },
    {
      "pool_id": 5,
      "pool_name": "another_pool",
      "migration_role": "active",
      "type": 1, "size": 3,
      "...": "... all normal pg_pool_t fields ..."
    }
  ]
}
```

Rules:
- Every pool entry gets a `migration_role` field: `"active"` or `"stub"`.
  Standalone pools get `"active"` (they are their own active pool with no chain).
- Active pools that have a migration chain get a `migration_chain` array.
  Standalone pools and stubs do not have this key.
- Stubs inside `migration_chain` are in descending pool-ID order (most recent first),
  matching the plain-text order.
- Each stub entry inside `migration_chain` carries its full `pg_pool_t::dump()` output
  so a consumer has all the information it needs without a second query.
- Stubs are **not** emitted as top-level entries in `pools` — they only appear nested
  under their active pool.  This keeps the top-level list clean (one entry per logical
  pool, which is the active pool).

---

## Open question from the conversation

**Tom at 1:58 PM / 2:02 PM:** *"Is `ceph osd pool migrate` still going to create a
new target pool and keep the source pool?  Or is it actually transforming the source
pool?"*

This affects the display because:
- If a new pool is always created (current behaviour via `osd pool create
  --migrate_from`), then pool IDs always increase along the chain, and descending
  order = most recent stub first.
- If `osd pool migrate` transforms in place (no new pool ID), the chain concept does
  not apply in the same way.

**Resolution needed before implementation:** confirm with Bill / the team whether
`osd pool migrate` creates a new pool (new ID) or transforms the existing one.  The
display design above assumes new-pool-always.

---

## Open question — pool ID shown without the flag

**Tom at 1:56 PM:** *"How are we going to handle the detailed view pool numbering if
we are keeping the pool number of the initial source pool?"*

**Tom at 2:03 PM:** *"We are only displaying the original pool number if the flag is
not added.  If the flag is added then the pools will use their real numbers."*

The current `print_pools()` code already does the root-ID substitution (scanning for
the lowest-ID pool whose `migration_target` points at the active pool and using that
as `display_pid`).  The agreed design above keeps this: without `--show-migration-chain`
the active pool displays the root's ID; with the chain view each pool shows its own
real ID.  Since `--show-migration-chain` is now dropped (replaced by always-on
behaviour), the rule becomes:

- **`osd pool ls`** (plain): pool names only — no ID shown, no ambiguity.
- **`osd pool ls detail`** (chain always shown): each pool shows its **real ID**.
  The root ID substitution is removed for this view because when you can see all the
  stubs, the IDs are unambiguous.

This is a small but meaningful change from the current `print_pools()` behaviour and
should be noted in commit messages.

---

## Summary of files to change

| File | Change |
|---|---|
| [`src/osd/osd_types.cc`](../src/osd/osd_types.cc) | Add `migration_target` / `migration_src` to `operator<<` inline detail line, following `tier_of` pattern |
| [`src/osd/OSDMap.cc`](../src/osd/OSDMap.cc) | Rewrite `print_pools()`: emit active+stub lines with labels and indentation; use real pool IDs; add chain-walk helper |
| [`src/mon/OSDMonitor.cc`](../src/mon/OSDMonitor.cc) | Rewrite the `osd pool ls` plain handler: emit label+indent for plain list; rewrite JSON handler: emit `migration_chain` array on active pool, omit stubs from top-level `pools` |
| [`src/mon/MonCommands.h`](../src/mon/MonCommands.h) | No change needed — `--show-migration-chain` flag is dropped |
