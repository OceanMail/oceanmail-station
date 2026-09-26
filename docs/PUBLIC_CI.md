# Public PR CI

Publication preparation for OceanMail/oceanmail-project#42 moves Phase 3A, 4I and
4J jobs to standard GitHub-hosted Ubuntu 24.04. Fork PRs run the existing
acceptance commands without private/same-repository guards, secrets or persistent
checkout credentials. Read-only contents permission and existing timeouts apply.
No shared cache or privileged downstream artifact consumer is introduced.
Actions are pinned by full SHA. All main-target PRs run checks, avoiding pending
required checks on path-filtered changes. Source pushes and synthetic PR merges
must be tracked separately in evidence.

The no-radio Pulse/Docker adapter and accepted HERMES/Mercury/Rust pins are
unchanged. This migration does not accept candidate upstream changes in
PRs #51/#52, quality work in #59, RF operation or production security.

Administrators must exclude this repository from every trusted self-hosted
runner group and repository-scoped runner before publication. PR workflow edits
can select different runners; current YAML cannot enforce that external boundary.
Local workstations and hardware labs remain deliberate maintainer operations,
never automatic public PR targets.

Required-check candidates are phase3a, phase4i and auth, after exact-head hosted
validation. No branch protection or organization settings are changed here.
Actual external non-write fork acceptance remains a publication gate.
