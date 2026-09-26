# OceanMail Station Development Environment

Status: ACTIVE WORKFLOW GUIDANCE

Debian/Linux is the default development and integration environment for OceanMail Station 0.2 work.

Use Debian/Linux by default for:

- HERMES/Mercury integration;
- Taylor UUCP, `uucpd`, `uuxcomp`, Postfix/Dovecot lab paths;
- Hamlib/radio-control work;
- modem/channel simulation and later physical-radio integration;
- Station service/API/backend work;
- containerized and deployment-oriented integration testing.

Windows remains important for OceanMail Desktop/client-specific behavior, packaging, and platform validation, but it is not the primary Station integration environment.

This is a development/workflow preference, not a product-platform restriction. Cross-platform client behavior still requires platform-appropriate testing, and accepted Station behavior must be demonstrated with the evidence level claimed rather than inferred from the development host.