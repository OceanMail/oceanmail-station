# HERMES session retirement regression

See [patch provenance](../lab/phase1/HERMES_PATCH_NOTICE.md) for the exact SHA,
digest, attribution, deployment requirement and limitations. The patch is temporary;
the behavioral regression remains after upstream resolves the defect.

## Reproduce on Linux

```sh
git clone https://github.com/Rhizomatica/hermes-net.git /tmp/hermes-upstream
python3 scripts/hermes-session-regression/compare_upstream.py \
  --source /tmp/hermes-upstream --out /tmp/hermes-comparison
make -C /tmp/hermes-comparison/current-patched/uucpd -j2
python3 scripts/hermes-session-regression/run_tests.py \
  --replacement /tmp/hermes-comparison/current-patched --tsan --repeat 10
```

Use a fresh output directory. The comparison archives exact upstream Git objects;
it does not modify upstream sources to make tests compile. It checks historical
unmodified, historical old-patch, current unmodified, and current patched trees.
Each compiles the actual worker/net/uuport code. Compilation failure, timeout or
signal is never counted as the expected assertion failure. A changed negative
control fails CI so maintainers must reassess patch necessity.

The historical patch under `fixtures/` is a test-only comparator recovered from
public Station's initial main, not a second production patch.

## Assertions and harness review

- Basic `Shere` and binary transfer are positive controls on all four variants.
- Retained TX holds the real transmitter under modem backpressure across retirement
  and reconnection: the peer must receive `NEW`, never `OLD`.
- Stale tail verifies the socket is empty at cleanup; reconnect-in-flight holds
  a received old byte and checks that the next greeting is exact.
- The delayed-exit case runs actual `uuport` in a child with SysV rings, stops it
  outside a ring critical section, ends a live session through the control worker,
  and tries another session before releasing the old process. Cleanup must wait,
  reject premature entry, and deliver the subsequent greeting exactly.
- Real abortive TCP close, invalid descriptor and injected EINTR exercise `net.c`.
- Restart kills a real daemon process while a bridge process retains its claim.
  Startup must refuse both a live daemon and a surviving bridge, preserve the
  existing semaphore, then recover only after both claims are released by death.
- The full patched suite additionally covers process death, incoming pipe/ring
  backpressure, SIGTERM before exec, partial TX/EAGAIN, receive/reset shutdown,
  continuous tails/EINTR fairness, repeated sessions, late local-disconnect ACK,
  duplicate idle DISCONNECTED and bridge-claim rejection.

Harness corrections: incoming execution now intercepts upstream `execv`
as well as historical `execl`; delayed exit enters retirement through a real
DISCONNECTED command, honoring current upstream's live-session-only kill policy.
Mutex-only implementation probes are restricted to the patched variant; behavioral
comparisons run on unmodified upstream without inventing a production mutex.
The test replaces `system(killall)` with hooks that target only its own child.
Semaphores use IPC_PRIVATE, or an exclusively created random key for restart,
with Python-parent cleanup. TSan tests only in-process
cases; fork/SysV assertions run normally and with ASan/UBSan. Leak checking is
disabled, and sanitizer success alone does not establish cross-process ordering.

## Rebase against upstream

The replacement modifies eight upstream files. VARA retirement overlaps upstream's
new late-disconnect changes and requires semantic reconciliation. The combined patch
retains duplicate/late-notification handling under the RX mutex, arms pending
disconnect before writing the command, and retains upstream's 90-second fallback
inside the retirement wait. It waits for the bridge claim and drains/resets rings
before reopening. No new UUCP process is admitted while old workers can write.

Review identified a startup hole: deleting an existing semaphore
forgets a surviving external bridge. This port corrects it with an atomic two-slot
startup claim before touching shared memory. A daemon owns its second slot for
its process lifetime; the first protects bridges and initialization. SEM_UNDO
permits recovery after death without resetting live claims. Incompatible legacy
semaphore sets fail closed and require a coordinated upgrade/fresh IPC namespace.

The upstream pre-agreed `-F`/`-Y` option remains off; the lab uses stock Taylor UUCP.
The protocol boundary remains Mercury's VARA-compatible control/data TCP pair.

## Evidence

Local diagnostic comparisons reproduce old TX (`4f4c44`), contaminated RX greeting,
six retained tail bytes, delayed old-bridge cleanup, and false success after TCP
reset on current unmodified upstream. The rebased patch passes those same probes.
The [merged public PR](https://github.com/OceanMail/oceanmail-station/pull/3)
records Actions evidence for its final head. Earlier runs and local results
do not substitute for acceptance checks on later revisions.

The combined `phase4i` job proves real UUCP transfer, durable interruption/retry,
far-side mailbox proof, reciprocal returned receipt and persisted correlation.
These are simulated laboratory results at `lab_peer_transport_unverified`, not
physical RF or production peer authentication.
