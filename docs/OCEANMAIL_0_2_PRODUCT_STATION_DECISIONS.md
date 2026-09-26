# OceanMail 0.2 — Product, Client, Station, and Management Decisions

Status: **Accepted design direction**

Date: 2026-09-04; current policy reconciled 2026-09-10.

[Desktop Decision 0009](https://github.com/OceanMail/oceanmail-desktop/blob/main/docs/decisions/0009-ordinary-mail-scheduling-and-importance.md) supersedes older normal/Priority semantics. OMail has only Emergency and Ordinary transport classes. Important is conventional message metadata and must not affect RF precedence, Station queue precedence, relay precedence, gateway/path selection, credits/quota treatment, or automatic Available retrieval order. Credits do not buy ordinary transport precedence.

The [Available manifest and account authorization boundary](AVAILABLE_MANIFEST_ACCOUNT_CONTRACT.md) defines recipient-private metadata before constrained-link content transfer, including decentralized native boat-to-boat OMail without a central Server dependency. It is a logical contract, not an implemented API.

This document records the accepted product and architecture decisions made while separating OceanMail Station from the OceanMail client for the 0.2 line. It also records which major OceanMail 0.1 product concepts are intended to carry forward and which require redesign.

The former 0.1 transport implementation is not inherited. Requirements and product behavior may carry forward where they remain valid.

## 1. Core product architecture

OceanMail 0.2 has three primary technical components:

```text
OceanMail Client
      |
      | Station API / Internet service API
      v
OceanMail Station                  OceanMail Server
      |                                  ^
      | HERMES / Mercury /               |
      | future transports                |
      +----------- intermittent ----------+
```

### OceanMail Client

The client is the user-facing mail/chat/contact/calendar application and the user-facing entry point for account settings.

The intended direction is one cross-platform client family rather than separate independently maintained "Lite", "Standard", "Manager", and "Full" applications.

Target client platforms may include Windows, macOS, Linux, iOS, and Android.

The client may operate:

- directly against OceanMail Internet services when Internet is available;
- through an OceanMail Station when locally connected to one;
- with capabilities exposed according to the reachable services and the authenticated user's permissions.

### OceanMail Station

OceanMail Station is the vessel/onboard persistent communications and synchronization service. It is independent of any individual user's laptop and should be able to run autonomously on a headless Linux system.

The Station owns OceanMail communications policy/state, background work, transport correlation/evidence, local synchronization state, and vessel-level network observations. It coordinates and observes durable mail/store-and-forward state provided by Postfix, Taylor UUCP, mailbox storage, and later transports rather than duplicating those authoritative payload stores merely to create an OceanMail queue.

### OceanMail Server

The OceanMail Server remains authoritative for hosted/global service state such as server-side account state, hosted mailbox state, service policy, and any server-authoritative accounting.

## 2. OceanMail Lite and OceanMail Full are deployment/capability concepts

Do not create unnecessary separate applications merely to preserve the old product names.

### OceanMail Lite

"OceanMail Lite" should primarily describe the OceanMail client operating without a local Station, normally using direct Internet access when available.

Lite therefore does not need to be a separate desktop codebase.

### OceanMail Full

"OceanMail Full" remains a valid product/deployment concept.

OceanMail Full means the complete onboard OceanMail experience: **OceanMail Client + OceanMail Station**, packaged and configured as an integrated system.

Full may be deployed:

- on one computer where appropriate; or
- as a distributed vessel installation with a headless Station and one or more client devices.

The product boundary is therefore different from the process/repository boundary. Full is a product bundle; Station is a component.

## 3. One headless Station, multiple clients

A normal vessel deployment may have one always-on or frequently-on headless Linux Station and multiple OceanMail clients on the vessel LAN/Wi-Fi.

Example:

```text
Captain laptop ----\
Crew laptop --------+---- Vessel LAN/Wi-Fi ---- OceanMail Station ---- HERMES/Mercury ---- Radio
Crew laptop --------/
```

The Station must continue communications, retry, receive, queue, and synchronize work even when all user laptops are powered off.

Multiple clients/users should be able to use the same Station without each client running its own HF communications stack.

## 4. Station authorization and delegated administration

Administrative authority belongs to authenticated users/accounts, not implicitly to laptops.

Device trust/pairing and user authorization are separate concepts:

```text
trusted/paired client device
        +
authenticated user
        +
assigned role/permissions
        =
allowed Station operation
```

Initial role model:

- **Station Owner / Captain** — full control and recovery authority; may assign administrative rights.
- **Station Admin** — delegated Station administration subject to the permissions granted by the owner.
- **Operator** — operational controls such as permitted queue/link operations without full security/ownership authority.
- **User** — personal mail/chat/account use and permitted Station status/queue views.

A captain should be able to grant another crew member administrative rights so that person can manage the Station from another laptop.

Station administration must not automatically grant access to another user's private mailbox or personal account data. Station authority and personal account ownership remain distinct.

## 5. Client account changes may be staged through the Station

A user should be able to make supported OceanMail server/account changes while connected only to the local Station, even when the vessel has no Internet connectivity.

Expected flow:

```text
user changes supported account/server setting in client
        -> client submits authenticated change to Station
        -> Station stores pending operation durably for that user
        -> client may disconnect or power off
        -> Internet later becomes available to Station
        -> Station synchronizes pending operation with OceanMail Server
        -> server confirms authoritative resulting state
        -> Station records confirmed state/result
        -> client receives confirmed state on its next connection
```

This allows opportunistic Internet use. For example, a sleeping crew member does not need to reopen a laptop merely because the captain temporarily enables Starlink.

Pending operations must be isolated per user.

### Security-sensitive operations

Not every server/account operation should be blindly queued.

Security-sensitive operations such as password/recovery changes, account deletion, ownership changes, or other high-impact authentication changes may require fresh authentication, an appropriately scoped signed authorization, immediate server contact, or other stronger handling.

The exact list and authorization mechanism remains to be specified.

## 6. Web management is a first-class Station interface

OceanMail Station should provide a local web management interface in addition to its machine-facing API.

The web interface should use the same underlying Station API and authorization model used by the OceanMail client rather than creating a parallel management backend.

Conceptually:

```text
                         +--> local Station Web UI
OceanMail Station API ---+
                         +--> OceanMail Client Station views
```

This is intended to reduce duplicate implementation and make a headless Station straightforward to administer.

The client may render Station data natively, open the Station web interface, embed selected management views where platform/security constraints permit, or combine these approaches. The API remains the authoritative interface contract.

A dedicated separate "OceanMail Manager" application is **not planned now**. It may be reconsidered later if large/commercial installations justify it.

A small local recovery/setup web interface is also desirable for cases where the OceanMail client is unavailable.

## 7. Station tab / management access in the client

The previously planned Station area in the OceanMail client remains useful.

What the user sees depends on the authenticated role and connected Station capabilities.

A normal user might see:

- Station connectivity and health;
- Grid/server last-contact state;
- that user's outgoing/receive queues;
- transfer estimates and permitted statistics.

An operator/admin may additionally see:

- link/radio state;
- queues;
- network/gateway/relay settings where implemented;
- diagnostics;
- users and delegated permissions where authorized;
- system/update configuration.

The client is a presentation/control surface for Station state; it is not itself the communications Station.

## 8. Carry forward 0.1 background behavior into Station 0.2

The useful background behaviors designed during 0.1 should carry forward as Station requirements where they remain applicable.

This includes, subject to implementation against the 0.2 stack:

- durable outbound and inbound queues;
- background transmit/receive;
- retry after interruption/failure;
- independent sent/transmitted versus confirmed-remote-receipt state and timestamps;
- opportunistic Internet synchronization;
- account/server synchronization;
- per-user durable state needed for disconnected clients;
- Emergency/Ordinary scheduling and fair recipient retrieval policy;
- byte-budget policy/metadata;
- emergency priority/preemption policy;
- durable evidence and metrics;
- continuing work after clients disconnect or power off.

These are **product/Station requirements**, not permission to port the obsolete BEMPIC/M4P-based 0.1 transport architecture.

## 9. Station tracking, vessel maps, contacts, and observations carry forward

The map/dashboard/tracking concepts from 0.1 remain desired Station capabilities.

The Station should eventually maintain local durable observations such as:

- this vessel/Station's best-known navigation position and permitted history;
- other Stations heard or contacted;
- station/vessel last-seen time;
- approximate/advertised position where legitimately available;
- transport/link by which another Station was observed;
- known/advertised Station capabilities;
- known gateways and their freshness/availability;
- transfer history;
- bytes transmitted/received;
- connection/session success/failure;
- measured effective throughput;
- queued traffic and retry state;
- Internet connectivity history;
- radio/link status and measurements;
- permitted relay/gateway contribution observations;
- future routing/relay observations if those features return.

The Station owns this observation/history data. The web dashboard and OceanMail client consume it through the Station API.

## 10. Vessel position is not the same as a user's shared location

Preserve the 0.1 privacy distinction between:

- a Station/vessel's navigation/network position; and
- a person's consensually shared contact location.

A vessel with multiple crew should normally appear as one vessel/Station on a network map, with permitted crew/contact information associated with that vessel rather than drawing each crew member as an independent vessel/location marker.

Personal location sharing remains user-controlled, consent-based, freshness-limited, revocable, and separate from Station navigation/network positioning.

Station position used for radio/network operation must not silently imply personal location-sharing consent.

## 11. Dashboard and statistics direction

The Station web UI is the natural primary home for rich operational views.

Expected long-term dashboard areas include:

### Overview

- Station health;
- Grid/server last contact;
- Internet status;
- HF/link status;
- active transfers;
- queue summary.

### Map

- own vessel;
- known Stations/vessels;
- known gateways;
- last-seen positions and freshness;
- contact-related location only where consent/permissions permit.

### Communications

- Mercury/HERMES status;
- radios and configured transports;
- frequencies/channel information where applicable;
- link measurements;
- session history.

### Queue

- outbound;
- inbound;
- retryable/failed;
- future relay/gateway queues where implemented.

### Network

- known Stations;
- capabilities;
- last heard/contacted;
- known gateways;
- permitted relay observations.

### Relay / Gateway

- relay/gateway mode;
- configured limits;
- contribution/work statistics;
- future earned credits/reliability information where appropriate.

### Statistics

- bytes sent/received;
- airtime/on-air-equivalent use where measurable;
- throughput;
- successful/failed sessions;
- traffic by transport;
- Internet versus HF use;
- permitted relay/gateway contribution.

### Users

- vessel users;
- roles and delegated permissions;
- Station administrators.

### Server

- pending sync;
- last successful sync;
- queued account/server operations;
- service state.

### System

- hardware;
- storage;
- updates;
- logs/diagnostics;
- backups/recovery where applicable.

## 12. One Station API for client and web UI

Prefer a capability/outcome-oriented API instead of exposing raw modem internals.

Conceptual resource areas may eventually include:

```text
/api/station
/api/users
/api/queues
/api/transfers
/api/links
/api/stations
/api/map
/api/gateways
/api/relay
/api/statistics
/api/server-sync
```

These are conceptual names, not a frozen wire contract.

The important decision is that management state and operations should be exposed once through a secured Station API and reused by both the local web interface and OceanMail clients.

## 13. Station has distinct STORE/TRANSPORT and GRID/CONTROL responsibilities

OceanMail Station has two major functional planes connected through a small Station-owned core/API boundary.

```text
                       OceanMail Station
                              |
                    +---------+---------+
                    |   Station Core    |
                    | identity/config   |
                    | API/events/state  |
                    +---------+---------+
                              |
              +---------------+---------------+
              |                               |
              v                               v
    STORE / TRANSPORT Plane          GRID / CONTROL Plane
    -----------------------          --------------------
    SMTP/Postfix                     station/peer discovery
    Dovecot/mailbox storage          topology/observations
    HERMES uuxcomp/crmail            relay policy
    Taylor UUCP                      gateway policy
    Mercury                          OChat Grid behavior
    durable store/queue coordination reputation/telemetry
    HF/IP/future VHF                 map/network statistics
    transfer execution/evidence
```

The distinction is policy versus execution:

- the **GRID / CONTROL Plane** decides what the Station should do within the OceanMail network;
- the **STORE / TRANSPORT Plane** coordinates durable mail/store-and-forward state and performs accepted transfers using the available transport machinery;
- upstream HERMES, Mercury, UUCP, Postfix, Dovecot, and later transport/store adapters should not absorb OceanMail-specific relay, gateway, OChat, reputation, or network-policy logic merely for convenience.

The STORE / TRANSPORT Plane treats Postfix, Taylor UUCP, Dovecot/mailbox storage, and later transport stores as authoritative for the payloads they hold. OceanMail-owned Station state may persist correlation mappings, policy decisions, evidence, budgets, and other metadata, but must not create a parallel payload queue when an existing durable store already provides the authoritative transfer state.

Examples of GRID/CONTROL-to-STORE/TRANSPORT decisions include selecting a useful peer/gateway, accepting relay custody, applying Emergency precedence and ordinary fairness, and deciding whether local resource policy permits a transfer. STORE/TRANSPORT reports evidence back to GRID/CONTROL, such as bytes moved, peer/link used, success/failure, timestamps, and measurable link quality.

These are logical architecture boundaries. They do not require separate executables or machines in the first implementation.

## 14. Relay participation has no Off mode

A running OceanMail Station always participates in relay behavior at least as a reluctant relay. There is intentionally **no relay-disabled setting**.

If an operator does not want the Station participating at all, the Station/device must not be running.

Relay willingness has two modes:

### Eager relay

An eager relay actively advertises that it is available to help and may be selected normally by other Stations for eligible traffic.

The intended meaning is approximately:

> Here I am; use me for traffic I can help with.

Eager does not mean physically unlimited. Station managers may still configure whatever resource controls OceanMail ultimately exposes, such as RF airtime, storage, power, daily relay volume, schedules, metered/satellite Internet use, retry limits, or other defensible constraints.

### Reluctant relay

A reluctant relay **does not advertise itself as a relay at all**. It does not announce "I am available but prefer not to be used."

Instead it listens to surrounding Grid activity and may intervene when it determines that a nearby Station is failing to find a suitable relay or route.

Reluctant-relay decisions use Emergency, age/stall/failure and route/resource conditions, never a removed ordinary Priority class. Accepted intended behavior is:

- emergency traffic: help whenever technically possible and legally/operationally permitted;
- ordinary traffic: generally decline discretionary relay work;
- stranded/stalled ordinary traffic: may accept as fallback when route failure or accumulated delay warrants intervention, subject to resource conditions.

The exact timers, thresholds, retry evidence, age thresholds, and resource scoring are implementation details to be designed later. The semantic distinction is fixed: **eager relays advertise; reluctant relays remain silent until they decide intervention is warranted.**

Relay mode is GRID / CONTROL policy. Once a relay transfer is accepted, durable queueing, custody, retry, transmission, acknowledgement, expiry, and transfer evidence belong to the STORE / TRANSPORT machinery.

## 15. Gateway modes are Full, Minimal, and Off except Emergency

Gateway policy is independent of relay willingness. A Station may be eager or reluctant as an RF/store-forward relay while separately choosing how much Internet-gateway service it provides.

A Station having Internet connectivity does not by itself make it a general gateway.

### Full Gateway

A Full Gateway normally offers ordinary third-party Internet-gateway service, subject to resource, authorization, and applicable legal/operational policy.

### Minimal Gateway

The name **Minimal Gateway** is retained. It does not normally gateway ordinary third-party traffic, but may provide fallback for stranded/stalled ordinary traffic when Grid policy determines that no suitable Full Gateway/route exists or excessive delay has accumulated. Important metadata and credits do not affect this choice; there is no Priority transport class.

Emergency traffic is always eligible under OceanMail policy when the Station is technically capable and legally/operationally permitted to assist.

The exact definition of "too much" delay remains future policy work and should use observable route/link conditions rather than arbitrary claims of precision.

### Off

Gateway Off means no ordinary third-party gateway service.

It does **not** disable emergency gateway eligibility. If the running Station has the technical ability and legal/operational authority to move emergency traffic to the Internet, gateway configuration must not prevent it from doing so.

The intended matrix is:

| Gateway mode | Ordinary third-party traffic | Emergency traffic |
| --- | --- | --- |
| Full | Normally available | Eligible* |
| Minimal | Fallback for stranded/stalled traffic under Grid policy | Eligible* |
| Off | No | Eligible* |

\* Emergency eligibility remains subject to technical capability, applicable radio/service law, licensing, frequency/mode restrictions, authorization, and other operational constraints.

A Station may always use available Internet for its own authorized local OceanMail synchronization regardless of whether it offers third-party gateway service, subject to applicable service and legal constraints.

## 16. Emergency assistance is a Station policy invariant within legal/operational limits

While an OceanMail Station is running, OceanMail configuration must not prohibit it from assisting eligible emergency traffic when it is technically capable and legally/operationally permitted to do so.

This applies to both relay and gateway behavior:

- eager relay: emergency traffic is eligible;
- reluctant relay: emergency traffic is eligible even though the Station does not normally advertise itself;
- Full Gateway: emergency traffic is eligible;
- Minimal Gateway: emergency traffic is eligible;
- Gateway Off: emergency traffic is still eligible.

This invariant does not override physical impossibility or applicable law. A Station without a usable RF path cannot relay over that path, and a Station without Internet cannot act as an Internet gateway. Radio-service rules, operator/station licensing, frequency and mode restrictions, maritime requirements, and other controlling legal or operational constraints remain controlling.

Emergency handling must remain subject to later abuse/authentication safeguards so that merely labeling ordinary traffic "emergency" cannot become an unrestricted bypass of network protections.

## 17. OChat is GRID/CONTROL behavior using shared STORE/TRANSPORT resources

OChat remains logically separate from durable OMail store-and-forward relay policy.

OChat is primarily a GRID / CONTROL-plane service concerned with nearby participants, groups, visibility/presence, regional relevance, and ephemeral communication. Its bytes still use the Station's actual HF/VHF/IP STORE / TRANSPORT machinery, but OChat should not be embedded into the mail stack or treated as durable relay mail.

Accepted prior behavior remains:

- OChat is ephemeral rather than durable store-and-forward mail;
- OMail traffic has priority over OChat and may preempt it;
- eager/reluctant relay modes do not apply to ordinary OChat forwarding;
- OChat airtime/resource policy remains a separate GRID / CONTROL concern.

## 18. Gateway behavior remains useful without committing to the old global mesh

A Station that gains Internet connectivity may synchronize its own local OceanMail traffic immediately.

An authorized gateway-capable Station may also exchange eligible traffic for other Stations according to the Full/Minimal/Off policy above.

This remains valuable for permanent shore gateways and opportunistic vessel gateways even though speculative global multi-hop routing is currently deferred.

There is no separate OceanMail gateway software product. OceanMail-operated managed gateways use the same Station software as vessel Stations, configured and provisioned for their managed-gateway role.

## 19. Relay reliability/incentive work is retained as design material

The accepted 0.1 work around eager-relay contribution, verified useful-work credit, Grid-connected availability credit, locally observed relay reliability, decay toward neutral, anti-gaming, and server-side aggregation remains relevant design material.

It is not an implementation requirement for the initial HERMES/Mercury proof phases.

When relay behavior is implemented against the 0.2 stack, those decisions should be reviewed against the actual capabilities and evidence available from the selected Station transports.

Reluctant-relay assistance and emergency assistance should also be metered as network work where measurable, even if future incentive policy distinguishes them from proactively advertised eager-relay availability.

## 20. Design principle

The consolidated 0.2 principle is:

> **The Station observes and decides through its GRID / CONTROL responsibilities, then stores and communicates through its STORE / TRANSPORT responsibilities. It remembers, synchronizes, and continues operating independently of connected clients. The OceanMail client and Station web UI present and control that Station state according to authenticated user permissions.**

This allows laptops and users to come and go while the communications system continues operating across intermittent HF and Internet connectivity.

## 21. Carry-forward classification

| 0.1 concept | 0.2 disposition |
| --- | --- |
| Durable background queues | Preserve in Station through coordinated authoritative stores/queues; do not create unnecessary duplicate payload queues |
| Background TX/RX and retries | Preserve in Station |
| Separate transmitted and confirmed-receipt evidence | Preserve |
| Opportunistic Internet synchronization | Preserve in Station |
| User server/account setting sync | Preserve; Station stages supported operations |
| Multi-user vessel operation | Preserve/strengthen |
| Captain/admin delegation | Preserve/strengthen with role-based authorization |
| Station dashboard | Preserve; web UI becomes primary rich management surface |
| Station tab in client | Preserve as authorized presentation/control surface |
| Vessel/Station map and tracking | Preserve |
| Consensual personal/contact location | Preserve separately from vessel position |
| Statistics and history | Preserve in Station |
| Gateway settings | Preserve; Full / Minimal / Off-except-emergency semantics accepted |
| Eager relay | Preserve; advertises availability, subject to resource controls |
| Reluctant relay | Preserve; silent listener/fallback intervention, not advertised |
| Relay Off | Removed; no relay-off mode while Station is running |
| Emergency relay/gateway assistance | Mandatory OceanMail-policy eligibility while Station is running, technically capable, and legally/operationally permitted |
| OChat | Preserve as GRID / CONTROL behavior using shared STORE / TRANSPORT resources; not durable relay mail |
| Relay reliability/history | Preserve design; defer implementation |
| Relay incentives/credits | Preserve design material; defer implementation |
| BEMPIC integration | Deferred/not part of initial 0.2 Station baseline |
| M4P implementation | Tabled/not inherited into initial 0.2 |
| Old M4P-dependent routing implementation | Do not port |
| Speculative global multi-hop mesh | Deferred, not required for initial 0.2 |
| New OceanMail HF modem/DSP | Not planned for initial 0.2; use proven upstream components |

## 22. Non-goals created by this decision

Do not create multiple separately maintained client applications merely to represent Lite, Full, or management roles.

Do not require a captain's or crew member's laptop to remain powered on for Station background work.

Do not make a dedicated OceanMail Manager application a current requirement.

Do not duplicate the Station management backend for the web UI and desktop/mobile clients.

Do not treat Station administration as permission to inspect users' private mailbox contents.

Do not equate local transmission success with confirmed remote receipt.

Do not add a relay-disabled configuration state.

Do not advertise reluctant relays merely to label them as lower-priority relays; their defining behavior is that they remain silent until fallback intervention is warranted. No ordinary Priority class or Important marker controls eligibility.

Do not allow gateway configuration to disable emergency assistance while the Station is running, technically capable, and legally/operationally permitted to assist.

Do not put OceanMail GRID / CONTROL policy into HERMES, Mercury, Taylor UUCP, Postfix, Dovecot, or another upstream STORE / TRANSPORT component merely because that component happens to store or move the bytes.

Do not silently revive the abandoned 0.1 BEMPIC/M4P transport stack while implementing these carried-forward product requirements.
