# Working on Network

Read README.md, the sole documentation index, then the relevant implementation
and docs/contracts.md. Runtime code and evaluated configuration outrank prose.
Keep each fact with its canonical owner; adjacent service READMEs own detailed
settings, docs/contracts.md owns integration boundaries, and docs/operations/
owns operator command sequences.

Implement only the agreed objective and assigned paths. Preserve unrelated
changes. Keep temporary plans and readable check logs in an ignored local work
area. Give editing workers exclusive file ownership. Substantial changes require
independent findings-first review and resolution of material findings, followed
by the relevant existing checks in docs/operations/verify.md.

Runtime support is x86_64-linux only. Darwin formatter availability is a developer
tool, not runtime support. Network development and verification must not create
or use virtual machines, including NixOS VM tests and QEMU/KVM; use the existing
x86_64-linux builder and process/namespace checks. Do not add architectures, a
generic provider/plugin framework, consumer package overrides, hosted CI, or
automatic merging. New public settings need a concrete consumer need and a
Network release. Dependency versions and package construction have one authority
in this repository.

Never print or persist credentials, decrypted secrets, private keys, passwords,
or live client profile URLs. Inspect secret names and runtime paths only.
Provider/DNS, live ACME, deploy, backup writer, restore/prune, and credential or
secret mutations require separate explicit owner approval. Local checks do not
authorize those actions. Release and consumer adoption are separate transactions;
do not describe an unverified checkout as released.
