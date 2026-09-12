# Domain docs

## Read order

Start with README.md, the sole documentation index. Follow its links
to the relevant implementation documentation and docs/contracts.md.
Runtime code and evaluated configuration outrank prose.

Read root CONTEXT.md when present, then any relevant ADRs in docs/adr/.
If these are absent, proceed silently.

## Layout and ownership

Use a single-context layout: root CONTEXT.md and docs/adr/.
Create them lazily when domain modeling resolves terminology or a
decision needs a durable rationale.

CONTEXT.md owns domain vocabulary. ADRs own decision rationale and
alternatives. Current behavior and settings stay with the canonical
owners established in AGENTS.md.

Add newly created domain documents to README.md's documentation index.
Keep temporary plans and unresolved proposals in `.work/` or the
issue tracker.

## Vocabulary and decisions

Use the glossary's terms when naming domain concepts. Identify genuine
vocabulary gaps for domain modeling.

Surface conflicts with existing ADRs explicitly. When changing an
accepted decision, record its replacement and update the affected
canonical documentation.
