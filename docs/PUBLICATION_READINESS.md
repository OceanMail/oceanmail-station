# OceanMail Station — Publication Readiness

Status: **PRIVATE / publication review required**

This document records Station-specific findings that must not disappear when the repository-publication audit thread is retired. Organization-wide publication gates are authoritative in `OceanMail/oceanmail-project/docs/specifications/publication-readiness.md`.

This is **not** a decision that Station will or will not become public.

## Current blockers / review items

### OceanMail license not yet selected

There is currently no top-level `LICENSE` for `OceanMail/oceanmail-station`. Public GitHub visibility must not be treated as an implicit reuse license.

Select and document the OceanMail-owned code license before an approved public source release.

### Field-test plan contains private/unnecessary operational detail

`docs/testing-hardware-acquisition-plan.md` currently contains concrete development and field-test context including:

- local home/work/boat path geometry;
- generic maritime test geography;
- personal-contact categories for future remote/professional-vessel testing;
- onboard/site capabilities and available local development resources.

Those details were useful for private planning but are not required to explain the public Station architecture. Before making the existing repository/history public, either:

1. sanitize/generalize the document while preserving reusable test requirements;
2. relocate the private field-test/site/contact details to an appropriately private project/operations record; or
3. explicitly approve the specific details for publication after privacy/operational review.

Do not silently lose the generic engineering requirements: staged virtual -> conducted-RF -> local OTA -> maritime/hybrid -> regional/professional validation, safe RF bench loading/attenuation, failure/recovery testing, and reproducible link/evidence metrics remain useful Station test design.

### Existing history needs its own audit

Do not assume cleaning current `main` is enough. Historical Station commits, PRs/issues, old status/handoff documents, and acceptance evidence have contained workstation-specific names/paths, exact laboratory IDs, detailed local test context, and copied diagnostics.

Before exposing the existing history:

- run a full-history secret scan;
- review historical blobs/refs and repository-adjacent GitHub discussion/evidence surfaces;
- review commit metadata and attachments for unnecessary personal information;
- decide whether the existing history is suitable or whether a reviewed/sanitized public history is preferable.

Accepted engineering evidence should be preserved where safe; the purpose is not to erase technical provenance but to avoid publishing private operational/personal details merely because they are historical.

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

## Public-release hygiene still required

Before accepting outside users/contributors, coordinate with the project publication workstream on:

- `LICENSE`;
- `SECURITY.md`;
- `CONTRIBUTING.md`;
- third-party attribution/notices;
- release-status language for experimental 0.2 code;
- CI/fork safety, especially any workflow using self-hosted runners.

## Publication options

The final project decision may choose any of these after review:

- make the existing Station repository/history public after successful audit/sanitization;
- create a sanitized public history/repository while retaining private development history;
- keep Station private for a defined period or permanently.

Record the final disposition in the organization project spine rather than treating this component note as the decision authority.
