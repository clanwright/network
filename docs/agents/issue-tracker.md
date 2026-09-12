# Issue tracker: GitHub

Tasks and proposed feature specifications live in GitHub Issues for
`clanwright/network`. Use the `gh` CLI with the existing authentication.

Read the issue body, labels, and comments before acting. Check existing
issues before creating a new one. For multiline issue bodies and comments,
use a local UTF-8 file with `--body-file`.

“Publish to the issue tracker” means create a GitHub issue.
“Fetch the relevant ticket” means read that issue and its comments.

Issue specifications describe requested changes. After implementation,
update the canonical project documentation reached through README.md.
Keep temporary plans and check logs in the ignored `.work/` directory.

Issue operations remain within the user's authorized task scope.
Tracker configuration and readiness labels do not grant approval for
protected operations defined in AGENTS.md.

## Pull requests as a triage surface

**PRs as a request surface: no.**

## Wayfinding

Use one issue labelled `wayfinder:map` for Notes, Decisions-so-far,
and Fog. Link child tickets as sub-issues; if unavailable, use a task
list in the map and a `Part of #<map>` reference in each child.

Use `wayfinder:research`, `wayfinder:prototype`, `wayfinder:grilling`,
or `wayfinder:task` for child ticket types.

Represent blockers with native issue dependencies when available;
otherwise use `Blocked by: #<number>` references. Select unassigned
open children with no open blockers in map order.

Claim by assigning the driving developer. On completion, record the
result, close the ticket, and update the map's Decisions-so-far.
