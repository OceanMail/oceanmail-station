# S1 measured source report

Source/tooling head: `2f22edba9a57ae7782fec0f9f27b81f555eaaed5` (clean before and after measurement).
Base: `ec9e5f232aac722bae25a979098100cc3c0dbaf9`.
Measurement: 2026-09-22T22:01:27.125616+00:00 through 2026-09-22T22:01:45.505309+00:00.

This document summarizes the historical measurement of the source identified above.
The measurements below are historical reported results, not current-commit CI
or a reproducible evidence bundle. Raw environment-specific reports are not
included. Run the [measurement tooling](../../.quality/README.md) on the desired
public commit to obtain fresh evidence.

## STATIC / UNIT and local process evidence

| Check | Assessment | Count |
| --- | --- | --- |
| measurement-self-tests | COMPLETE | 17 |
| cargo-fmt | COMPLETE | 0 |
| cargo-clippy | FINDINGS | 4 |
| cargo-check | COMPLETE | 0 |
| cargo-test | COMPLETE | 22 |
| readiness-tests | COMPLETE | 5 |
| auth-build | COMPLETE | 0 |
| auth-http-tests | COMPLETE | 10 |
| shellcheck | FINDINGS | 22 |
| shellcheck-unsuppressed | FINDINGS | 23 |
| python-ruff | COMPLETE | 0 |
| python-types | FINDINGS | 296 |
| docker-hadolint | PARTIAL_OR_COMPILER_ERROR | 15 |
| workflow-actionlint | COMPLETE | 0 |
| semgrep | FINDINGS | 1 |
| cargo-audit | COMPLETE | 0 |
| audit-tool-cargo-audit | FINDINGS | 4 |
| audit-tool-cargo-llvm-cov | FINDINGS | 4 |
| audit-tools-python | FINDINGS | 6 |
| audit-tools-semgrep | FINDINGS | 6 |

Readiness tests are static shell-block probes; auth HTTP tests are local loopback
process integration, not product/LAN acceptance. Rust default tests and target
runs repeat the same tests; do not add their counts together. Zero-test binaries
and doc-test runs are retained explicitly. No test skip/xfail baseline is seeded.
The 17 measurement self-tests are separate from application tests.

Clippy totals are emitted diagnostics across targets, including duplicate
binary/binary-test emissions. Ruff uses its isolated default rules, not all rules.
ShellCheck's unsuppressed pass includes SC1091 after removing its existing native
disable in a temporary copy; original source and line numbers remain intact.
Hadolint includes a DL1000 parse error at `lab/phase4b/Dockerfile:21`; its findings
are partial and not proof that every Dockerfile was fully analyzed. Compiler/type
failures are distinct: cargo-check/compiler errors are zero; strict Python
findings include both existing test helpers and new report tooling.

## Diagnostic totals by rule

- cargo-clippy: `{"clippy::io_other_error": 2, "clippy::too_many_arguments": 2}`
- shellcheck-unsuppressed: `{"1087": 4, "1091": 1, "2002": 2, "2012": 1, "2015": 3, "2016": 1, "2034": 3, "2317": 8}`
- python-ruff: `{}`
- python-types: `{"reportArgumentType": 7, "reportAttributeAccessIssue": 1, "reportConstantRedefinition": 1, "reportIndexIssue": 2, "reportMissingParameterType": 40, "reportOptionalMemberAccess": 5, "reportUnknownArgumentType": 66, "reportUnknownLambdaType": 11, "reportUnknownMemberType": 87, "reportUnknownParameterType": 36, "reportUnknownVariableType": 40}`
- docker-hadolint: `{"DL1000": 1, "DL3003": 4, "DL3008": 7, "DL3066": 1, "DL4006": 1, "SC2015": 1}`

Strict Python diagnostics by owned file: `{".quality/measure.py": 197, ".quality/test_measure.py": 32, "scripts/test-phase4i-snapshot-readiness.py": 12, "scripts/test-phase4j-auth.py": 55}`.

## Rust file coverage

| File | Hit / instrumented lines | Percent |
| --- | --- | --- |
| `src/auth.rs` | 227 / 300 | 75.67% |
| `src/bin/oceanmail-remote-receipt-evidence.rs` | 0 / 234 | 0.0% |
| `src/bin/oceanmail-returned-receipt-evidence.rs` | 20 / 432 | 4.63% |
| `src/bin/oceanmail-uucp-evidence.rs` | 0 / 654 | 0.0% |
| `src/lease.rs` | 215 / 215 | 100.0% |
| `src/lib.rs` | 433 / 544 | 79.6% |
| `src/main.rs` | 0 / 124 | 0.0% |

No owned Rust files are missing. Zero-hit binaries remain in the denominator;
test functions are included. Python/shell/lab runtime coverage is unmeasured.
The no-radio Docker suites and local HTTP process tests are not folded into this
Rust unit-test coverage. These measurements do not assert coverage gates exist.

## Security and dependency measurements

