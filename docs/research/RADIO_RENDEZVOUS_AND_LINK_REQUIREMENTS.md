# Radio Rendezvous and Link Requirements Research

- **Status:** Research / future Station requirements
- **Source:** reconciled from OceanMail 0.1 HF/rendezvous/modem research and retired 0.2 RF/VHF design discussion
- **Boundary:** this does not modify the current HERMES/Mercury proof path.

## Purpose

Preserve radio-operation requirements and experiments that remain useful after the 0.2 HERMES transition without carrying forward BEMPIC/M4P ownership assumptions or treating historical modem capability notes as current facts.

Specific third-party modem/radio capabilities must be revalidated against current upstream documentation before implementation.

## Lower-layer reliability boundary

OceanMail Station must not recreate point-to-point RF reliability already provided by a mature connected modem/link.

Where the selected link provides them, the modem/link layer owns behavior such as:

- modulation/demodulation;
- frame error detection;
- FEC;
- ACK/NAK;
- RF-frame retransmission;
- adaptive speed/robustness; and
- half-duplex turnaround behavior.

OceanMail Station owns durable job state, scheduling/policy, application/service handoff, evidence capture, and continuation across lost sessions—not a second fine-grained ARQ system.

This is consistent with the current HERMES/Mercury proof architecture.

## Half-duplex assumption

HF Station design should normally assume half-duplex operation unless a specific supported system proves otherwise.

Performance work should measure:

- payload bytes;
- total transmitted/received bytes;
- airtime;
- number/cost of TX/RX turnarounds;
- acknowledgement/repair overhead;
- listen/deferral time; and
- effective useful throughput.

A design with fewer bytes may still be worse if it causes excessive turnarounds or lost opportunities.

## Short-range and terrain-obstructed HF

Do not model HF reachability as either line-of-sight or long-distance skip only.

Depending on frequency, time, ionospheric conditions, antenna installation, terrain, and noise, useful local or regional HF links may arise from direct/ground-wave/diffracted energy and from high-angle skywave/NVIS behavior. Nearby stations separated by substantial terrain may sometimes communicate even when a VHF path is blocked. The inverse is also possible: a nearby peer may be unusable while a materially more distant peer is strong because propagation and antenna patterns create different lobes, nulls, or skip behavior.

These are test hypotheses, not coverage guarantees. Future Station scheduling, rendezvous, and link-selection logic must not infer reachability solely from geographic distance or optical/VHF line of sight. Prefer measured per-peer/per-band evidence and, where useful, propagation context.

Maritime RF testing should deliberately include both clear and terrain-shadowed short paths so OceanMail can measure when short-range HF is useful across mountainous maritime geography rather than assuming either success or failure. Candidate examples include vessels on opposite sides of an island or terrain-shadowed channels where legal and operationally practical.

## Legal/regional channel catalog

A future Station may maintain a signed/versioned region/service-aware channel catalog derived from authoritative permitted allocations and operator configuration.

Candidate metadata includes:

- jurisdiction/region;
- radio service;
- frequency/channel;
- intended use;
- permitted emission/data/bandwidth/power constraints;
- compatible configured modem/link types;
- rendezvous/calling versus working-data classification;
- receive-only/prohibited state where applicable;
- effective dates; and
- provenance/version.

The software must not invent arbitrary worldwide frequencies.

Protected distress/safety channels must never be repurposed as ordinary OceanMail rendezvous/data channels.

Such a catalog is an operator aid, not a replacement for applicable law, licensing, or official frequency information.

No production HF frequency/channel set has been selected. Exact HF channels remain intentionally unresolved until physical-radio planning can combine applicable service rules, licensing, modem/radio capabilities, antenna behavior, propagation measurements, and regional operating requirements. OceanMail should expect multi-band HF operation rather than hard-coding a single global frequency.

## Future VHF transport wishlist — deferred

VHF is a desired future first-class Station transport, but it is **not on the current critical path**. Do not implement VHF merely because the Station transport architecture can accommodate it. The accepted sequencing remains: first obtain a functional OceanMail system on the current HERMES/Mercury/IP path; evaluate and implement VHF afterward.

The intended future abstraction is that Station policy/queue/evidence logic can choose among available transports such as:

```text
OceanMail Station
      |
      +-- ordinary IP / Starlink
      +-- VHF transport
      `-- HF transport
