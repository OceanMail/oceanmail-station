# S3a public port and review handoff

## Scope and lineage

The port starts from public Station `5d6b95ebc434d85beaedc093a831ab01841f79c3`.
Its source is archive PR #59 at `a2487dd6640631785438539d7eb4e7e845144ba8`.
Only quality tooling, its tests/locks and the already accepted Rust 1.98.1
selection are ported. The archive branch also contains superseded dependency
work; it must not be merged wholesale into the public tree.

The public implementation adds typed scanner normalization, exact diagnostic
multiplicity/context comparison, immutable-base config and suppression guards,
coverage inventory validation, isolated scanner execution and retained raw evidence.
Python tooling installs use transitive hash locks. Bash syntax failures and
Python suppression inventories are classified correctly by the report-only runner.

No production suppression ledger, advisory exception ledger, baseline seed,
required quality workflow or branch protection is introduced. S3b/S4 require
separate assignments. The trusted runner intentionally cannot validate its own
initial introduction against a base that does not contain it.

## Review disposition

The archive's three review-fix records were inspected before porting. Their
final changes are retained: explicit Cargo audit freshness/index checks and
database provenance; isolated HOME/Cargo/cache state and rejected scanner
options; immutable-base gate loading; advisory owner/expiry metadata; directive
and unscanned-script detection; SC1087 handling; Python transitive locks.
The public-port review additionally found that multi-option ShellCheck disable
comments escaped measurement inventory/unsuppression. A regression test now
checks their inventory and removal while retaining other options and line numbers.
Historical private evidence bundles and old acceptance counts are not imported.
Fresh public-head evidence belongs in the PR and its linked Actions runs.

Remaining limitations are explicit: Rust/shell directive and Rust test identity
matching are conservative textual checks, not complete language parsers. Local
scanner isolation is not a sandbox for malicious builds. The report-only
measurement audit does not provide the ratchet adapter's stronger freshness
validation. Complete CI enforcement and executable-line thresholds remain S4.

## Reproduce

Follow [README.md](README.md) for bootstrap and measurement. Then run:

```bash
python3 -m unittest discover -s .quality -p 'test_*.py' -v
python3 .quality/smoke_adapters.py /absolute/new-evidence/scanners
python3 .quality/smoke_rust.py /absolute/new-evidence/rust
```

The smoke probes create disposable Git repositories and fixture-only ledgers.
They exercise clean, new-diagnostic and setup/parser/policy failures without
creating a production baseline. Preserve all raw output and failed attempts.
Run measurement on a committed clean head and dispatch existing acceptance
workflows on that same final head. Report STATIC / UNIT separately from
INTEGRATION; no LIVE / PRODUCT claim follows from these checks.

## Acceptance gates

Independent Claude review of each exact public PR base/head is required by
AGENTS.md and the central retrofit specification. This handoff does not claim
that review or owner acceptance. Keep the archive source branches until the
public replacements have been accepted. Do not infer merge authorization from
historical archive PR descriptions.
