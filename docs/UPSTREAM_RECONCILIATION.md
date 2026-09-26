# HERMES / Mercury reconciliation — 2026-09-26

Selection proposed from public main `77974bc617b07a707e9381399477eae93061f645`.
Public PR checks and their exact source/run identities are recorded in the PR;
merge requires owner approval. No upstream issue/PR is submitted by this work.

## Exact inputs

| Component | Historical | Current evaluated / proposed |
| --- | --- | --- |
| HERMES | `5c76adff754de49c0b934c7fd7bddf7619b0c3d6` | `0fee4a53f54074ad6237b9fa1083a272cac89f60` |
| Mercury | v1.9.13 `4eac25e06a0c88996621bc74af5b7b2f0d353848` | development `638193b9a9cc5ab15f272805af116e94b2fdf4c6` |
| Mercury archive candidate | `f8e3935909f845e99d783b7ff99be86c4cebb910` | superseded as a selection target |
| Mercury latest release | v1.9.15 | `8a47831882c9751b1fee5bcbf5f9de11fb46ac4b` |

Proposed combined input: exact current HERMES + the explicit temporary retirement
patch + unmodified current Mercury. HERMES `uuxcomp`/`crmail` use the same current
SHA without a patch. All runtime build paths and evidence headers use these pins.

## Upstream findings

HERMES since the old pin adds pre-agreed startup (`8c40edf`, off by default),
service packaging, and late/duplicate DISCONNECTED handling (`d49979e`, `971ac57`,
`872709d`). These changes do not join old bridge workers, serialize RX/TX with
retirement, invalidate retained TX generations, drain stale socket data or fix
`tcp_read` negative/EINTR handling. The unchanged ring and bridge lifecycle paths
remain vulnerable in the executable comparisons; commit descriptions alone were
not treated as evidence of resolution.

HERMES also rewrites email-header handling and removes libcmime (`7ac4fbc`), with
a build-time raw-mail option (`e358109`). The default compressed path is retained.
The libcmime build, compatibility patch and distribution notices are removed from
the new image because that dependency no longer exists; historical evidence stays
in Git. Phase 3A and returned-mail acceptance gate the changed upstream parser.

Mercury after v1.9.13 changes ARQ turn contention, connect-during-teardown, broadcast
framing, audio/PTT paths and the UI WebSocket implementation. The archive's normal
shutdown fix (`78d3e6a`) is included in released v1.9.15. Later development adds
forced-exit unkey (`9e58d4b`, `4e7c255`), stale-RX isolation (`bab3040`, `f7a3d70`),
ended-session resurrection prevention (`26c82a1`), and turn/disconnect listen-before-
transmit and combined ACK/data changes. It reverts the enlarged ALSA/Pulse buffer,
adds RTP audio and compiler/linker flag propagation. The latter features are not
enabled by OceanMail. OpenSSL development support is included for current builds.

These post-release lifecycle fixes justify evaluating development head rather
than promoting the older archive candidate or v1.9.15 just because either was
previously tested. The VARA-compatible TCP interface remains the integration
boundary. No Mercury patch is carried.

## Fresh validation and acceptance

`upstream-regression.yml` compares four HERMES variants and builds/tests all four
Mercury revisions above, including deterministic Pulse byte transfer for each.
The normal, ASan/UBSan and TSan retirement suites retain exact logs/results.
The existing required `auth`, `phase3a`, `phase4i` job identities are preserved.
The combined `phase4i` job adds durable interrupted-transfer retry before its
unchanged returned-receipt acceptance. All run on GitHub-hosted Ubuntu 24.04 with
credential-free checkout and pinned Actions. No deleted private runner is needed.

Local diagnostics: current Mercury builds and passes 465 upstream unit tests.
Current unmodified HERMES fails retained TX, stale tail, in-flight RX, delayed
bridge and three TCP error probes while basic greeting/binary controls pass.
The replacement corrects those probes. The PR's fresh public CI results determine
acceptance; this document does not declare pending CI successful.

STATIC / UNIT is distinct from INTEGRATION. No LIVE / PRODUCT, physical RF,
preemption, Broadcast or production-security qualification is claimed.

## Archive disposition and upstream follow-up

From #52 retain the isolated retirement fix, lifecycle/net regressions, provenance
and limitations. Rebase against current upstream and add duplicate/late-disconnect
coverage. Discard the obsolete reviewed-head comparator, private review JSON
bundles and old workflow duplication; retain the old small patch only as a test
fixture. No archive commit history is merged or published.

The archive's unresolved restart review finding is fixed, not ported unchanged:
daemon startup now atomically preserves/excludes live bridge and daemon claims
before replacing shared memory. A new process-death/restart regression covers it.

From #51 retain exact-source verification, upstream tests, container retry path and
actual container provenance. Replace candidate-specific Dockerfile/workflow with
the normal build and permanent comparison coverage. Do not retain `f8e3935` as the
default or introduce a Mercury downstream fork.

After all exact-head public checks pass, these items account for the technical
value of #52 and #51; archive branches may then be retired by the owner. Until
then, keep both. This task never deletes them.

A focused HERMES upstream report is warranted: the reproducible comparison has
affected SHA, expected/actual bytes, real bridge lifecycle, proposed patch and
before/after results. Review is needed for adoption and remaining ring owner-death
and untagged-stream limits. Mercury's related lifecycle defects already have
upstream fixes; no additional Mercury report is indicated by local passing tests.
Any fresh acceptance failure must be investigated before that conclusion is final.

The remaining reason unmodified upstream cannot be selected is the reproducible
HERMES lifecycle/TCP defects. Removal criteria are in the
[patch notice](../lab/phase1/HERMES_PATCH_NOTICE.md): upstream must pass unmodified,
then remove patch/application, retain regressions, and rerun combined acceptance.
