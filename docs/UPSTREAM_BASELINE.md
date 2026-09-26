# OceanMail Station — Upstream Baseline

Snapshot baseline: 2026-09-03. Reciprocal-session integration delta accepted in no-radio Phase 4I on 2026-09-10.

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

Current reproducible baseline: **v1.9.13**, commit `4eac25e06a0c88996621bc74af5b7b2f0d353848`.

Development branch to track: `mercuryv2`.

Why:

- Mercury v2 is the upstream-recommended implementation.
- It exposes a VARA-style TCP TNC interface: control on the base port and data on base+1.
- HERMES `uucpd` already consumes that interface; OceanMail does not need a modem-specific transport shim.
- Mercury includes a two-instance ALSA loopback testbed (`utils/loopsim`) that can exercise two real modem instances on one Linux host without radio hardware.
- Phase 4I additionally proved exact pinned Mercury through a disposable Debian/PulseAudio container on the OceanMail self-hosted runner, avoiding a host `snd-aloop` requirement while preserving the same TCP TNC boundary.
- Pinning v1.9.13 gives the current lab a repeatable input while upstream development continues.

License note: the repository is identified by GitHub as GPL-3.0. Preserve upstream license/notices and re-check the exact applicable terms before distribution.

### HERMES networking (`hermes-net`)

Repository: https://github.com/Rhizomatica/hermes-net

Current baseline commit: `5c76adff754de49c0b934c7fd7bddf7619b0c3d6`.

Critical pieces:

- `uucpd` — bridges UUCP/uucico to ARDOP/VARA-compatible TNCs, including Mercury.
- `uuport` — UUCP pipe transport used by uucico to reach `uucpd`.
- `uuxcomp` — mail-oriented UUCP wrapper/compression tooling for the end-to-end email path.

The upstream Mercury systemd configuration intentionally runs `uucpd` with the VARA backend against Mercury on TCP base port 8300. OceanMail uses that compatibility boundary rather than adding a Mercury-specific protocol inside OceanMail.

License note: do **not** infer the `uucpd` license from the repository-level GitHub badge. `uucpd/LICENSE` is GNU AGPL v3 and the README also contains inconsistent GPL/AGPL wording. Treat `uucpd` as AGPLv3-covered for OceanMail planning unless clarified upstream. Keep it as a separate upstream program and preserve its applicable source/license obligations for any downstream modification/distribution.

#### Accepted Phase 4I laboratory integration patch

Phase 4I exposed a rapid reciprocal-session defect at this exact HERMES pin. After a completed A -> B UUCP conversation, stale end-of-conversation bytes could remain in HERMES's persistent VARA/Mercury TCP data stream and appear at the start of the B -> A session. Taylor then received old `OOOOOO` bytes where the new slave `Shere` greeting was expected.

OceanMail therefore carries one narrow tracked laboratory patch:

```text
lab/phase1/hermes-vara-discard-stale-data.patch
```

Against exact HERMES commit:

```text
5c76adff754de49c0b934c7fd7bddf7619b0c3d6
```

The patch:

- discards a blocking data read if the session has already transitioned to disconnected;
- drains retired TCP tail bytes during the old-session cleanup boundary;
- emits `Connection cleanup complete.` after final buffer reset and cleanup-state clearing.

The self-hosted Phase 4I workflow requires `git apply --check`, applies the patch only to the exact pin, compiles `uucpd`/`uuport`, and then runs the full returned-receipt acceptance. Accepted run `34517583360` passed and is recorded in [`PHASE4I_RETURNED_RECEIPT_EVIDENCE.md`](PHASE4I_RETURNED_RECEIPT_EVIDENCE.md).

This is an accepted **laboratory integration delta**, not a declaration that OceanMail owns or has forked HERMES architecture. It does not authorize unreviewed downstream changes. A production/distribution decision must revisit upstream status, licensing/source obligations, and whether the fix can be carried upstream or the pin advanced to an upstream resolution.

### libcmime

Repository: https://github.com/spmfilter/libcmime

Role: MIME dependency used by the HERMES `uuxcomp` / `crmail` mail-compression path in the Phase 2B-derived laboratory images.

Current reproducible baseline: **0.2.2**, commit `dd21eb096d162656e30243f60fc4bc35ad39ae6e`.

License note: `COPYING` at the pinned commit is the MIT License. Preserve the copyright/license notice when distributing copies or substantial portions.

#### Current laboratory build delta

The Phase 2B image applies [`libcmime-empty-sender.patch`](../lab/phase2b/libcmime-empty-sender.patch) only to exact commit `dd21eb096d162656e30243f60fc4bc35ad39ae6e`, with `git apply --check` before application. The patch replaces `asprintf(&sender, "");` with `sender = "";` in `cmime_message_set_sender`.

This makes the existing laboratory edit explicit; it does not introduce a new behavior change. Static comparison against the pinned upstream file proves the patched bytes equal the previous Dockerfile substitution (patched file SHA-256 `066607f2917f618f00fd373be1207ec911e59507f0c11540c0d30eccf8d49869`). The original call passes the address of a `const char *` to an allocation API expecting `char **`. The existing replacement supplies the empty fallback directly. The original historical diagnostic is not available, so this is a source-level compatibility rationale, not a reconstructed claim about an old build failure.

The upstream MIT [`COPYING`](../lab/phase2b/libcmime-COPYING) is preserved beside the patch. The final laboratory image copies upstream `COPYING` directly from the pinned checkout and includes [`libcmime-NOTICE`](../lab/phase2b/libcmime-NOTICE), including source-file attribution and the downstream delta. Image construction asserts both notices exist.

The Phase 3A mail-client and Phase 4I returned-receipt acceptance must pass on this change before merge. No production suitability or complete combined-image license clearance is claimed. Upstream resolution, source obligations for other components, and the chosen OceanMail license remain separate publication/distribution gates.

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
