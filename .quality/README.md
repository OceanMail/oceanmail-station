# Station S1 report-only measurement

Scope: [Station #53](https://github.com/OceanMail/oceanmail-station-archive/issues/53),
coordinated by [Project G0 draft #44](https://github.com/OceanMail/oceanmail-project-archive/pull/44).
No S2 cleanup, S3 adapter/baseline, required quality workflow or protection is
implemented here. Existing source, assertions, locks, workflow triggers and
HERMES/Mercury pins stay authoritative.

## Run on Linux x86-64

Prerequisites: Python 3.13 with venv, Bash, Git, curl, C compiler/linker, rustup,
and network access for pinned tools and advisory feeds. Provision rustup locally
if absent; do not substitute the system Cargo 1.85 for the accepted CI compiler.

```bash
rustup toolchain install 1.98.1 --profile minimal --component clippy,rustfmt,llvm-tools-preview
bash .quality/bootstrap.sh
source .quality/tools/env.sh
python3 -m unittest discover -s .quality -p 'test_*.py' -v
python3 .quality/measure.py --out /absolute/path/to/station-reports
```

Bootstrap recreates its two isolated Python environments under `.quality/tools`
to prevent stale packages from earlier probes; preserve its stdout/stderr.
Toolchain installation is an explicit prerequisite, not an implicit upgrade of
product dependencies. If using isolated `CARGO_HOME`/`RUSTUP_HOME`, retain those
variables and prepend that Cargo bin directory before sourcing `env.sh`.

Each invocation creates a fresh timestamped report directory. It records exact
HEAD, beginning/end dirty state, tracked-file hashes, OS/runtime information,
commands/cwd/status/timing, raw stdout/stderr, JSON summaries and coverage XML.
`checks.json` is the full parsed report; `summary.md` is navigation, not a gate.
`SHA256SUMS.json` hashes every retained report file. Never interpret runner exit
zero as clean CI. Missing tools, timeouts, compiler/setup/parser errors, partial
scans, missing coverage and zero-test targets remain explicit. No suppressions,
known-failure quarantine or diagnostic baseline is generated.

The runner executes repository tests and the local loopback auth process in a
dedicated development checkout. It does not start Docker labs or physical radio.
Avoid running it concurrently with another build or edits in the same checkout.
Run on a committed clean head for authoritative evidence; dirty preflight runs
are retained only as diagnostic work. Application test outcomes, self-tests and
scanner findings are separate metrics, not a combined passing-test total.

## Tool/configuration provenance

Initial candidates derive from the owner's `OceanMail-CI-Retrofit-Kit`, dated
2026-09-22; hashes are recorded in `kit-provenance.json`. The Station runner adapts
its subprocess/output model with strict report parsing and target/test coverage.
It does not invoke all-repository measurement or copy future ratchet adapters.

| Tool | Direct pin | Scope |
| --- | --- | --- |
| Rust / Clippy / rustfmt / LLVM component | 1.98.1 | Existing CI compiler; all owned Cargo targets |
| cargo-llvm-cov | 0.6.19 | Rust test instrumentation, complete owned file inventory |
| cargo-audit | 0.22.2 | Product lock and measurement Rust tool locks |
| Ruff | 0.12.12 | Every tracked standalone Python file, isolated defaults (E4/E7/E9/F) |
| basedpyright | 1.31.4 | Strict Linux Python 3.13, scripts and owned `.quality` code |
| ShellCheck | 0.10.0 (shellcheck-py 0.10.0.1) | Every tracked shell script |
| Hadolint | 2.15.1 | Every tracked Dockerfile |
| actionlint | 1.7.7 | All three existing workflows; embedded ShellCheck enabled |
| Semgrep | 1.177.0 | Reviewed local Rust unsafe / Python eval / shell-process rules |
| pip-audit | 2.9.0 | Both installed Python tool environments |

`bootstrap.sh` uses Cargo `--locked`, pip install reports and freezes, upstream
binary checksums and captured executable hashes. These are direct pins plus
resolved-install evidence, **not a full transitive/hash lock**. Python, OS,
system tools, advisory feeds and binary download endpoints have independent
provenance/availability; complete enforcement/reproducibility belongs to S3/S4.
The product `Cargo.lock` is unchanged. No mutable Semgrep registry rules or
Semgrep token are used. Findings are review hypotheses, not confirmed exploits.

Compatibility probes found three initial-kit limitations: Semgrep 1.136.0 first
needed `pkg_resources` (setuptools 80.9.0 restored startup), then reported partial
Rust parsing; cargo-audit 0.21.2 could not parse a current CVSS 4 advisory; Hadolint
2.12.0 could not parse a current Dockerfile. Only measurement-tool pins were
updated, and the failed preflight evidence is retained. Semgrep 1.177.0 parses all owned Rust/Python targets and cargo-audit 0.22.2
reads the current advisory database. Hadolint 2.15.1 still reports DL1000 at
`lab/phase4b/Dockerfile:21` after its heredoc; that file is a partial static
scan, not clean Docker validation. No Dockerfile is rewritten to satisfy it.

## Source, target and test matrix

`manifest.json` enumerates every tracked Rust, shell, Python, Dockerfile,
workflow and patch. `target-matrix.json`, `cargo-metadata.stdout` and
`cargo-features.stdout` retain exact resolved Cargo target/dependency features.
At the starting main there is one package, no package feature declarations,
one library, the Station daemon and three evidence binaries. Default dependency
features plus rusqlite `bundled`, serde `derive`, Tokio macros/runtime/net/process/
signal/sync/time and UUID v4/serde are the current manifest scope. There is no
invented `--all-features` matrix. Compilation/Clippy use `--all-targets`; default
`cargo test --locked` includes doc tests, and separate per-target runs retain
unambiguous target/test identities. Zero-test binaries/doc targets are explicit.
Only native `x86_64-unknown-linux-gnu` is validated here; ARM/other OS targets are
unmeasured.

Existing local acceptance commands remain:

```bash
cargo +1.98.1 test --locked
python3 scripts/test-phase4i-snapshot-readiness.py -v
cargo +1.98.1 build --locked
python3 scripts/test-phase4j-auth.py -v
```

Coverage includes all seven owned Rust files, including unexecuted binaries and
zero-hit lines; no owned-source filename exclusion is configured. Test functions
are included in llvm-cov line totals, so these are instrumented file metrics,
not a pure production-code-only percentage. Rust unit-test coverage does not
measure Python HTTP acceptance or Docker labs. The two existing Python suites
are explicit commands, not automatic execution of arbitrary standalone scripts.
Bash syntax and ShellCheck are static analysis, not shell runtime acceptance.

The tracked HERMES patch is hashed/inventoried, excluded from owned-source
format/lint/coverage because it is a separately reviewed upstream integration
delta. Embedded Python, shell heredocs and generated variants in lab scripts/
Dockerfiles are not extracted into complete standalone analysis. Actionlint's
embedded ShellCheck is enabled; pyflakes is not installed. Semgrep has only
three syntactic rules; it cannot establish account isolation, race freedom,
cryptographic trust or complete security coverage. Docker/apt/upstream binary
advisories and Go/Haskell scanner build dependency audits remain gaps. Shell
and Python coverage/runtime beyond the named acceptance suites is unmeasured.

## Existing restricted runner group CI

A `.quality`/documentation-only PR does not match current workflow path filters.
After pushing the final branch head, use existing authorized dispatches:

```bash
gh workflow run phase3-dovecot-compat.yml --ref quality/measure
gh workflow run phase4i-linux-acceptance.yml --ref quality/measure
gh workflow run phase4j-auth.yml --ref quality/measure
```

Record each run URL, `headSha`, `event`, conclusion, job/step and artifacts.
These dispatches prove the branch head, not a synthetic PR merge. If no
synthetic-merge run exists, report that gap explicitly. Owner merge has not
occurred, so there is no merged-main evidence. Preserve every failed attempt
and unchanged-head rerun rather than calling intermittency repaired.

Phase 3 uses the existing Dovecot/writable IMAP acceptance; Phase 4I preserves
exact returned-receipt/session-retirement/negative-pre-return/restart assertions
and trust `lab_peer_transport_unverified`; Phase 4J preserves auth/account
isolation. Existing PRs #51/#52 are independent. No no-radio result proves
production security, real GUI operation, hardware or physical-radio acceptance.

Existing native suppression locations are inventoried separately; this is not a
new suppression ledger. Ruff ignores `noqa` and Semgrep disables `nosemgrep`
for measurement. The first ShellCheck pass retains the existing SC1091 directive in
`scripts/preflight-debian.sh` for `/etc/os-release` sourcing. A second unsuppressed
pass removes disable comments only in temporary source copies, preserving line
numbers and a source mapping in the report. The checkout is never edited and
existing exceptions are neither reapproved nor added to a baseline.
