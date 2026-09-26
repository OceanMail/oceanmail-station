# U.S. HF Regulatory Constraints for Station Research

- **Status:** Active constraint / unresolved regulatory research
- **Organization authority:** `OceanMail/oceanmail-project/workstreams/regulatory-compliance.md`
- **Scope:** Station RF control, testing, relay/gateway research, and physical-radio evidence

## Purpose

Translate the organization-level U.S. FCC workstream into Station-specific engineering constraints without pretending that Station documentation supplies legal authorization.

This file does not independently interpret or settle FCC law. If it conflicts with the project-spine regulatory workstream or a later authoritative regulatory decision, the project spine wins and this file must be reconciled.

## Current engineering constraints

### Physical-radio gate remains closed

Station's no-radio HERMES/Mercury proof does not authorize RF operation. Physical-radio Phase 5 remains held until the owner/project lead approves a defined hardware, frequency, emission, power, location, operator/license, and test scope supported by the required regulatory evidence.

A successful conducted bench setup, modem loopback, or certified radio does not by itself clear over-the-air operation.

### Do not assume generic license-free HF

Station must not encode an assumption that normal OceanMail maritime HF can operate under Part 15, CB, amateur-radio rules, or another generic license-free path. The current U.S. production investigation is centered on Part 80 maritime operation, with Part 5 as a possible experimental path where appropriate.

Amateur-radio testing, if separately lawful for a particular experiment and participants, is not evidence that the eventual OceanMail maritime service is authorized.

### Keep unattended transmit separable from automation

Station may research and implement non-RF automation such as queueing, persistence, scheduling decisions, receive processing, route evaluation, diagnostics, and operator prompts without assuming authority to key a transmitter unattended.

Until the project establishes a lawful unattended-transmission model, do not make unattended HF transmit a prerequisite for core Station correctness.

Design radio control so that these concepts remain distinguishable:

- automatic receive/listen;
- automatic local scheduling/selection;
- operator-authorized transmit/session initiation;
- automatic transmitter control while an authorized session is active; and
- fully unattended transmitter initiation.

The project-spine workstream records 47 CFR § 80.179 as a specific unresolved constraint: its enumerated unattended-transmitter permissions do not obviously cover arbitrary private HF OceanMail store-and-forward operation.

### Older test-plan language is qualified

`docs/testing-hardware-acquisition-plan.md` predates the detailed FCC reconciliation.

Its references to regional or professional-vessel "unattended" or "long unattended" operation must **not** be read as accepted authority for unattended HF transmission. Until the regulatory workstream clears such behavior, those test goals mean long-duration Station operation, receiving/listening, local automation, and only whatever transmit behavior is expressly authorized for the test.

Likewise, Stage 2 and later over-the-air tests may begin only after the regulatory scope for that stage is established. The hardware plan is a technical plan, not a radio authorization.

### Direct intership capability is not relay authority

Current Part 80 research identifies a radioprinter provision for direct intership operation between ships associated with a common private coast station. Station must not translate that observation into an assumption that autonomous multi-hop/store-carry-forward relay is lawful.

Direct peer communication, store-and-forward application behavior, relay policy, and unattended RF retransmission are separate questions. Multi-hop remains evidence-gated in the current project architecture even apart from regulation.

### Radio/channel profiles must carry regulatory provenance

The future region/service-aware channel catalog described in `RADIO_RENDEZVOUS_AND_LINK_REQUIREMENTS.md` remains useful, but it is an operator/software guardrail rather than legal authorization.

For any physical test or supported production profile, preserve enough metadata to identify the regulatory basis actually evaluated, including where applicable:

- jurisdiction/service;
- station/callsign/license or experimental authorization;
- frequency/channel;
- emission/mode and configured bandwidth;
- transmit power;
- selected radio/equipment authorization evidence;
- operator-control assumptions;
- automatic/unattended permissions or prohibitions;
- effective dates/conditions; and
- provenance for the rule/license/grant relied upon.

Fail closed for transmit if the active profile requires regulatory facts that are unknown or inconsistent with the approved test/deployment scope.

## Mercury / HERMES evidence needed before RF claims

Mercury remains the preferred upstream HF modem baseline, but upstream technical capability is not Part 80 authorization.

Before a physical-radio acceptance claim, preserve the exact Mercury/HERMES pin and evidence for the configuration actually transmitted, including:

- configured channel bandwidth;
- control and payload modes used;
- measured/authoritative occupied or necessary bandwidth evidence;
- PTT/radio-control behavior;
- automatic calling/session behavior;
- spectral/emission information needed for regulatory classification; and
- any upstream statement about intended regulatory domain.

Current upstream Mercury documentation exposes 500 Hz, 2300 Hz, and 2750 Hz bandwidth selections. Do not assume those settings map automatically to an FCC emission designator or permitted Part 80 service use.

## Radio selection

Do not hardwire Station architecture to one radio model solely for regulatory convenience. Generic Hamlib/control boundaries remain preferred where technically suitable.

The Icom IC-M803 is a current **candidate reference radio** because it is a marine MF/HF transceiver marketed for external HF email/modem use and has an FCC equipment-authorization record (`AFJ410000`). Before relying on it for a specific test/emission, archive and review the official grant/exhibits and the exact conditions relevant to that configuration.

A certified transmitter does not independently authorize OceanMail's selected waveform, frequency, traffic, service model, or unattended behavior.

## Physical-test evidence addition

When physical RF work is eventually authorized, test evidence should add regulatory/configuration identity to the existing technical measurements. At minimum, record the authorization/profile identifier used for the test alongside radio model, firmware if material, frequency, mode, bandwidth, power, location, antenna/test topology, Station/Mercury versions, and operator/control mode.

Do not describe a successful RF exchange as proof of regulatory compliance; it proves only the observed technical behavior under the recorded configuration.

## References

Organization-level rule findings, SailMail precedent, FCC staff-response summary, Mercury outreach questions, and authoritative-resolution requirements are maintained in:

`OceanMail/oceanmail-project/workstreams/regulatory-compliance.md`

Related Station research:

- `RADIO_RENDEZVOUS_AND_LINK_REQUIREMENTS.md`
- `../testing-hardware-acquisition-plan.md`
- `../UPSTREAM_BASELINE.md`
