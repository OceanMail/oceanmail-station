# OceanMail Station — Upstream Baseline

Reconciliation merged on 2026-09-26 in [Station PR #3](https://github.com/OceanMail/oceanmail-station/pull/3).
Exact-head public CI remains the acceptance gate for future changes.
See [reconciliation findings and implementation](UPSTREAM_RECONCILIATION.md).

This document records the external components selected for OceanMail 0.2 Station proofs. It is a reproducibility and boundary record, not a vendoring list.

## Policy

- Prefer unmodified upstream HERMES/Mercury components.
- Keep OceanMail-specific adapters, configuration, orchestration, queue policy, and product semantics in this repository.
- Do not copy upstream source into OceanMail merely for convenience.
- Pin reproducible lab inputs. Track upstream development separately and advance pins deliberately.
- If a proven integration defect requires a downstream patch before upstream resolution, keep the patch narrow, explicit, source-pinned, license-preserving, independently build-tested, and documented as an integration delta rather than pretending the upstream pin is unmodified.
- Prefer reporting/contributing confirmed integration fixes upstream rather than accumulating a private fork.
- Treat license compatibility as a release gate before distributing a combined product or maintaining downstream modifications.

## Critical-path components

### Mercury

Repository: https://github.com/Rhizomatica/mercury

Role: HF modem and ARQ data link.

Current reproducible input: unmodified development commit `638193b9a9cc5ab15f272805af116e94b2fdf4c6`.
Latest release evaluated: v1.9.15 (`8a47831882c9751b1fee5bcbf5f9de11fb46ac4b`).

Development branch to track: `mercuryv2`.

Why:

- Mercury v2 is the upstream-recommended implementation.
- It exposes a VARA-style TCP TNC interface: control on the base port and data on base+1.
- HERMES `uucpd` already consumes that interface; OceanMail does not need a modem-specific transport shim.
- Mercury includes a two-instance ALSA loopback testbed (`utils/loopsim`) that can exercise two real modem instances on one Linux host without radio hardware.
- Phase 4I additionally proved exact pinned Mercury through a disposable Debian/PulseAudio container on the OceanMail self-hosted runner, avoiding a host `snd-aloop` requirement while preserving the same TCP TNC boundary.
- The exact development pin includes post-v1.9.15 stale-RX, session-resurrection and forced-exit fixes; permanent comparison CI retains the earlier releases/candidate.

License note: the repository is identified by GitHub as GPL-3.0. Preserve upstream license/notices and re-check the exact applicable terms before distribution.

### HERMES networking (`hermes-net`)

Repository: https://github.com/Rhizomatica/hermes-net

Current input commit: `0fee4a53f54074ad6237b9fa1083a272cac89f60`.

Critical pieces:

- `uucpd` — bridges UUCP/uucico to ARDOP/VARA-compatible TNCs, including Mercury.
- `uuport` — UUCP pipe transport used by uucico to reach `uucpd`.
- `uuxcomp` — mail-oriented UUCP wrapper/compression tooling for the end-to-end email path.

The upstream Mercury systemd configuration intentionally runs `uucpd` with the VARA backend against Mercury on TCP base port 8300. OceanMail uses that compatibility boundary rather than adding a Mercury-specific protocol inside OceanMail.

License note: do **not** infer the `uucpd` license from the repository-level GitHub badge. `uucpd/LICENSE` is GNU AGPL v3 and the README also contains inconsistent GPL/AGPL wording. Treat `uucpd` as AGPLv3-covered for OceanMail planning unless clarified upstream. Keep it as a separate upstream program and preserve its applicable source/license obligations for any downstream modification/distribution.

#### Temporary HERMES integration patch

**Temporary downstream integration delta pending upstream resolution.**
Current unmodified upstream still fails executable delayed-bridge, retained TX,
stale RX/tail and TCP error regressions. The old drain-only patch is replaced by
the isolated session-retirement patch. Both uucpd and uuport must be rebuilt and
restarted together. Exact source SHA, patch SHA-256, licensing, reproducer,
limitations and removal criteria are in
[HERMES_PATCH_NOTICE.md](../lab/phase1/HERMES_PATCH_NOTICE.md).

Builds reject unexpected upstream SHAs and require `git apply --check` before
applying the patch. Permanent hosted regression and combined acceptance cover
the selected HERMES + patch + unmodified Mercury combination.

### libcmime — superseded dependency

Current upstream HERMES removed libcmime in its email-header rewrite. The lab
therefore removes its build, old compatibility patch and image notices. Historical
0.2.2 pin/patch evidence remains in Git; it is not part of the current image.
The compressed uuxcomp/crmail path remains enabled and is gated by fresh mail
and returned-receipt acceptance.

## Deferred upstream components

### HERMES radio daemon

Repository: https://github.com/Rhizomatica/hermes-radio-daemon

Use later when physical radio control is introduced. It supports HERMES shared-memory integration and Hamlib-class radios and already carries UUCP transfer status into its station status path.

Not required for the no-radio Mercury/UUCP proof.

License status must be checked directly before redistribution; GitHub's repository metadata does not currently identify a standard SPDX license.

### HERMES Broadcast

Repository: https://github.com/Rhizomatica/hermes-broadcast

RaptorQ/fountain-coded one-to-many delivery over Mercury broadcast mode. Potentially valuable for later OceanMail bulk synchronization, directory/manifest distribution, emergency information, and other acknowledgement-poor traffic.

Not on the first point-to-point email critical path.

### Mercury Connector

Repository: https://github.com/Rhizomatica/mercury-connector

Useful as an upstream file-transfer reference and diagnostic comparator. OceanMail's current store-forward proof uses UUCP/uucpd because that tests the actual mail-oriented path we depend on.

### Skywave

Repository: https://github.com/Rhizomatica/skywave

Use later for comparative modem/channel testing. Mercury's own two-instance simulation remains the closer current proof because it exercises real Mercury ARQ instances directly.

### HERMES GUI / backend / frontend

These remain references for HERMES station behavior, not OceanMail product dependencies for the current Station milestone.

Current upstream relationship as of 2026-09-08:

- `Rhizomatica/hermes-gui` is the established Angular HERMES station GUI.
- `Rhizomatica/hermes-frontend` is the newer next-generation frontend under development; its README describes a Next.js/React monorepo consuming `Rhizomatica/hermes-api`.
- Rhizomatica maintainer Rafael Diniz directly confirmed to OceanMail that their code is intended to be GPL-covered, including `hermes-frontend`, and invited OceanMail to send upstream PRs and create issues.
- The same maintainer confirmed that maritime/mobile operation is of interest to HERMES and specifically identified automatic gateway selection as desired future functionality.

The maintainer statement establishes upstream licensing intent, but `hermes-frontend` still does not carry a top-level `LICENSE` file in its current Git tree. For redistribution or derivative/product use, do not rely on an email statement alone: obtain or verify explicit repository license/SPDX metadata and the exact applicable terms first.

Do not infer from the new frontend repository that HERMES has already finalized the long-term boundary between `hermes-api`, the newer frontend, the existing GUI/backend, and the existing email/UUCP stack. Treat that relationship as an upstream architecture question.

OceanMail should prefer focused written technical collaboration through upstream issues/PRs and email. Candidate areas for upstream discussion include automatic peer/gateway selection, mobile/changing peers, short or asymmetric contact opportunities, and the boundary between generic HERMES store-carry-forward behavior and OceanMail-specific maritime/product policy.

## Laboratory dependency chain

```text
OceanMail test/mail handoff
            |
         UUCP spool
            |
          uucico
            |
          uuport
            |
          uucpd
            |
  VARA-compatible TCP TNC
            |
       Mercury v2
            |
  simulated audio / later HF
```

The boundary is intentional: OceanMail owns application/station policy above this chain. HERMES/Mercury owns UUCP-to-link integration and modem/link behavior below it. OceanMail evidence/orchestration may observe these components but must not silently absorb their protocol responsibilities.

## Pin/update rule

A newer upstream commit or release does not automatically replace these inputs. Update a pin or retire an integration patch only after:

1. recording the new upstream ref and applicable license/interface changes;
2. comparing the downstream patch against the new upstream source and determining whether it is still required;
3. rerunning the applicable acceptance tests, including reciprocal returned-receipt behavior where HERMES/Mercury session lifecycle is affected;
4. comparing transfer correctness, interruption/retry behavior, evidence semantics, and measured performance;
5. recording whether the resulting input is unmodified upstream or still carries an explicit reviewed delta.
