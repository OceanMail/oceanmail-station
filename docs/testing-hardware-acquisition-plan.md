# OceanMail 0.2 Testing & Hardware Acquisition Plan

Original plan: 2026-09-03  
Reconciled with current project/Station authority: 2026-09-11

## Status and authority

This is the current **component-local planning document** for staged Station validation and hardware acquisition.

It does **not** authorize physical-radio work. [`CURRENT_STATUS.md`](CURRENT_STATUS.md), [`STATION_ARCHITECTURE.md`](STATION_ARCHITECTURE.md), and the `OceanMail/oceanmail-project` Station workstream remain authoritative for whether physical-radio work may begin. As of 2026-09-11, physical-radio **Phase 5 is HELD pending explicit owner/project-lead authorization and suitable hardware scope**.

The **Test Stage 0–5** labels below are this document's test progression only. They are not the Station implementation Phase 0–5 numbering. Any test stage that keys a physical radio is part of the held physical-radio Phase 5 authorization boundary.

## Purpose

This plan defines a staged validation path for OceanMail Station 0.2, from fully virtual nodes through controlled RF and later maritime field trials. Hardware purchases are tied to specific test stages rather than purchased speculatively.

**Core rule:** buy hardware only when a defined test stage requires it. Repurposed computers and isolated virtual infrastructure are the default development platforms until dedicated station hardware becomes necessary.

This test-acquisition rule does not select the eventual production/reference Station hardware. The project-level deployment specification separately requires qualification of marine ARM64 and permanent-gateway x86-64 reference profiles; repurposed laptops remain the current development/test nodes.

## Test resource categories

Select isolated virtual/container hosts, repurposed client hardware and authorized
fixed/mobile test sites appropriate to each stage. Personal equipment inventories,
site geometry and participant identities are kept outside public documentation.

Bluetooth and USB availability on repurposed laptops is useful for peripherals, radio control, diagnostics, and future experiments. It does **not** by itself establish Bluetooth or direct-USB client access as an accepted OceanMail Client/Station interface. The current product boundary is the authenticated Station API/local mail-service boundary over the vessel network once authentication/authorization permits LAN exposure.

## Test Stage 0 — Virtual Network Laboratory

### Goal

Validate as much of OceanMail as possible before purchasing radios.

### Environment

- Run multiple independent OceanMail station VMs on the Debian workstation.
- Use independently isolated virtual hosts when independent hosts, services, or failure domains are useful.
- Emulate links with controlled bandwidth, latency, packet loss, outages, asymmetric paths, and reconnection.
- Represent stations, gateways, and any later relay behavior virtually before RF implementation.
- Use HERMES/UUCP-compatible workflows wherever practical so the virtual harness resembles the physical station architecture.

### Required tests

- Store-and-forward persistence across process, station, and network failures.
- Interrupted transfers that resume without restarting completed work.
- Cases where substantial data is transmitted before an acknowledgement can return.
- Cases where the receiver accepts substantial data but the link disappears before acknowledgement.
- Duplicate suppression and idempotent re-delivery.
- Gateway appearance/disappearance and transport switching.
- Emergency/Ordinary scheduling, ordinary fairness/age protection, and evidence-state handling; do not reintroduce a sender-selectable ordinary Priority transport class.
- Sent/transmitted time and confirmed-receipt time as separate states.
- Multi-node forwarding experiments where applicable without requiring speculative mesh architecture in the 0.2 baseline.
- Station/client separation over local IP and, once accepted authentication/authorization permits it, vessel LAN/Wi-Fi access to the secured Station interface.

### Purchase gate

**No new hardware.**

Test Stage 0 is complete when failures caused by protocol/software behavior can be distinguished from failures introduced by RF/modem behavior.

## Test Stage 1 — Controlled Bench RF

### Goal

Introduce real HF radios and the real modem/audio/control path without depending on antennas or ionospheric propagation.

**Authorization note:** this is physical-radio Phase 5 work and must not begin merely because this plan exists.

### Bench topology

```text
Laptop A
   |
  USB
   |
HF Radio A
   |
controlled RF loading / attenuation / coupling
   |
HF Radio B
   |
  USB
   |
Laptop B
```

### Required purchases

| Item | Qty | Requirement / reason |
| --- | ---: | --- |
| HF transceiver | 2 | USB CAT/control required; USB audio strongly preferred; documented control; digital-mode capable |
| RF dummy load(s) | As required | Safe transmitter loading during bench development |
| RF attenuator/coupling components | 1 test set | Reduce transmitter energy to safe receiver levels and create repeatable link margins |
| Coax, adapters, patch cables | As required | Bench interconnection and instrumentation |
| USB cables/isolation | As required | Buy only after the selected radios define the need |

### Radio selection requirements

