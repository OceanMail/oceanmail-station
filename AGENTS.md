# OceanMail Station — Agent Instructions

These repository-local instructions apply to implementation agents working in `OceanMail/oceanmail-station`.

## Organization authority

Organization-level OceanMail definition, architecture, terminology, repository inventory, cross-repository decisions, current project state, and AI/contributor workflow are authoritative in [`OceanMail/oceanmail-project`](https://github.com/OceanMail/oceanmail-project).

Before substantial Station work, read there in order:

1. `PROJECT.md`
2. `CURRENT_STATE.md`
3. `DECISIONS.md`
4. `REPOSITORIES.md`
5. `workstreams/station.md` and, as applicable, `workstreams/hermes-mercury.md` / `workstreams/identity-accounts.md`
6. relevant project ADR/interface/terminology documents

Then read this repository's `docs/CURRENT_STATUS.md`, `docs/STATION_ARCHITECTURE.md`, security/upstream/contract documents, source, open PRs/issues, and tests.

The organization role split and architecture-escalation process are defined by `oceanmail-project/AGENTS.md`. This file adds Station-specific constraints only.

## Station boundaries

- Preserve the STORE / TRANSPORT versus GRID / CONTROL separation in `docs/STATION_ARCHITECTURE.md`.
- Do not duplicate authoritative payload stores/queues already owned by Postfix, Taylor UUCP, Dovecot/mailbox storage, HERMES/Mercury, or later accepted store/transport components.
- HERMES and Mercury remain upstream-first dependencies. Keep exact accepted pins and downstream integration deltas explicit, narrow, auditable, provenance-tracked, and license-preserving.
- Do not start physical-radio Phase 5 work without explicit owner/project-lead authorization.

## Current mail policy

- OceanMail 0.2 user-originated transport classes are Emergency and Ordinary only.
- There is no ordinary sender-selectable Priority transport class.
- `Important` is interoperable message metadata only and must not change RF/Station/relay precedence, gateway/path selection, credits/quota treatment, or automatic Available retrieval ordering.
- Recipient-controlled Available ordering is intent inside ordinary local-account work; Station remains authoritative for fairness, age protection, Emergency preemption, and actual link scheduling.

## Available/account privacy

- `docs/AVAILABLE_MANIFEST_ACCOUNT_CONTRACT.md` is the current logical foundation for Available/account authorization.
- Available is private recipient metadata describing content held elsewhere before constrained-link payload transfer; it is not IMAP, already-local mail, or outbound queue history.
- Authenticate the principal and enforce explicit principal-to-account grants before disclosing recipient-private manifest, plan, or accounting metadata.
- Loopback binding, account/message IDs, email strings, device pairing, Captain/Admin authority, and Desktop-side filtering are not authorization boundaries.
- Holder-side disclosure must also be recipient/account-authorized or equivalently end-to-end confidential before private manifest metadata leaves the holder.
- Station-less hosted/Lite direct-Internet operation must retain equivalent authentication/account-grant/durable-plan/privacy semantics at the hosted Server.
- Native boat-to-boat OMail availability must not require the central Server.

## Evidence truthfulness

Never claim stronger evidence than the source proves.

- `left_postfix_queue` is Postfix disappearance only.
- `uucp_job_created` proves exact queued Taylor work only.
- caller/process success is not remote receipt.
- `remote_mailbox_receipt_observed` is exact far-side mailbox evidence, not human-read status.
- Phase 4I `returned_remote_receipt_observed` proves returned laboratory receipt arrival/validation/correlation at trust `lab_peer_transport_unverified`; it is not production cryptographic peer authentication.

## Security/API discipline

- The Station API remains conservative until accepted authentication/authorization permits broader exposure.
- Do not describe loopback as authorization.
- Production storage/key-separation gates are independent of API authentication.
- Captain/Station administrative authority does not inherently grant personal mailbox decryption or Available metadata access.
- Fail closed where authorization, accounting permission, trust, or required evidence is unknown.

## Current parallel work

Before changes, inspect current `main`, open PRs/issues, and `docs/CURRENT_STATUS.md`. Preserve review/evidence lineage for compatibility, upstream-integration, and accepted proof work. Do not overwrite independent active branches.

## Testing and handoff

Separate evidence into:

```text
STATIC / UNIT
INTEGRATION
LIVE / PRODUCT
```

Do not describe CI/unit/lab evidence as live product or RF verification.

Before handoff, run applicable repository checks and report exact branch/HEAD, changed files, evidence, blockers, and PR/CI state. Update `OceanMail/oceanmail-project` when Station work changes organization-level architecture, terminology, cross-component contracts, or settled semantics. Follow merge authority in the central project instructions.

## S1 quality measurement

Read [the report-only tooling guide](.quality/README.md) before measurement. Use `bash .quality/bootstrap.sh`, source `.quality/tools/env.sh`, run `python3 -m unittest discover -s .quality -p 'test_*.py' -v`, then `python3 .quality/measure.py --out /absolute/report/path`. Preserve raw output, exact source/config/tool provenance and failed/partial checks. Run existing no-radio acceptance with workflow_dispatch on the exact task head because these paths do not automatically trigger CI. Every retrofit PR receives independent Claude review; owner retains merge authority. S1 does not authorize formatting cleanup, suppression/baseline generation or enforcement. No CLAUDE.md convention exists here; these shared instructions apply to all agents.
