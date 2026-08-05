---
name: ceph-commit-msg
description: Use when the user wants to generate or write a commit message for staged changes in the Ceph repository, following the project's conventional format (component: subject + body + Signed-off-by).
---

# Ceph Commit Message Generator

Follow these steps every time this skill is activated.

## Step 1 — Gather staged diff and author info

Run these two commands in parallel with `execute_command`:

```bash
git diff --cached --stat
```
```bash
git diff --cached
```

The author is always **Tom Sollers <tom.sollers@ibm.com>** — do not run `git config` to look it up.

## Step 2 — Identify the component prefix

Inspect the changed file paths and map them to the correct Ceph component prefix using this table:

| Path pattern | Prefix |
|---|---|
| `src/osd/` | `osd` |
| `src/mon/` | `mon` |
| `src/mds/` | `mds` |
| `src/mgr/` or `src/pybind/mgr/` | `mgr` |
| `src/osdc/` | `osdc` |
| `src/rgw/` | `rgw` |
| `src/rbd/` or `src/librbd/` | `rbd` |
| `src/client/` | `client` |
| `src/common/` | `common` |
| `src/msg/` | `msg` |
| `src/test/` | `qa` |
| `qa/` | `qa` |
| `doc/` | `doc` |
| `cmake/` or `CMakeLists.txt` | `cmake` |
| Multiple unrelated subsystems | use the dominant one or `ceph` |

## Step 3 — Compose the commit message

Follow this format exactly:

```
<component>: <Short imperative summary, max 72 chars>

<Optional body: 1–3 short paragraphs explaining *why* the change is
needed and *what* it does. Wrap at 72 chars per line. Omit if the
subject line is self-explanatory.>

Signed-off-by: Tom Sollers <tom.sollers@ibm.com>
```

Rules:
- Subject line: imperative mood ("Fix", "Add", "Remove", "Implement"), no trailing period, max 72 chars.
- Blank line between subject and body, and between body and trailers.
- Body explains motivation/context — not a list of every line changed.
- Always use the hardcoded `Signed-off-by: Tom Sollers <tom.sollers@ibm.com>` trailer.
- Do NOT add `Assisted-by` unless the user asks for it.

## Step 4 — Present the message

Show the full commit message in a fenced code block so the user can copy it directly or run:

```bash
git commit -m "<subject>" -m "<body>"
```

Or suggest they pipe it with:

```bash
git commit -F - <<'EOF'
<full message>
EOF
```

Do **not** run `git commit` automatically — present the message and let the user decide.