There are no existing HF radios that need to constrain the test design. Radios purchased for this test program **must be controllable over USB**. Prefer the simplest possible Station integration:

```text
Laptop --USB--> Radio
```

rather than requiring separate sound cards, CAT adapters, PTT interfaces, and multiple cables.

Candidate radios should have:

- reliable USB CAT/control support on Linux; Windows support desirable;
- USB audio input/output strongly preferred;
- software-controllable PTT and frequency/mode selection;
- compatibility with the HERMES/Mercury path selected for OceanMail 0.2;
- stable operation for sustained digital-mode duty cycles;
- adjustable transmit power, including low-power operation;
- documented control protocol and/or mature Hamlib support;
- practical antenna/tuner options for fixed, sailboat, and mastless motor-cruiser installations;
- reasonable cost and availability so a future supported test kit can be replicated.

### Required tests

- Automated frequency, mode, and PTT control from the Station software stack.
- Real Mercury/HERMES modem transmit/receive interoperability.
- Clean-link throughput baseline.
- Progressive degradation using controlled attenuation.
- Abrupt carrier loss during message transfer.
- Short reconnect windows followed by another outage.
- Asymmetric links where one direction is materially better than the other.
- Long transfers and acknowledgement-loss scenarios.
- Recovery after radio, modem, Station process, or laptop restart.
- Repeatability: the same attenuation/configuration should produce broadly comparable test results across repeated runs.

### RF safety

Two radios may physically sit beside each other on the bench, but they must not simply be connected transmitter-to-receiver or keyed into an unsuitable/open load. The conducted test arrangement must provide appropriate loading, isolation, attenuation, and power handling for the selected radios.

The exact attenuator/coupler topology should be designed only after the radio models and minimum useful transmit-power settings are known.

## Test Stage 2 — Local Over-the-Air Tests

### Goal

Compare controlled bench behavior with real propagation, terrain, antenna systems, and local RF noise.

**Authorization note:** this remains physical-radio Phase 5 work.

### Candidate paths

Compare authorized clear-path, obstructed-path, fixed-antenna and mobile-antenna
test sites. Select distances and terrain appropriate to the test objective;
record actual site details only in the restricted operational test plan.

Short-range HF behavior is frequency-, antenna-, terrain-, noise-, and propagation-dependent. These paths are useful precisely because they differ substantially rather than behaving like ideal line-of-sight laboratory links.

### Additional purchases — only when Test Stage 2 begins

- HF antenna system(s) appropriate to the selected radios and sites.
- Antenna tuner(s) where required.
- Feed line, grounding/bonding/counterpoise components, weather protection, and strain relief.
- Potential motor-cruiser whip/vertical system for the mastless boat.
- Potential sailboat backstay/long-wire-style installation for comparison.

### Data to record

- Frequency.
- Mode/modem.
- Transmit power.
- Antenna configuration.
- Station identity.
- Time and path.
- Link-establishment success.
- Transfer success/failure.
- Useful payload throughput.
- Retransmissions.
- Session duration.
- Interruption count.
- Signal-quality metrics exposed by modem/radio.
- Station position for mobile tests.
- Vessel heading later where available.
- Environmental and configuration notes sufficient to reproduce the test.

The long-term diagnostic objective is to correlate link quality with frequency, path/bearing, peer, antenna installation, Station position, vessel heading, and propagation conditions instead of assuming a particular antenna geometry predicts performance.

## Test Stage 3 — Boat Hybrid Connectivity & Marine Integration

### Goal

Exercise OceanMail as an actual maritime Station where RF, local networking, navigation data, and Internet connectivity coexist.

### Marine test platform requirements

Use an authorized vessel with suitable IP connectivity and navigation interfaces
for the planned scenarios. Inventory actual equipment privately before selecting
interfaces or purchasing hardware. Include mastless and sailboat antenna cases
where available; these are test categories, not an owner's vessel inventory.

### Key scenarios

1. Operate HF-only with queued traffic.
2. Starlink becomes reachable; accepted pending work can use the appropriate IP/Server path without losing state. Internet connectivity alone must not silently change the Station's configured third-party gateway policy.
3. Starlink disappears during operation; the Station returns to RF/store-and-forward behavior where policy and available transports permit.
4. An authenticated local OceanMail client connects/disconnects over the accepted vessel LAN/Wi-Fi Station interface while Station work continues. Bluetooth or direct-USB client access is not assumed unless separately designed and accepted later.
5. GPS position changes while underway and is associated with link observations.
6. Compare mastless motor-cruiser antenna performance with fixed-site and sailboat installations.
7. Observe interference/noise interactions from marine electronics and vessel power systems.
8. Confirm that loss or return of one transport never corrupts or ambiguously duplicates application-level delivery state.

### Marine-data purchase gate

