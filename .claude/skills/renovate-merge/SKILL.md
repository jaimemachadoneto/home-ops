---
name: renovate-merge
description: Use when the user asks to merge, process or catch up on the open Renovate PRs of home-ops, or to keep the cluster dependencies current.
model: sonnet
disable-model-invocation: true
---

# Merge the Renovate PRs of home-ops

Merge the open Renovate PRs one at a time, in a safe sequence. After each merge, Flux must apply it and the cluster must be healthy before the next merge. Scripts make every check; their exit code is the result. Opus decides the risky cases. The user decides only what Opus cannot decide, or what is on the "always ask" list.

**A violation of the letter of these rules is a violation of their spirit.**

## The plan note

The note `~/Notes/10 - Projects/home-ops/Renovate merge plan <YYYY-MM>.md` holds the state. A later session continues from it.

- Use the note of the current month. If it does not exist, copy the open rows of the last note into a new note.
- Give each PR one row: number, what, risk class, status. Status is `todo`, `merged`, `waiting for user`, `deferred` or `closed`, with a short reason.
- After each change to the note, commit and push in `~/Notes`. **REQUIRED SUB-SKILL:** Use `notes`.

## Scripts

Run the scripts with `bash` from the home-ops repository root. `S=.claude/skills/renovate-merge/scripts`.

| Script | Exit codes |
| --- | --- |
| `bash $S/classify.sh` | 0 done, 1 the list is possibly cut |
| `bash $S/wait.sh <sha> <merged_at> [timeout]` | 0 healthy, 1 failure, 2 timeout |
| `bash $S/precheck.sh <pr>` | 0 ready, 10 wait and run again, 20 not mergeable, 30 checks fail |
| `bash $S/crd-diff.sh <pr>` | 0 same CRDs, 3 new CRDs that Flux applies, 4 new CRDs that Flux does not apply, 2 unknown |
| `bash $S/backup.sh <namespace> <app> [--postgres]` | 0 backups complete, 1 failure, 3 no data to copy |
| `bash $S/merge.sh <pr>` | 0 merged, prints `sha=<sha> merged_at=<epoch>`; 1 merge failed; 2 Flux did not fetch |

Any other exit code is a script error. Examine the output, and do not merge.

`precheck.sh` ignores two failures on purpose. The lint jobs fail because of style errors already on `main`, and the user decided to ignore them. A flux-local job that fails only at "Add Comment" rendered correctly, but the diff is too long for a comment.

## The loop

1. Run `bash $S/wait.sh $(git rev-parse origin/main) 0 120`. If the exit code is not 0, stop and escalate. Do not merge into a cluster that is not healthy.
2. Run `classify.sh`. It gives each open PR its phase, risk class, "always ask" mark and pair. Add each PR that has no row to the note, with these values. Do not change a class to a lower class.
3. Take the next row with status `todo`, in the sequence of `classify.sh`.
4. If a row has a pair, do the minor or patch PR first. Renovate then rebases the major PR, which keeps its own class.
5. For a `low` or `medium` row, run `precheck.sh` and `crd-diff.sh`.
   - If `precheck.sh` gives 10, take the next row and come back later.
   - If `precheck.sh` gives 20 or 30, or `crd-diff.sh` gives 2 or 4, change the class to `review`.
6. For a `review` or `high` row, give the `renovate-facts` agent the PR number. Write its facts and the `crd-diff.sh` output in the row. If the row has the "always ask" mark, set it to `waiting for user`. Else escalate.
7. If the app keeps data that the new version can change, run `backup.sh` first.
8. Run `merge.sh`, then `wait.sh <sha> <merged_at>`.
9. If `wait.sh` gives 0, set the row to `merged`, then commit and push the note.
10. If `wait.sh` does not give 0, write an incident in the note and escalate. Stop the loop until the cluster is healthy.
11. Go to step 3. At the end, give the user the list of rows with `waiting for user`.

## Risk classes

`classify.sh` gives the class from the title and the changed files. The facts are there, so a script decides, not a model.

| Class | When |
| --- | --- |
| `low` | A digest or a patch version of a leaf app, an AI app or a CI action |
| `medium` | A minor version, a patch of infrastructure, or a patch of a data store |
| `review` | A major version, or a new year of a calendar version. Also a minor version of a data store, or a title without versions. |
| `high` | A major version of a data store, or any change to the platform (Talos, Kubernetes, Flux) or to secrets |

A step of the loop can raise a class: a check that fails, or a CRD change. Nothing lowers a class.

## Escalate to Opus

Give the `renovate-escalation` agent the row, the facts and the output of the scripts. The agent decides, acts once, and returns its decision. Write its decision and its reason in the row.

- If the agent returns `ask-user`, set the row to `waiting for user`. Continue with the rows that do not depend on it.
- If the cluster is not healthy after its action, stop the loop and tell the user.

## Always ask the user

Opus does not decide these cases. Set the row to `waiting for user`.

- A major version of a data store: Postgres, Dragonfly, Ceph, VolSync, Kopia, or an app database.
- Any change to the platform (Talos, Kubernetes, Flux) or to secrets (External Secrets, 1Password Connect).
- A data migration that a person must do: an export and an import, `pg_upgrade`, or a migration command. An app that migrates its database at start is not on this list. For that app, run `backup.sh` before the merge.
- A restore, or a PVC delete.
- A change to credentials.
- A revert after the new version started, if the version migrates its database at start.

## Recover through git only

- To undo a merge, run `gh pr revert <pr>`, then merge the revert PR with `merge.sh` and run `wait.sh`.
- After a revert, Renovate opens the same update again. Close that PR with the reason, so Renovate skips the version.
- To make a config change that a Renovate PR needs, open a separate PR to `main` and merge it first. GitHub refuses a push to a `renovate/*` branch.
- If `crd-diff.sh` gives 4, the usual config change sets `install.crds` and `upgrade.crds` to `CreateReplace` in the HelmRelease.

## Rationalizations

| Excuse | Reality |
| --- | --- |
| "The release notes are clean and I took a backup, so I can merge this major version." | A major version of a data store is on the "always ask" list. Ask. |
| "It is a small app. A revert is routine." | The new version can migrate the database at start. The old version cannot read it. Ask. |
| "Batches of five save time. The apps do not depend on each other." | One merge at a time. A failure in a batch has no clear cause, and a revert of a batch reverts good updates. |
| "A lint check that fails is a real signal. I fix it first." | The user decided to ignore these lint errors. `precheck.sh` knows them. |
| "`helm rollback` is faster than a revert PR." | Flux applies git again and undoes the rollback. Recover through git. |
| "CI is green, so the chart upgrade is safe." | CI does not compare CRDs. Run `crd-diff.sh`. |
| "Renovate offers the newest version, so a direct upgrade is correct." | Some software needs one major version at a time. Opus examines the upgrade path. |
| "This PR looks low, `classify.sh` is too careful." | Keep the class of `classify.sh`. Only raise a class. |
| "The cluster has one small problem, but it is not from this PR." | `wait.sh` must give 0 before the next merge. |

## Red flags: stop

- You want to merge two PRs before `wait.sh` gives 0.
- You want to merge a row on the "always ask" list.
- You want to use `helm`, `kubectl edit` or a database command to correct a failure.
- You want to retry a failed action a second time.
