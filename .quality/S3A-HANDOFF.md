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
The public measurement also exposed unresolved sibling `test_ipc` imports in
the newer HERMES helper directory. The type-checker search path now includes
that directory; no missing-import diagnostic is suppressed.
Historical private evidence bundles and old acceptance counts are not imported.
Fresh public-head evidence belongs in the PR and its linked Actions runs.

Remaining limitations are explicit: Rust/shell directive matching over-approximates
candidates. Rust test matching under-approximates: attribute-argument forms,
alternative test macros and same-named tests in different modules are not fully
tracked, and unknown forms are not rejected. Deleting those tests can evade the
guard. Before S3b, establish authoritative per-target enumeration. Local
scanner isolation is not a sandbox for malicious builds. The report-only
measurement audit does not provide the ratchet adapter's stronger freshness
validation. Complete CI enforcement and executable-line thresholds remain S4.

## Independent review corrections

Claude reviewed Station `8fa010c24beb2b639350991a21ed14406f1c633c` and Project
`7e7dcb8bf808d87fcf1cc292ae4e478e63e6a37c`. That review does not cover later heads.

- R1: describe the test-inventory under-approximation accurately; complete
  authoritative enumeration remains a pre-S3b requirement.
- R2: detect `SkipTest` and `importorskip`, including direct imports and aliases.
- R3: describe proxy/wrapper hashes and version validation without claiming
  complete underlying executable provenance.
- R4: disable rustup auto-install in scanner environments, even if enabled by
  the caller; missing compiler provisioning must fail.
- O1/O2: preserve valid ShellCheck input after removing a disable-only directive
  with a trailing reason; scope the HERMES sibling import path to its directory.
- O4: record fresh-fetch completion and commit date without claiming an enforced
  90-day database-age limit.

Other optional improvements and future S3b/S4 requirements from the review remain
outside this correction. No production ledger or enforcement is added. A new
exact-head delta review is required before owner acceptance.

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
