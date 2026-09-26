# HERMES laboratory patch provenance

OceanMail Phase 4I builds HERMES `uucpd` / `uuport` from the exact upstream repository and commit below, then applies the adjacent tracked patch `hermes-vara-discard-stale-data.patch`.

- Upstream repository: `Rhizomatica/hermes-net`
- Upstream commit: `5c76adff754de49c0b934c7fd7bddf7619b0c3d6`
- Patched upstream file: `uucpd/vara.c`
- Purpose: prevent retired-session VARA/Mercury TCP data from becoming the first bytes consumed by a later reciprocal UUCP session, and expose an explicit post-cleanup laboratory boundary.

The `uucpd` component carries its own upstream `LICENSE`, which is copied into the Phase 1 lab image at `/usr/local/share/licenses/hermes-uucpd/LICENSE`. This notice does not relicense HERMES or the patched source. The OceanMail lab image also stores the applied patch and its SHA-256 so evidence can distinguish the exact upstream pin from the OceanMail laboratory delta.

This patch is a laboratory integration delta, not a claim that upstream HERMES or production OceanMail transport has adopted this behavior. Physical-radio acceptance remains separate.