Do not buy dedicated GPS, chartplotter, AIS, NMEA, or other marine-data interface hardware until the interfaces already present on the boat have been inventoried.

Select marine integration hardware only after determining whether useful data is already exposed through NMEA 0183, NMEA 2000, Ethernet, serial/USB, vendor APIs, or another available interface.

## Test Stage 4 — Regional Trial

### Goal

Move from local RF paths to a genuinely regional link and unattended/long-duration behavior.

### Candidate

Two authorized Stations at geographically separated regional test sites.

### Primary questions

- Frequency/time-of-day propagation behavior over a regional path.
- Automatic retry/scheduling across long periods when no usable path exists.
- Whether accumulated Station-specific link history improves later transport/frequency decisions.
- Message delivery across multiple contacts rather than requiring a continuous session.
- Operational simplicity for a participant who is not part of the development bench.
- Remote diagnostics: determine why a failed remote Station did not exchange traffic without requiring a developer at the Station.

### Hardware policy

Do not purchase participant hardware until the Test Stage 1/2 configuration is stable enough to define a repeatable supported kit.

## Test Stage 5 — Moving Professional-Vessel Field Trial

### Goal

Validate OceanMail in a professional moving-vessel environment after recreational and regional testing is stable.

### Candidate

An authorized professional-vessel participant, subject to owner/operator approval, radio licensing, installation constraints, and operational safety requirements.

### What this adds

- Continuous movement across changing propagation conditions.
- Real bridge/electrical RF-noise environment.
- Long unattended operation.
- Potential transitions among terrestrial IP, satellite IP, and HF availability.
- Operational feedback from a professional mariner.
- Realistic installation, maintainability, diagnostics, and failure-reporting requirements.

This is a late validation environment, not an early debugging environment.

## Cross-stage acceptance metrics

| Category | Minimum evidence to capture |
| --- | --- |
| Reliability | Delivery success/failure, retries, duplicate handling, corruption detection, restart recovery |
| Interruption tolerance | Bytes/messages preserved across signal loss; resume point; acknowledgement-loss behavior |
| Performance | Useful payload throughput, session setup time, airtime, overhead, queue latency |
| Store-forward | Forwarding/gateway decisions, expiry behavior, duplicate prevention, persistence |
| Transport switching | Reason and timing for RF/IP transition; unfinished-work handling |
| Radio/modem | Frequency, mode, power, modem metrics, control failures |
| Station context | Software version, hardware node, antenna configuration, position where applicable |
| User-visible state | Sent/transmitted timestamp, confirmed-receipt timestamp, Grid last-contact state, clear queued/synced status |

Every test harness should preserve enough metadata to reproduce failures and compare software revisions.

Evidence strength must continue to use the project's STATIC / UNIT, INTEGRATION, and LIVE / PRODUCT distinction. Bench or over-the-air RF results are LIVE/RF evidence only for the exact tested path and must not be generalized into production-security or global propagation claims.

## Consolidated shopping list by decision point

| Priority | Item | Current decision |
| --- | --- | --- |
| Now | Dedicated mini-PC/SBC station computers | **Do not buy.** Repurpose existing laptops. |
| Now | Additional servers | **Do not buy.** Use Debian VMs and isolated virtual infrastructure. |
| First physical-radio purchase | Two HF transceivers | Required for Test Stage 1 after physical-radio Phase 5 is explicitly authorized. USB control is required; USB audio is strongly preferred. |
| First physical-radio purchase | Dummy-load/attenuation/coupling equipment | Required for safe, repeatable Test Stage 1 bench RF. Exact components depend on selected radios. |
| First physical-radio purchase | Coax/adapters/cables | Buy to match selected radios and bench topology. |
| Later | HF antennas/tuners | Test Stage 2 only; choose separately for fixed-site and marine tests. |
| Later | Marine-data interface hardware | Test Stage 3 only after onboard interface inventory. |
| Much later | PACTOR hardware | Not required for initial HERMES/Mercury development; acquire only for explicit PACTOR interoperability work. |
| Much later | Participant station kits | Only after a supported hardware configuration emerges from local testing. |

## Immediate hardware decision

**Do not purchase dedicated Station computers or additional servers.** Existing laptops and virtual infrastructure are sufficient for the current no-radio work.

When physical-radio Phase 5 is explicitly authorized, the first hardware budget should be reserved for:

1. **Two carefully selected USB-controllable HF transceivers.**
2. **The safe conducted-RF bench equipment required to test those specific radios.**
3. **Matching coax, adapters, and USB cabling.**

Do not choose the attenuator/coupler package independently of the radios; safe attenuation and power-handling requirements depend on transmitter characteristics and the bench topology.

After controlled bench RF is stable, choose antennas and tuners for the actual local over-the-air sites.