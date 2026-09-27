# Public PR CI

Phase 3A, 4I and 4J jobs run on standard GitHub-hosted Ubuntu 24.04. Fork PRs run the existing
acceptance commands without private/same-repository guards, secrets or persistent
checkout credentials. Read-only contents permission and existing timeouts apply.
No shared cache or privileged downstream artifact consumer is introduced.
Actions are pinned by full SHA. All main-target PRs run checks, avoiding pending
required checks on path-filtered changes. Source pushes and synthetic PR merges
must be tracked separately in evidence.

The no-radio Pulse/Docker adapter and accepted HERMES/Mercury/Rust pins are
unchanged. Passing these checks does not accept unreviewed upstream changes, RF operation
or production security.

Administrators must exclude this repository from every trusted self-hosted
runner group and repository-scoped runner whenever configuration changes. PR workflow edits
can select different runners; current YAML cannot enforce that external boundary.
Local workstations and hardware labs remain deliberate maintainer operations,
never automatic public PR targets.

Protected main requires phase3a, phase4i and auth. Exact-head hosted validation
and an end-to-end external non-write fork test are separate evidence. The latter
remains unverified; source publication does not imply it passed.
