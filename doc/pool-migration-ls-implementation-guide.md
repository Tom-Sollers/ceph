# Implementation guide — `ceph osd pool ls detail --show-migration-chain`

This document walks through every file you need to touch, in the order you should
touch them, explaining *why* each change is needed and *what* to do — without doing
it for you.

---

## Overview of the call path

When a user runs `ceph osd pool ls detail`, the request flows like this:

```
ceph CLI
  -> mon RPC
    -> OSDMonitor::preprocess_command()   [src/mon/OSDMonitor.cc]
         |
         +-- plain text + detail  ->  OSDMap::print_pools()   [src/osd/OSDMap.cc]
         |
         +-- JSON (any detail)    ->  inline loop in preprocess_command()
                                      calls pg_pool_t::dump()  [src/osd/osd_types.cc]
```

There are exactly **four files** to change:

| File | What changes |
|---|---|
| [`src/mon/MonCommands.h`](../src/mon/MonCommands.h) | Add the new flag to the command definition |
| [`src/mon/OSDMonitor.cc`](../src/mon/OSDMonitor.cc) | Read the flag; add chain-building + JSON output logic |
| [`src/osd/OSDMap.h`](../src/osd/OSDMap.h) | Update the `print_pools` signature |
| [`src/osd/OSDMap.cc`](../src/osd/OSDMap.cc) | Add chain-building + plain text output logic |

---

## Step 1 — Add the flag to the command definition

**File:** [`src/mon/MonCommands.h:1130`](../src/mon/MonCommands.h)

This is where the `osd pool ls` command is declared. Currently it looks like:

```c
COMMAND("osd pool ls "
    "name=detail,type=CephChoices,strings=detail,req=false",
    "list pools", "osd", "r")
```

You need to append a second named parameter for the new boolean flag, following the
same pattern used elsewhere in the file (e.g. `name=show_shadow,type=CephBool` on
the `osd crush tree` command a few hundred lines down).

**What to add:** `name=show_migration_chain,type=CephBool,req=false` — concatenated
onto the existing argument string with a space separator.

After this change the parser will accept `--show-migration-chain` from the CLI and
make it available to `preprocess_command` via `cmdmap`.

---

## Step 2 — Build a helper: the chain reconstruction function

Before touching either `OSDMonitor.cc` or `OSDMap.cc`, think about the chain-building
logic — both files need it, so the cleanest place for it is a private static helper
(or a free function in an anonymous namespace) that you can call from both the plain
text and JSON paths.

**The problem it solves:** because completed source stubs have `migration_src` cleared
(only `migration_target` remains), you cannot walk a chain *backwards* from the tip.
You must walk *forwards*: for each pool in the map, check whether its `migration_target`
points at a known tip, and so on up the chain.

**The data structure to produce:** for each independent chain, an ordered
`std::vector<int64_t>` of pool IDs going root → ... stubs ... → active (tip).

**The algorithm:**

1. First pass over `osdmap.get_pools()`: collect all pool IDs where
   `is_migration_src() == false` — these are either standalone pools or the tips
   (active pools) of chains.

2. For each tip ID found, walk backwards: scan all pools for any pool whose
   `migration_target == tip_id`. That pool is the predecessor. Then scan again for any
   pool whose `migration_target == predecessor_id`, and so on, until no predecessor is
   found. That final pool with no predecessor is the root.

3. Reverse the accumulated list to get root → tip order.

4. If a tip has no predecessor at all, it is a standalone pool — skip it.

The result is a `std::vector<std::vector<int64_t>>` — one inner vector per chain,
each ordered root → active. You will use this in both the plain text and JSON paths.

**Where to put it:** a `static` free function just above `OSDMap::print_pools()` in
[`src/osd/OSDMap.cc`](../src/osd/OSDMap.cc) is the natural home. It takes a
`const mempool::osdmap::map<int64_t, pg_pool_t>& pools` argument (the same type
returned by `get_pools()`) and returns
`std::vector<std::vector<int64_t>>`.

---

## Step 3 — Update `OSDMap::print_pools()` signature

**File:** [`src/osd/OSDMap.h:1835`](../src/osd/OSDMap.h)

The current signature is:

```cpp
void print_pools(CephContext *cct, std::ostream& out) const;
```

Add a `bool show_migration_chain = false` defaulted parameter so that all existing
callers (there are two — see [`src/osd/OSDMap.cc:4556`](../src/osd/OSDMap.cc) and
[`src/mon/OSDMonitor.cc:6423`](../src/mon/OSDMonitor.cc)) continue to compile
unchanged.

---

## Step 4 — Rewrite `OSDMap::print_pools()`

**File:** [`src/osd/OSDMap.cc:4423`](../src/osd/OSDMap.cc)

This function currently skips any pool where `pdata.is_migration_src()` is true and
does a simple linear scan. With the flag set it needs to do something fundamentally
different, so the cleanest approach is:

```cpp
void OSDMap::print_pools(CephContext *cct, ostream& out, bool show_migration_chain) const
{
  if (show_migration_chain) {
    // --- new path ---
  } else {
    // existing code unchanged
  }
}
```

**The new path:**

1. Call your chain-building helper from Step 2 to get the ordered chain vectors.

2. Collect the set of all pool IDs that belong to any chain (flatten the vectors into
   a `std::set<int64_t>`). This lets you quickly identify standalone pools in the
   next step.

