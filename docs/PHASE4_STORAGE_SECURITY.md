# Phase 4 Storage Security Boundary

Status: **Accepted Phase 4 requirement; implementation design in progress**

## Hard release gate

No production OceanMail Station release may persist user-sensitive data, credentials, mailbox contents, pending account operations, or equivalent private state unencrypted at rest.

Station administration and personal-content access are separate authorities. A Station Owner/Captain or delegated Station Admin must not gain another user's mailbox/private-content access merely by holding a Station-management role.

Phase 4A is a laboratory exception: its SQLite database currently contains only basic Station identity/state and is plaintext. The service must advertise that production storage security is not yet ready.

## Security goals

The production Station must address two different risks rather than treating them as one problem.

### 1. Offline/stolen-media protection

If a Station is powered off, stolen, or its storage device is removed, sensitive Station data must not be readable without the appropriate unlock material.

The first Linux candidate for this layer is LUKS2/dm-crypt whole-volume or dedicated-data-volume encryption. This protects data at the block-device boundary while the volume is locked, but it is not a substitute for application authorization once the running system has unlocked the volume.

Upstream reference: https://gitlab.com/cryptsetup/cryptsetup

### 2. User/private-content separation

A running Station may need to remain online while individual users are logged out. Station administrative authority must therefore remain distinct from possession of users' private-content decryption keys.

The design should support per-user/application key separation for private mailbox content, user credentials/tokens, sensitive pending server operations, and other private state where feasible.

This requirement is stronger than whole-disk encryption alone: once a disk volume is mounted, whole-volume encryption does not by itself enforce user-to-user privacy.

## Mailbox compatibility

Phase 3 proved that OceanMail can use normal SMTP/IMAP clients. Storage encryption must preserve that standards-based client boundary rather than forcing OceanMail to reimplement ordinary mail composition and retrieval.

Dovecot 2.4's `mail-crypt` plugin is the first mailbox-at-rest candidate to evaluate. Current Dovecot documentation describes transparent mail encryption/decryption and supports global or per-user keying, including encrypted user private keys.

Upstream reference: https://doc.dovecot.org/main/core/plugins/mail_crypt.html

A particularly relevant property to test is whether the Station can retain a user's encryption/public-key material needed to accept and encrypt incoming mail while keeping the corresponding private decryption capability locked until the user authenticates. This is a candidate design, not yet an accepted implementation result.

## Station database

Phase 4A uses ordinary SQLite through `rusqlite` for non-production laboratory state.

Before sensitive user/account state is stored there, choose and test an encrypted-storage approach. Candidate directions include:

- keeping the database only on an encrypted Station data volume when it contains Station-level non-private state;
- application-level envelope encryption for sensitive columns/blobs with per-user keys;
- SQLCipher or another reviewed encrypted-SQLite implementation if whole-database encryption materially simplifies the design.

The official SQLite Encryption Extension (SEE) is proprietary/licensed and is not assumed as the OceanMail solution. No encrypted-SQLite implementation is selected yet.

## Data classification

At minimum, treat the following as sensitive unless a narrower reviewed classification is documented:

- mail bodies and attachments;
- mail headers/metadata that reveal private communications relationships;
- account credentials, authentication tokens, recovery material, and private keys;
- pending server/account operations;
- private contact/location data;
- user-specific queue metadata where it reveals private communications;
- logs/evidence that contain message content, addresses, tokens, or other private data.

Station identity, software version, public transport capabilities, and similar operational metadata may not require per-user encryption, but should still receive offline storage protection in a production installation where practical.

## Key-lifecycle requirements

The final Phase 4 design must define and test:

- initial key creation/provisioning;
- user login/unlock behavior;
- user logout/auto-lock behavior;
- background receive while a user is logged out;
- already-accepted outbound work after user logout;
- password changes and key re-wrapping/re-encryption;
- captain/admin account removal without unintended mailbox disclosure;
- user removal and secure key retirement;
- backup/recovery keys and recovery procedure;
- lost-password behavior and explicit limits on recoverability;
- device replacement/migration;
- key rotation;
- protection of keys in memory and avoidance of secrets in logs/command lines where feasible.

## Background-operation constraint

OceanMail Station must continue communications when user clients disconnect or power off. Encryption therefore cannot depend on a user's laptop remaining connected.

At the same time, "Station can transport a user's already-authorized work" must not automatically mean "Station management can display that user's private plaintext."

The implementation must explicitly document what plaintext must transiently exist for SMTP/Postfix/UUCP/Dovecot operation and minimize its lifetime and accessibility. Product-level Station Admin rights must never be treated as a mailbox decryption entitlement.

An operating-system root compromise is a stronger threat than a Station-management role and may be able to observe process memory or transient plaintext on a running system. Phase 4 should minimize this exposure, but must not falsely claim that application-level role separation makes a fully compromised running host safe.

## Phase 4 gating

Until this storage/key model is implemented and accepted:

- the Station API remains loopback-only;
- `production_storage_ready` must remain false;
- application-managed storage encryption must be reported as not implemented;
- per-user key separation must be reported as not implemented;
- Phase 4 laboratory SQLite state must not be treated as a production mailbox/account store;
- new Phase 4 work should avoid placing sensitive user payloads into the Station-owned database unnecessarily.

LAN API exposure, real multi-user account provisioning, and production mailbox persistence must not be promoted past laboratory status without reconciling this security boundary.

## Acceptance requirement

Before OceanMail Station can claim production-ready encrypted storage, tests must demonstrate at minimum:

1. powered-off storage does not expose sensitive data without unlock material;
2. a Station-management role does not provide another user's mailbox decryption capability;
3. incoming/background mail handling works under the chosen logged-out key model;
4. user login can retrieve/decrypt the user's mail through the supported client path;
5. logout/auto-lock removes the user's private-content access from ordinary Station management surfaces;
6. restart/recovery/backup and password/key-rotation procedures preserve intended access without silently weakening key separation;
7. no production-security capability flag is enabled until the corresponding acceptance evidence exists.