Semgrep emits one INFO unsafe-block review lead, with no scanner parse errors at
the updated pin; it is not a reproduced security bug. Only three local syntactic
rules ran. Cargo product audit and measurement-tool audits are distinct below.
Tool findings are observed package/advisory matches, not confirmed exploitation.
CVSS/unscored advisory metadata is retained raw; absent severity is unknown.

| Audit scope | Advisory/package identity | Category |
| --- | --- | --- |
| cargo-audit | None reported | Completed scan |
| audit-tool-cargo-audit | `RUSTSEC-2026-0204` / `crossbeam-epoch 0.9.18` | Vulnerability; CVSS None |
| audit-tool-cargo-audit | `RUSTSEC-2026-0258` / `h2 0.4.14` | Vulnerability; CVSS None |
| audit-tool-cargo-audit | `RUSTSEC-2026-0185` / `quinn-proto 0.11.14` | Vulnerability; CVSS CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:N/I:N/A:H |
| audit-tool-cargo-audit | `RUSTSEC-2026-0285` / `rustls 0.23.40` | Vulnerability; CVSS CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:L/I:N/A:N |
| audit-tool-cargo-audit | `RUSTSEC-2026-0190` / `anyhow 1.0.102` | unsound |
| audit-tool-cargo-audit | `RUSTSEC-2026-0186` / `memmap2 0.9.10` | unsound |
| audit-tool-cargo-llvm-cov | `RUSTSEC-2026-0195` / `quick-xml 0.37.5` | Vulnerability; CVSS CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:N/I:N/A:H |
| audit-tool-cargo-llvm-cov | `RUSTSEC-2026-0194` / `quick-xml 0.37.5` | Vulnerability; CVSS CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:N/I:N/A:H |
| audit-tool-cargo-llvm-cov | `RUSTSEC-2026-0067` / `tar 0.4.44` | Vulnerability; CVSS CVSS:4.0/AV:N/AC:L/AT:N/PR:N/UI:A/VC:N/VI:L/VA:N/SC:N/SI:N/SA:N |
| audit-tool-cargo-llvm-cov | `RUSTSEC-2026-0068` / `tar 0.4.44` | Vulnerability; CVSS CVSS:4.0/AV:N/AC:L/AT:N/PR:N/UI:A/VC:L/VI:L/VA:N/SC:N/SI:N/SA:N |
| audit-tool-cargo-llvm-cov | `RUSTSEC-2026-0190` / `anyhow 1.0.99` | unsound |
| audit-tools-python | `PYSEC-2026-196` / `pip 25.1.1` | Vulnerability; severity not supplied by pip-audit |
| audit-tools-python | `PYSEC-2026-1795` / `pip 25.1.1` | Vulnerability; severity not supplied by pip-audit |
| audit-tools-python | `PYSEC-2026-1796` / `pip 25.1.1` | Vulnerability; severity not supplied by pip-audit |
| audit-tools-python | `PYSEC-2026-2875` / `pip 25.1.1` | Vulnerability; severity not supplied by pip-audit |
| audit-tools-python | `PYSEC-2026-2876` / `pip 25.1.1` | Vulnerability; severity not supplied by pip-audit |
| audit-tools-python | `PYSEC-2026-3721` / `pip 25.1.1` | Vulnerability; severity not supplied by pip-audit |
| audit-tools-semgrep | `PYSEC-2026-196` / `pip 25.1.1` | Vulnerability; severity not supplied by pip-audit |
| audit-tools-semgrep | `PYSEC-2026-1795` / `pip 25.1.1` | Vulnerability; severity not supplied by pip-audit |
| audit-tools-semgrep | `PYSEC-2026-1796` / `pip 25.1.1` | Vulnerability; severity not supplied by pip-audit |
| audit-tools-semgrep | `PYSEC-2026-2875` / `pip 25.1.1` | Vulnerability; severity not supplied by pip-audit |
| audit-tools-semgrep | `PYSEC-2026-2876` / `pip 25.1.1` | Vulnerability; severity not supplied by pip-audit |
| audit-tools-semgrep | `PYSEC-2026-3721` / `pip 25.1.1` | Vulnerability; severity not supplied by pip-audit |

RustSec database revision: `f7dc4b2860b29978f400fda0aab31cc4dbd21134`;
commit time: `2026-09-22T13:47:48-07:00`.
Pip advisory queries are timestamped in checks.json; the feed has no immutable
revision here. Lock graphs, actual versions, install reports and resolved freezes
are retained. Complete transitive reproducibility is not claimed.

## Remaining evidence boundaries

Established Phase 3/4I/4J workflow dispatches must identify the final PR head;
their results belong in the draft PR handoff. Current path filters exclude these
tooling/docs changes, so no synthetic-merge run is automatically generated.
No main-merge evidence exists because merging is not authorized. Existing
candidate PRs #51/#52 and their failures/reruns remain independent; their green
runs do not prove this head. LIVE / PRODUCT: none; no RF or production-security
claim. Embedded/generated code, other platforms, scanner build dependencies and
Docker/apt/upstream advisories remain gaps as described in the tooling guide.

No baseline, broad suppression, dependency/upstream promotion, source cleanup,
required workflow or branch protection was introduced. S2 is not started.
