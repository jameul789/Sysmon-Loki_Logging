# Sysmon-Loki_Logging

This project is my attempt to use Sysmon, Windows Security Logs, Loki and Grafana to build a logging system for end users. This will hopefully aid in security and gve a better sense of idea on the unseen movements that may happen on end-user devices. This will be a logging pipeline that will only capture important information such as remote sessions, service installations and other moments that shape security posture. The logs will be kept specific to these types of things to keep it lightweight and bandwidth friendly.


This repository explains how to send Sysmon logs to Loki using Grafana Alloy.

## Documentation

- [Setup Guide](docs/setup-guide.md)
- [Alloy Installation](docs/alloy-installation.md)
- [Alloy Configuration](docs/alloy-config.md)
- [Sysmon Installation](docs/sysmon-installation.md)
