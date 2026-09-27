# HERMES session-retirement patch provenance

**Temporary downstream integration delta pending upstream resolution.**

- Repository: https://github.com/Rhizomatica/hermes-net
- Exact upstream SHA: `0fee4a53f54074ad6237b9fa1083a272cac89f60`
- Artifact: `hermes-vara-discard-stale-data.patch` (historical filename, retirement replacement).
- SHA-256: `4c5f2d17092eca8c685fbe18017c18b8803d1c0e47a4a25477dd0a06ae262136`
- Scope: eight files under upstream `uucpd/`; no permanent OceanMail modem fork.
- Reason: old bridge writes and retained RX/TX bytes contaminate subsequent sessions; negative TCP reads/EINTR are mishandled.
- Reproducer/tests: [HERMES_SESSION_REPLACEMENT.md](../../docs/HERMES_SESSION_REPLACEMENT.md).
- Selection/evidence: [UPSTREAM_RECONCILIATION.md](../../docs/UPSTREAM_RECONCILIATION.md).

The build rejects any other SHA, runs `git apply --check`, and records the upstream
SHA and patch digest in the image. Rebuild and restart **both uucpd and uuport**:
the shared connector includes a semaphore identifier. The replacement patch
preserves upstream's pre-agreed startup, duplicate disconnect handling and 90-second
teardown fallback, but waits for bridge workers before reopening the session.

Attribution: source retains Rhizomatica copyright and Rafael Diniz's authorship
notices. Source headers say GPL-3.0-or-later; `uucpd/LICENSE` is AGPLv3. The original
LICENSE is copied unchanged into the image. This notice does not relicense upstream;
treat the component as AGPLv3-covered pending clarification. Test sources retain
GPL-3.0-or-later notices. AI-assisted changes require normal code review.

Limitations: a permanently stopped bridge or infinite stale stream prevents
retirement; death inside an existing shared-ring spinlock can still require restart.
TCP loss requires daemon restart. Untagged streams cannot classify arbitrarily late
old modem output. No ARDOP session, physical RF or production-security proof.

Removal criteria: advance to an exact upstream SHA that passes the behavioral
regressions unmodified and full combined Pulse/UUCP/interruption/returned-receipt
acceptance. Delete patch/application; retain permanent regression tests.

Startup atomically claims bridge and daemon semaphore slots before touching shared
rings. An active daemon or surviving bridge makes startup fail closed. The set is
reused after process death; it is never removed or reset on restart. An older
one-slot semaphore set is incompatible and also fails closed; stop all old
processes and use a fresh IPC namespace when upgrading from a one-slot implementation.
