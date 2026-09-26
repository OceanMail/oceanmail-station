# Single-Radio Operational Baseline

- **Status:** Retained Station constraint / future scheduler research
- **Origin:** 2026-09-01 Station/RF design discussion
- **Boundary:** additive to the current HERMES/Mercury proof path; does not authorize physical-radio Phase 5.

## Retained constraint

The initial practical OceanMail Station design must remain functional with **one HF transceiver**. It must not require simultaneous receive/transmit capability on multiple HF frequencies, multiple radios, or a continuously monitored secondary channel in order for basic OMail operation to work.

A single transceiver can normally service only one tuned frequency/session at a time. Therefore future real-radio scheduling/rendezvous logic must account explicitly for:

- sequential scanning/monitoring rather than pretending multiple frequencies are observed simultaneously;
- the radio being unavailable for other HF scanning or sessions while an active connected transfer owns it;
- retune/setup/settling and link-establishment cost;
- half-duplex operation and turnarounds;
- returning to an appropriate rendezvous/listening state after a session; and
- Emergency/current-vessel OMail work being able to preempt lower-value opportunistic activity according to accepted Station scheduling policy.

This constraint is compatible with the broader radio-flexibility rule in `RADIO_RENDEZVOUS_AND_LINK_REQUIREMENTS.md`: managed gateways or later installations may use multiple independent radios when simultaneous monitoring, availability, throughput, or failure-domain separation justifies them. Multi-radio hardware is an optimization/capacity option, not a baseline functional dependency.

## What is not fixed

This note does not select:

- a scan list or scan dwell time;
- a global rendezvous frequency;
- a radio model;
- a number of RF frequency bands (scheduler Bands 0–3 are now defined by Project ADR-008);
- an ALE implementation;
- session-preemption thresholds; or
- a production scheduling algorithm.

Those remain subject to applicable regulatory authorization, supported upstream behavior, real hardware measurements, propagation evidence, and the current Station scheduling/accounting architecture.

## Current scheduling consequence

[Project ADR-008](https://github.com/OceanMail/oceanmail-project/blob/main/docs/decisions/ADR-008-four-band-scheduling-and-channel-use.md) defines rendezvous announcements, negotiated Band 1/Band 2 directed exchanges on one working channel, and announced shared broadcasts without a dedicated channel per band. A Station cannot monitor another frequency simultaneously; bounded check-ins and Emergency discovery/preemption must be designed and validated. Band 3 broadcasts receive no reserved lease time. Lease duration and the normal Band 1 cap are independent tuning inputs, with a necessary route-establishment exception. Ten/four minutes are arithmetic examples, not selected defaults or a fixed 40% ratio; operating values require measured transport and responsiveness evidence. No instantaneous cross-channel Emergency detection is claimed.
