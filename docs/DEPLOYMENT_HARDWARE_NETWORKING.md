# OceanMail Station Deployment Hardware and Networking

Status: current component requirements. Organization-level authority and rationale: `OceanMail/oceanmail-project/docs/specifications/station-deployment-power-networking.md`.

## Station role model

Permanent managed gateways and vessel appliances run the same OceanMail Station software. A gateway is a configured Station role, not a separate software product.

## Reference hardware direction

Two hardware profiles are expected:

- **Marine/owner Station:** low-power, passively cooled ARM64 SBC class with Ethernet, USB, Wi-Fi, and durable local storage. Orange Pi-class hardware is a candidate reference family, not a frozen dependency.
- **Permanent/institutional gateway:** fanless x86-64 thin-client or N100-class hardware with Ethernet, multiple USB ports, replaceable SSD-class storage, and straightforward Debian support.

For permanent Internet-connected gateways, local capacity is less important than storage durability. They are transit nodes with bounded local queues/cache/logs, not long-term mailbox archives. 32–64 GB durable SSD-class storage is expected to be ample unless measured outage/backlog requirements prove otherwise.

## Networking behavior

The Station may provide a local Wi-Fi AP for OMail, OChat, Station management/status, and explicitly authorized Station APIs.

The Station is **not** a general-purpose Internet router:

- no general NAT service;
- no generic Internet forwarding for client devices;
- no requirement to replace the vessel's router/AP.

Preferred wired topology:

```text
radio <-> USB <-> Station <-> Ethernet <-> vessel LAN / Internet
                         \
                          +-- Wi-Fi AP <-> OceanMail clients
```

When Wi-Fi is the only upstream link, configuration must support:

- local AP mode while disconnected;
- STA/client mode to join Starlink, marina Wi-Fi, or another upstream AP;
- concurrent AP+STA only on hardware/driver combinations proven reliable;
- role switching when concurrent mode is unavailable;
- optional second USB Wi-Fi adapter so one radio can serve backhaul and the other the persistent OceanMail AP.

Do not infer AP+STA capability from dual-band marketing. Qualify the actual Linux chipset/driver behavior.

## Power and storage failure model

Abrupt power removal is a normal supported operating condition. Boat owners may wire Station power behind a physical switch and remove power without an OS shutdown.

Implementation must therefore ensure:

- durable queues and Station-owned state survive hard power loss;
- transactional/crash-safe writes where applicable;
- no critical state exists only in RAM;
- interrupted writes recover automatically;
- ordinary hard switch-off does not normally require manual filesystem repair;
- boot after power restoration automatically resumes Station services and durable work.

Prefer eMMC, SSD, or other robust storage over low-quality microSD where practical. Filesystem, database, queue, and log write patterns must be tested under repeated power cuts.

## Logging/storage implications

Structured operational telemetry may remain locally durable until confirmed central ingestion, then be aged or deleted according to policy. Detailed diagnostic/debug logs are a separate bounded-retention category. Avoid unbounded local logs on small appliances.

## Qualification tests still required

- ARM64 reference board selection and long-duration test;
- fanless x86-64 permanent-gateway reference selection;
- Ethernet + Wi-Fi AP operation;
- Wi-Fi client failover and recovery;
- concurrent AP+STA where proposed;
- USB Wi-Fi dual-radio fallback;
- repeated hard power cuts during active queue/database writes;
- idle/active power measurement;
- radio/USB/RF interference and reliability testing with supported ICOM-class hardware.
