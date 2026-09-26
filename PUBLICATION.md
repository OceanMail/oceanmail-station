# Fresh source publication

Owner-approved 2026-09-26: this repository starts with sanitized current source
and a new initial commit. Pre-publication Git history, numbered issues/PRs,
Actions records and recovery copies remain in a separate private repository
with an `-archive` suffix. They are not imported into this repository.
Links to those historical resources require private access. Historical commit
IDs and test reports are provenance records, not new-repository CI evidence.

The public source licenses are installed in LICENSE and LICENSE-DOCS;
LICENSING.md defines scope and preserves third-party terms. This record
supersedes older statements that the license choice is still pending.
No DCO or additional inbound agreement is adopted by this migration.

Unmerged development branches remain private. Transfer selected changes only
after review, using new commits without importing the original Git ancestry.
Never mirror-push the private repository into this one.

Before public cutover: verify this tree, required hosted CI, runner exclusion,
read-only Actions defaults and repository access. Configure protection with
zero required approving reviews and required checks. Enable private vulnerability
reporting at public cutover and validate the external-fork workflow.
Public source availability is not a production, radio or safety certification.
