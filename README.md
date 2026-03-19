# Sysmon-Loki_Logging

## Overview

This project implements a lightweight endpoint logging pipeline using **Sysmon**, **Grafana Alloy**, **Loki**, and **Grafana**.

The objective is to provide improved visibility into endpoint activity by capturing security-relevant events such as:

* remote logons
* service installations
* process execution
* other behaviour indicative of changes to system security posture

The pipeline is designed to prioritise **high-value telemetry** while minimising noise, bandwidth usage, and storage overhead.

---

## Architecture Summary

Each endpoint performs the following:

1. **Sysmon** is installed with a custom configuration (based on SwiftOnSecurity’s baseline) to generate structured security events.
2. Events are written to the Windows Event Log.
3. **Grafana Alloy** reads these logs and forwards them to **Loki**.
4. **Loki** ingests and stores the logs.
5. Logs are queried and visualised in **Grafana**.

---

## Key Design Principles

- **Selective logging**
  Only relevant security events are captured to reduce noise.

- **Lightweight deployment**
  Designed to minimise system and network impact on endpoints.

- **Centralised visibility**
  All logs are aggregated in Loki and accessible via Grafana.

- **Automated deployment**
  Installation and removal scripts support scalable rollout (e.g. via PDQ Deploy).

---

## Components

- **Sysmon** : Endpoint telemetry collection
- **Grafana Alloy** : Log collection and forwarding
- **Loki** : Log aggregation and storage
- **Grafana** : Visualisation and querying

---

## Configuration

- Sysmon is deployed with a **custom configuration** derived from SwiftOnSecurity’s baseline, tuned to reduce excessive logging.
- Alloy configuration is currently **embedded within the installer script**.
- A local copy of the Alloy configuration is written to the endpoint to allow further modification if required.

---

## Prerequisites

- A server capable of running:

  ~ Grafana
  ~ Loki
- Loki accessible over the network (default port: `3100`)
- Windows endpoints with:

  ~ Administrator privileges
  ~ Network access to the Loki instance

---

## Purpose

This project is intended to:

- Improve visibility into endpoint behaviour
- Provide a foundation for detection and monitoring
- Enable centralised log analysis using Grafana

---

## Current Drawbacks
 - Currently has a test Loki IP address hardcoded into the **param block (line 2)**
   This can prove to be an issue as Loki hosts will most likely have a different IP address.
   Current solution is to edit the IP address in the script to the same as Loki host IP address

---

## Future Improvements

- Alerting based on key security events
- Expanded Windows Event Log ingestion
- Config versioning and update mechanism
- Dashboard development for common detection scenarios
- Health monitoring and tamper detection
