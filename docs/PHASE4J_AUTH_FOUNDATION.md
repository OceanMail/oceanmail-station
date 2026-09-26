# Phase 4J — laboratory authentication foundation

Status: laboratory authentication foundation; not production identity or
permission to expose the Station on a LAN.

Authority: the [Available account contract](AVAILABLE_MANIFEST_ACCOUNT_CONTRACT.md), and
[storage/key-separation gates](PHASE4_STORAGE_SECURITY.md).

## Implemented boundary

Two **loopback-only laboratory** GET endpoints exercise server-derived identity:

| Endpoint | Required explicit permission | Result |
| --- | --- | --- |
| `/api/v1/auth/context` | `auth_context_read` Station permission | This credential's identity, role, independent device-trust state, explicit permissions/account grants, expiry, and Station identity. |
| `/api/v1/accounts/{account_id}/auth/context` | `context_read` grant for that exact account | The same identity with only the requested account grant. |

Both authenticate before checking permissions. Account IDs are opaque exact-match
authorization scopes; email addresses, Thunderbird profile IDs, headers asserting
roles, and guessed IDs do not confer authority. `owner_captain`, `admin`,
`operator`, and `user` are descriptive roles, not implicit grants. Device trust
is an independent provisioning fact, not proof of device possession or a mailbox
grant. This bearer-only lab slice does **not** implement production device binding.

Future handlers can use `RequestContext::require_account` with explicit read/write
permissions. They must check every referenced object before lookup/disclosure and
must not interpret one scope's permission as authority for another scope. The
enumerated Available/plan/accounting permissions do not implement those APIs.

Missing, invalid, duplicated Authorization headers and expired credentials get a
generic `401`; missing scope/permission gets a generic `403`. An unauthorized
existing account and nonexistent account return the same denial. Responses use
`Cache-Control: no-store` and `Vary: Authorization`. Tokens are accepted only in a
single `Authorization: Bearer ...` header, never query parameters or identity
headers. No credential value is returned or included in configuration errors.

## Runtime provisioning (synthetic lab identities only)

`OCEANMAIL_LAB_AUTH_FILE` names a regular, owner-only JSON file owned by the
Station process's effective UID (for example mode 0600 in a restricted tmpfs
runtime directory). Ownership/mode are checked on the opened file descriptor;
even a root-run Station rejects another UID's 0600 file. Use random 32-byte tokens encoded
as 64 lowercase hex characters. Do not use real mailbox passwords, put tokens
in command-line arguments, commit them, upload the file as evidence, or send
these reusable credentials over radio/shared constrained links.

The document requires these fields (tokens intentionally omitted here):

```text
laboratory_only: true
credentials: [
  token: <fresh cryptographically random 64-character lowercase hex secret>
  user_id: <operator-provisioned stable opaque identity>
  role: owner_captain | admin | operator | user
  permissions: [auth_context_read | station_status_read | station_admin]
  device_id: <operator-provisioned device identifier>
  device_trusted: true | false
  account_grants: [
    account_id: <stable opaque account identity>
    permissions: [context_read | available_read | retrieval_plan_read |
                  retrieval_plan_write | accounting_read]
  ]
  expires_at_unix: <required absolute expiry>
]
```

Unknown fields/permissions, duplicate tokens or account grants, invalid IDs,
non-laboratory mode, overlarge input and broadly readable credential files fail
startup with a redacted error. No file configured means all protected requests
fail authentication, not permissive access. An explicitly empty credential list
is also deny-all. Credentials are read once into memory at startup; the Station
does not create or copy a credential store into its SQLite database.

Identity survives process restart only when the operator deliberately re-provisions
the same IDs; Station identity continues to come from existing durable Station
state. A token's expiry is rechecked per request. **Lab revocation is removal or
grant reduction followed by Station restart**; editing the file alone does not
revoke the in-memory snapshot. No background execution, refresh, enrollment,
recovery, cross-Station grants or production offline lifetime is selected here.
For immediate revocation stop the lab process before changing/restarting it.

Token equality uses `subtle` 2.6.1's fixed-length constant-time comparison rather
than a bespoke cryptographic primitive. This narrow dependency does not provide
TLS, proof of device possession, replay resistance, or production credential
lifecycle. See [upstream API](https://docs.rs/subtle/2.6.1/subtle/trait.ConstantTimeEq.html).

## Unchanged laboratory/evidence boundary

`parse_loopback_bind` is unchanged and still rejects LAN/wildcard addresses even
with credentials configured. Existing Phase 4 evidence endpoints remain separate,
unauthenticated loopback **lab diagnostics**, not an account-private product API.
Do not put real multi-user/private data in this lab or proxy these routes onto a
LAN. Their vessel-wide observations are not authorized by this auth slice.

`capabilities.api_authentication` remains false because the existing API as a
whole is not protected; the new context explicitly identifies its limited
`laboratory_runtime_bearer` authentication. `lan_exposure`, production storage,
application encryption, per-user key separation, and verified host-volume
encryption remain false. Returned receipt trust stays exactly
`lab_peer_transport_unverified`. No Phase 5 work is included.

## Validation

```bash
cargo test --locked
cargo build --locked
python3 scripts/test-phase4j-auth.py
```

STATIC / UNIT: denied missing/invalid/expired/ambiguous credentials, exact account
scoping, read/write separation, all role/device combinations, explicit permission
checks, fail-closed configuration, stable context and absence of secrets.

INTEGRATION: real Station process/HTTP requests, two-account isolation, denied
Admin/Operator/Captain cross-account access, forged identity headers, no-permission
denial, expiry, restart/reprovision, grant removal on restart, no secret copies in
responses/logs/SQLite, rejected LAN bind, rejected invalid/unsafe files and unchanged
security flags. CI uses the existing trusted private self-hosted Linux runner.
The separate Phase 4I workflow remains the no-radio receipt regression gate.

LIVE / PRODUCT: no Desktop GUI, real account enrollment, LAN product service,
hardware, radio or production security acceptance is claimed.

## Blocked next boundaries

Issue #23 remains open for accepted production enrollment/device proof, revocation
and disconnected lifetime, encrypted/key-separated persistence, and secured LAN
acceptance. This lab credential format is not a production identity decision.

Issue #24 and real Desktop Available cannot claim completion from this context
endpoint. Holder-authorized metadata provenance, stable logical object bindings,
protected persistence and revocation/expiry of background intent must be accepted
before real private catalog/plan operations. Accounting must remain unavailable
and spending fail closed until authoritative policy is known. No balances,
holder trust, durable retrieval or payload execution are fabricated in this slice.
