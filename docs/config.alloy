loki.write "main" {
  endpoint {
    url = "http://192.168.100.138:3100/loki/api/v1/push"
  }
}

loki.source.windowsevent "sysmon_filtered" {
  eventlog_name = "Microsoft-Windows-Sysmon/Operational"

  # Ship only selected Sysmon Event IDs
  xpath_query = "*[System[(EventID=1 or EventID=3 or EventID=8 or EventID=10 or EventID=12 or EventID=13 or EventID=14 or EventID=15)]]"

  # Read-state tracking for this channel
  bookmark_path = "C:\\ProgramData\\GrafanaLabs\\Alloy\\bookmarks\\sysmon.xml"

  labels = {
    job  = "windows"
    host = env("COMPUTERNAME")
    log  = "sysmon"
  }

  forward_to = [loki.write.main.receiver]
}
