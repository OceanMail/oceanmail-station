# OceanMail Station — Source and release readiness

Status: **PUBLIC SOURCE — updated 2026-09-26**.

Station is published from a sanitized source snapshot with fresh history. The
installed licenses are AGPL-3.0-only for OceanMail-owned code and CC-BY-SA-4.0 for
documentation; see [LICENSING.md](../LICENSING.md) and
[PUBLICATION.md](../PUBLICATION.md). These are completed source-publication
choices, not evidence of production or RF readiness.

## Continuing source review

Keep personal contacts, field locations, workstation details, live credentials
and operational inventories out of source, logs and attachments. The generic
[test plan](testing-hardware-acquisition-plan.md) preserves staged virtual,
conducted-RF, local OTA and maritime validation, safe bench loading/attenuation,
failure/recovery tests and reproducible link/evidence metrics. Physical-radio
work still requires explicit authorization.

Review provenance, secrets, metadata and release contents when adding new
material. Current-tree checks alone do not assess every published Git object or
GitHub surface. Use the organization
[release checklist](https://github.com/OceanMail/oceanmail-project/blob/main/docs/specifications/publication-readiness.md).

## Upstream/license provenance that must be preserved

Current Station documentation already records important upstream boundaries:

- exact HERMES/Mercury/libcmime pins in `docs/UPSTREAM_BASELINE.md`;
- upstream-first separation in `AGENTS.md` and `docs/STATION_ARCHITECTURE.md`;
- the Phase 4I HERMES laboratory delta in `lab/phase1/hermes-vara-discard-stale-data.patch`;
- patch provenance/license handling in `lab/phase1/HERMES_PATCH_NOTICE.md`.

A public release must preserve those notices and re-check the exact third-party license obligations for the form actually distributed. Do not relicense upstream GPL/AGPL material as OceanMail-owned code.

## Security publication boundary

Open source does not require hiding the Station security design. It does require that public material not expose live credentials/private operational configuration or make laboratory modes look production-ready.

Preserve current security truth:

- unauthenticated LAN API exposure is not accepted;
- loopback is not authorization;
- laboratory plaintext state is not production storage readiness;
- production storage encryption/per-user key separation remain independent release gates;
- development/test identities and fixtures must remain clearly non-production.

## Contributor access and checks

Use [CONTRIBUTING.md](../CONTRIBUTING.md), [SECURITY.md](../SECURITY.md), and
[public CI](PUBLIC_CI.md). Protected main requires auth, phase3a and phase4i.
GitHub private vulnerability reporting is enabled; non-maintainer end-to-end
submission and external-fork acceptance remain unverified. Passing no-radio
checks does not establish real RF, production storage security or live product acceptance.