3. For each chain vector (one per independent chain):
   - Print the chain header line:
     `"migration chain (root_pool_id " << chain[0] << ", active_pool_id " << chain.back() << "):\n"`
   - Loop through the chain vector. For each pool ID at index `i`:
     - Determine the role: `i == 0` → root, `i == chain.size()-1` → active, else → stub.
     - Determine the indent for the pool line: root = `""`, stub = `"    "` (4 spaces),
       active = `"        "` (8 spaces).
     - Determine the indent for sub-fields: pool_indent + `"    "`.
     - Print: `pool_indent << "pool " << pid << " [" << role_label << "] '" << name << "' " << pdata << rb_score_str << "\n"`
       where `role_label` is `"root]  "`, `"stub]  "`, or `"active]"` (padded to equal
       width — note the trailing spaces on root and stub).
     - Print sub-fields at sub-field indent: `migration_src`/`migration_target` (whichever
       apply), `migration_status`, `progress`, `migrating_pgs`.
     - Print snaps and removed_snaps at sub-field indent (same as today, just with the
       correct indent prefix instead of a hard-coded `\t`).
   - Print a blank line after the chain.

4. After all chains, print standalone pools (those not in the set from step 2) exactly
   as the existing code does today — no label, no indent.

**Progress calculation** — you will need a small inline helper:

```cpp
// Returns 0-100
int migration_progress_pct(const pg_pool_t& p) {
  if (p.get_pg_num() == 0) return 0;
  return (p.get_pg_num() - p.migrating_pgs.size()) * 100 / p.get_pg_num();
}
```

A pool with `is_migration_src() == true` and `migrating_pgs.empty()` is `complete`.
Otherwise it is `in_progress` (or one of the stalled states if you want to check
`PG_STATE_MIGRATION_WAIT` etc. — that is a further enhancement).

---

## Step 5 — Update `OSDMonitor::preprocess_command()` for the JSON and plain text paths

**File:** [`src/mon/OSDMonitor.cc:6418`](../src/mon/OSDMonitor.cc)

### 5a — Read the new flag

After the existing `cmd_getval(cmdmap, "detail", detail);` line, add:

```cpp
bool show_migration_chain = false;
cmd_getval(cmdmap, "show_migration_chain", show_migration_chain);
```

`cmd_getval` on a `CephBool` parameter writes directly into the `bool` and returns
true if the parameter was present.

### 5b — Pass the flag to `print_pools`

The plain text + detail branch on line 6421 calls:

```cpp
osdmap.print_pools(cct, ss);
```

Change this to pass the flag:

```cpp
osdmap.print_pools(cct, ss, show_migration_chain);
```

That is the only change needed for the plain text path — all the work is in
`OSDMap.cc`.

### 5c — Add the JSON chain path

The JSON path (the `else` branch starting at line 6425) currently opens a single
`"pools"` array and loops over all pools skipping `is_migration_src()` ones.

When `show_migration_chain` is true, this block needs to be replaced with the
structured output described in the design doc. The structure to emit:

```
open_object "root"
  open_array "migration_chains"
    for each chain:
      open_object
        dump chain envelope fields (chain_id, root_pool_id, active_pool_id, etc.)
        open_array "pools"
          for each pool in chain:
            open_object "pool"
              dump_int "pool_id"
              dump_string "pool_name"
              dump_string "migration_role"   ("root" / "stub" / "active")
              dump_int "chain_depth"         (0 / 1 / 2)
              dump_bool "is_active_pool"
              dump_string "migration_status"
              dump_int "progress_pct"
              dump_int "migrating_pgs"
              pdata.dump(f.get())            <- full pg_pool_t detail
              dump_read_balance_score(...)
            close_object "pool"
        close_array "pools"
      close_object
  close_array "migration_chains"
  open_array "pools"
    for each standalone pool: (existing code)
  close_array "pools"
close_object "root"
```

The chain-building logic is identical to what you wrote for `OSDMap.cc` in Step 2.
You can either call the same static helper (if you move it somewhere both translation
units can reach, e.g. a small private header), or duplicate the walk inline here —
it is only ~20 lines.

When `show_migration_chain` is false, the existing code is completely unchanged.

---

## Summary of touch points

```
src/mon/MonCommands.h       line 1130-1131   add show_migration_chain CephBool param
src/mon/OSDMonitor.cc       line 6419        read show_migration_chain with cmd_getval
                            line 6421        pass flag to print_pools()
                            line 6425-6471   add show_migration_chain JSON branch
src/osd/OSDMap.h            line 1835        add bool param to print_pools signature
src/osd/OSDMap.cc           before 4423      add chain-building static helper
                            line 4423        add show_migration_chain param + new path
```

---

## Things to watch out for

**The chain walk is O(N²) in pool count** — for every tip you scan all pools. With
realistic pool counts (tens or low hundreds) this is fine. Do not try to optimise it
until it is shown to be a problem.

**`migration_src` is not reliable for backward walking.** Completed hops have it
cleared. Always walk forward (source → target direction) and accumulate, then reverse.
This is covered in Step 2 above.

**The `pools` map is ordered by pool ID** (it is a `btree_map<int64_t, pg_pool_t>`).
Since migration target pools are always created after their source, their IDs are
always higher. This means iterating the map in order naturally visits roots before
their descendants, which helps — but do not rely on it as a substitute for building
the explicit chain vector.

**Sub-field indentation:** today `print_pools` hard-codes `\t` (a tab character) for
snap/removed\_snaps lines. In the new path you should use spaces so the indentation
is consistent with the pool line indentation. Pass the sub-field indent string into
the section of code that prints snaps.

**Label padding:** the labels `[root]  `, `[stub]  `, `[active]` must all be the
same rendered width (9 characters including brackets and trailing space) so that the
pool name column lines up. `[root]` and `[stub]` each need two trailing spaces;
`[active]` needs none.

**Test pools to use:** `src/test/osd/` contains unit tests for `pg_pool_t` and
`OSDMap`. Look at existing pool-related tests there for the pattern to follow when
writing your own test.
