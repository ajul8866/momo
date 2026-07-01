# Agent Instructions

## Repo docs

The living project guide is in `repo-docs/`. Start with `repo-docs/README.md`; when `repo-docs/walkthroughs/one-real-run.md` exists, use it as the main behavior trace. The guide documents the `vuln-mine` mining loop in depth and summarizes the `vuln-target-prep` upstream path.

Repo-docs sync triggers before the final response when you: answer repo questions ("how does this work", onboarding, architecture); make behavior-bearing edits to code, config, data, scripts, or tests under `.claude/skills/`; hit user uncertainty or a correction about stable project behavior; surface or clarify stable project knowledge in conversation; or are about to write project knowledge to memory.

When a trigger fires, run a foreground repo-docs sync gate before answering: use the `repo-docs` skill in Sync mode when available (otherwise manually read the relevant `repo-docs/` pages and inspect current source), then decide whether the guide is missing, stale, wrong, or incomplete.

Patch the smallest owning guide page before your final response when the current answer depends on a correction, or stale/missing guide content would mislead the user now: behavior path changed → `walkthroughs/one-real-run.md`; concept changed or clarified → the matching `modules/` page; an exact field, command, schema, manifest rule, or contract changed → `references/manifest-contract.md` or `references/source-evidence.md`; a term's meaning changed → `glossary.md`; a material sync happened → `change-log.md`.

If broader guide work is needed but not required for the current answer to be correct, delegate it to a background `repo-docs` sync agent when the platform supports a tracked handoff. If no background agent is available, make a scoped foreground patch or explicitly mention the pending doc sync — do not silently defer.

A user does not need to explicitly ask for memory sync. If stable project knowledge is missing from `repo-docs/`, patch the smallest owning guide page before leaving the knowledge only in chat or agent memory. When behavior-bearing code, config, data, scripts, or tests change, compare the change against the guide before finishing unless the user asked you not to touch docs. Record meaningful guide updates in `repo-docs/change-log.md` with verification and `Synced through <commit-sha>` when git is available.
