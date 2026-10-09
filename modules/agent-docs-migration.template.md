# Agent docs migration brief for {{REPO}}

<!-- Written by Initialize-OctoAgentDocs on {{DATE}}. {{BRIEF}} is a WORKING FILE for the
     migration: Test-OctoAgentDocs warns while it exists (rule migration-pending). Delete it
     in the commit that completes the migration. -->

This repository still carries its agent instructions in `CLAUDE.md`. The target shape is one
canonical entry point, `AGENTS.md`, that every coding agent reads, a two-line `CLAUDE.md` shim that
imports it, and the detail moved into path-routed documents under `docs/`. These instructions are
for the coding agent doing the migration together with a developer. Nothing here was derived
from this repository's source; every value below comes from the ruleset that `Test-OctoAgentDocs`
enforces.

## Target shape

```
AGENTS.md          the entry point, loaded in every session; pointers and rules only
CLAUDE.md          the shim, exactly these lines and nothing else:
{{SHIM}}
docs/<topic>.md    one topic per file, with frontmatter that routes it (see below)
```

`AGENTS.md` carries these level-2 sections (the checker requires their presence, not their order), with
the routing markers under the first:

{{SECTIONS}}

```markdown
{{START_MARKER}}
{{END_MARKER}}
```

Every `docs/*.md` starts with a frontmatter block of single-line `key: value` entries. `applies_to`
is a comma-separated list of path globs; a change under one of those paths is what makes an agent
open the file.

```yaml
---
description: One line that lets an agent decide whether to open this file.
applies_to: src/Area/**, tests/Area/**
---
```

Reference material that no path change should trigger uses `background: true` instead of
`applies_to`. A doc has one or the other, never both and never neither.

## Budgets

The checker holds the result to these limits. They are context cost for the agent, not style.

{{BUDGETS}}

## Steps

Run `Test-OctoAgentDocs -Path {{PATH}}` after every step, not only at the end. The output names the
rule behind each finding; `Test-OctoAgentDocs -Explain -Rule <id>` explains why it exists and
what to do.

1. **Read `CLAUDE.md` once, end to end.** List its level-2 and level-3 sections. For each, note
   whether it is a rule or pointer every session needs, or detail that matters only when a
   particular part of the code changes. Do not rewrite anything yet.
2. **Create `AGENTS.md`** with the required sections above and the routing markers. Move the
   session-wide material into it: how to build and test, what to do before a commit, the rules
   that apply everywhere. Keep its budget in mind from the start.
3. **Move the detail into `docs/`,** one topic per file, with frontmatter. Move text verbatim.
   Shortening, merging and deleting are the developer's decisions, made in review, not the
   agent's; what you believe is obsolete goes into a list for the developer, not into the bin.
   Give each doc `applies_to` globs for the paths it explains, or `background: true`.
4. **Replace `CLAUDE.md` with the shim.** Run `Test-OctoAgentDocs -Path {{PATH}} -Fix`. It writes
   the shim only when `CLAUDE.md` is already empty of real content, so empty the file first by
   moving its last sections, then run `-Fix`. Never pass `-Force` to skip that check.
5. **Generate the routing table** with the same `-Fix` run. The table is derived from the docs'
   frontmatter and is regenerated on every `-Fix`; never edit it by hand.
6. **Fix every finding** until the checker reports clean. `-Fix -WhatIf` names what a `-Fix`
   would write without writing it.
7. **Delete this file** (`{{BRIEF}}`) in the same commit. The commit message follows the
   repository's convention and names the work item.

Rules for the agent during the migration:

- English only. These files are published with the repository.
- Move, do not rewrite. A sentence that was correct in `CLAUDE.md` is correct in its new home.
- The checker never writes prose. A missing section or description is yours to write, and you
  write it from what the repository does, not from what a template suggests.
- `-Fix` is yours to run. It regenerates the two derived regions and nothing else, and it refuses
  to overwrite content it does not own.
- When a budget is exceeded, split by topic before you trim, and trim before you ask for a higher
  limit. A higher limit in `.agent-docs.json` needs a reason in the pull request.

## What the checker will say, in the order to fix it

{{RULES}}