```

Transport selection must not create independent mail semantics or duplicate durable payload queues. HERMES/UUCP-derived store/transport behavior may remain above multiple link adapters where proven compatible, but that is an integration question rather than a requirement that every link use the same modem.

### Open-source requirement

The OceanMail VHF modem/transport implementation should be open source.

Mercury remains the current preferred open HF modem baseline. Do **not** assume Mercury itself is the VHF modem merely because OceanMail uses HERMES/Mercury on HF. A future VHF implementation should evaluate an appropriate open-source software modem/TNC or transport adapter and then prove how it integrates with the Station STORE / TRANSPORT boundary.

The relevant USB integration point is the radio, modem, or TNC/control/audio interface—not the antenna. Antennas remain RF components connected to the radio by the appropriate feed line.

### Radio hardware flexibility

Do not hard-code OceanMail around either a combined or separate-radio topology.

Combined HF/VHF transceivers can be useful for lower-cost/test installations when they expose suitable documented computer control/audio interfaces. For managed gateways or other serious installations, independent HF and VHF radios may be preferable when simultaneous monitoring, independent failure domains, or concurrent link availability matters. This is a hardware-selection preference to validate later, not a current purchase requirement.

### Marine VHF / VDSMS candidate

For U.S. recreational/private-vessel use, **VHF Digital Small Message Services (VDSMS)** is a candidate worth evaluating rather than an accepted OceanMail waveform.

The current U.S. Coast Guard channel table identifies VDSMS on multiple marine VHF channels, including non-commercial channels 68, 69, 71, 72, and 78A, and states that VDSMS short digital messages use RTCM Standard 12301.1. See:

- https://www.navcen.uscg.gov/us-vhf-channel-information

A future OceanMail VHF implementation must revalidate the then-current FCC/USCG rules and the applicable RTCM requirements before transmission. The existence of VDSMS permission does **not** mean an arbitrary open-source waveform can be placed on a marine VHF voice channel.

A yacht-club/private-coast gateway is a desired future use case: for example, a vessel with failed/unavailable Starlink could use a strong local VHF path to an OceanMail Station at a marina/yacht club, which could then use its Internet path subject to accepted gateway policy. Current 47 CFR 80.501 includes organized yacht clubs with moorage facilities and certain nonprofit noncommercial services among private-coast-station eligibility categories, but that does not by itself settle frequency, emission, station-license, equipment-certification, public-correspondence, or commercial-service questions. Revalidate the complete regulatory path before implementation:

- https://www.ecfr.gov/current/title-47/chapter-I/subchapter-D/part-80/subpart-K/section-80.501

Regulatory analysis must be based on the applicable radio service, station eligibility, channel/use, emission, licensing, and actual communications purpose. Do not classify a transmission as commercial or noncommercial merely from the radio manufacturer, where the equipment was purchased, or a simplified assumption that all vessel-to-vessel traffic is one category.

### CB rejected for the current roadmap

Do not plan CB Radio Service as an OceanMail digital transport under current U.S. rules. Current 47 CFR 95.971 permits CB transmitter types for AM/SSB voice and optional FM voice emissions rather than a general-purpose digital data mode:

- https://www.ecfr.gov/current/title-47/chapter-I/subchapter-D/part-95/subpart-D/section-95.971

This is a regulatory rejection, not a technical claim that 27 MHz propagation would be useless. Reconsider only if the governing rules or a different lawful service/allocation creates a real data path.

## Rendezvous → working channel concept

Where lawful and technically supported, retain the research model:

1. Station listens/scans an authorized rendezvous set.
2. Station with useful pending work emits or responds to compact opportunity information rather than a complete mailbox catalog.
3. Peers determine whether useful work exists.
4. Peers select an authorized working/data channel.
5. Radio retunes automatically when configured, safe, and supported.
6. A short link-quality check validates the working channel.
7. If inadequate, return to rendezvous and try another appropriate channel.
8. If adequate, perform useful store-forward/mail work.
9. Return to rendezvous/listening state afterward.

This resembles established call/working-channel and ALE-style operational patterns; OceanMail should reuse established standards/upstream mechanisms where possible instead of inventing a proprietary equivalent.

## Do not chatter on every state change

New mail, receipts, account changes, route/gateway observations, or other local state may cause the scheduler to reassess pending work.

They should not automatically generate immediate RF control traffic.

Actual signaling must consider:

- expected value;
- current channel occupancy;
- collision avoidance;
- backoff/jitter;
- configured operating policy;
- regulatory limits; and
- power/cost constraints.

## Isolation discovery

A Station with no useful current connectivity may eventually need an efficient discovery method to determine whether a peer/gateway is available.

Any request/response design should suppress redundant simultaneous answers rather than causing every listener to transmit.

No wire format is selected here.

## Connected versus broadcast modes

The Station architecture should distinguish:

### Connected/ARQ link

Use a reliable connected path for pairwise work and trust the modem/link's own repair/adaptation.

### Broadcast/FEC/no-ack link

Use one-to-many/no-return-link techniques where they materially improve delivery, cooperative reception, policy distribution, emergency/control microtraffic, or other measured use cases.

HERMES Broadcast/RaptorQ is the first upstream candidate to evaluate rather than designing a new OceanMail fountain-code implementation.

Broadcast reception does not prove every listener received complete data.

## Passive listening

A Station may learn useful diagnostics/observations from traffic it can safely decode without becoming an active relay.

Distinguish:

- observed peer/link/capability evidence; and
- retained third-party payload.

Do not assume that arbitrary listeners can reconstruct a connected ARQ session unless the actual modem/link explicitly supports a monitor/cooperative mode that provides sufficient data.

## Radio control

Prefer standard upstream radio-control interfaces such as Hamlib where they satisfy requirements.

Station-specific radio profiles may include:

- CAT/PTT configuration;
- audio devices;
- supported bands/modes;
- power constraints;
- tuner/antenna information where available; and
- operator-defined regulatory/profile data.

Avoid hardwiring OceanMail to one radio model when generic control works.

## Link-quality evidence

Where upstream components expose it, collect evidence such as:

- effective throughput;
- session establishment time;
- bytes/airtime;
- retries/repair;
- selected modem mode/gear;
- SNR/RSSI/decode confidence;
- frequency/band;
- peer identity;
- failure reason; and
- interruption/resume outcome.

Do not require unavailable metrics merely to claim support for a transport.

## Vessel-heading / antenna-direction diagnostics

Optional vessel heading may be recorded and correlated with link performance using:

- peer/bearing where known;
- frequency/band;
- antenna configuration;
- vessel heading;
- propagation/environmental context; and
- time/season.

The purpose is to discover empirical Station-specific strengths/nulls over time.

Do not assume a sloped backstay antenna automatically provides superior range in the direction it leans or that simple geometry predicts its RF pattern.

## Propagation-aware operational policy

Future scheduling may use learned/forecast propagation as one input to decide when to attempt nonurgent work.

This is not a promise to transmit a user message at a fixed clock time. Opportunistic contacts remain more important than a rigid schedule.

Potential inputs include:

- frequency/band history;
- time of day/season;
- peer/region;
- learned success rates;
- available propagation forecasts; and
- current queue urgency.

## Trusted local relay relationship

Preserve research into explicitly authorizing another Station as a trusted local store-forward/rendezvous node for selected users/vessels.

Such a relationship should be established through authenticated identity/policy rather than a per-message pop-up.

A trusted relay need not replicate an entire historical mailbox. The minimum useful state may include eligible message objects, receipts, limited identity/authorization state, and bounded relay metadata.

This remains future relay research; current 0.2 first proves direct Station/gateway mail.

## Quota/accounting question retained

The old research identified a potential abuse issue if arbitrary addressed senders can automatically consume a recipient's scarce receive allowance.

Before constrained-link billing/quota rules are finalized, compare models such as:

- sender pays ordinary addressed injection;
- recipient pays primarily for recipient-initiated large/selective retrieval;
- relay operators consume separate voluntary contribution resources;
- direct one-hop delivery may receive an efficiency discount without becoming unlimited; and
- scheduling/fairness limits remain independent of billing so "free" local traffic cannot monopolize spectrum.

No accounting change is accepted by this research document. Program-level policy belongs in `OceanMail/oceanmail-project` and Server/service documentation.

## Historical modem findings

OceanMail 0.1 collected notes about PACTOR/SCS ALE, VARA HF, ARDOP, Mercury/HERMES, FreeDATA/Codec2, and related tools.

Those notes remain in `oceanmail-0.1-prototype` as historical evidence.

Before relying on any capability—monitor mode, ALE, channel control, broadcast behavior, modem command, license, or integration API—recheck current upstream documentation and implementation.

## Experimental priorities

After the current deterministic Mercury/UUCP proof is stable, useful experiments include:

1. severe/asymmetric reverse-link and lost-ACK conditions;
2. multiple legal/configured channel profiles in simulation/test harnesses;
3. connected versus broadcast/no-ack transfer cost;
4. interruption/restart across retune/reconnect;
5. observed throughput versus advertised modem rate;
6. radio-control portability through Hamlib;
7. short-range clear versus terrain-shadowed HF paths, including conditions where a nearer peer fails while a farther peer succeeds;
8. long-term frequency/peer/heading diagnostic correlation; and
9. whether rendezvous/working-channel automation materially improves successful useful bytes per unit airtime.

## Accepted scheduling/channel decision (2026-09-21)

[Project ADR-008](https://github.com/OceanMail/oceanmail-project/blob/main/docs/decisions/ADR-008-four-band-scheduling-and-channel-use.md) now fixes the high-level four-band policy and activity-based channel behavior: rendezvous announcements, negotiated addressed Band 1 control/manifests followed by Band 2 payload on the same channel, and announced shared broadcasts (normally Band 3; authenticated Server-promoted urgent updates are Band 1). Band 0 owns Emergency propagation/control and preempts ordinary work.

No separate frequency per scheduler band is required. Announce broadcast time, channel, dataset/version, and expected duration; hourly opportunities are optional when updates exist and do not reserve part of every lease. One radio requires bounded listening/check-in opportunities and proven Emergency discovery/preemption.

Overhearing depends on supported modem/link decoding or monitor/broadcast capabilities. Validate reusable public data; private manifests remain addressed/account-authorized, and listening confers neither custody nor ACK/transmit rights. Concrete frequencies, access/collision-avoidance protocols, pause/resume boundaries, and RF evidence remain future work; this decision does not authorize Phase 5.
