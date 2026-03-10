#**install Sysmon using Microsoft Sysinternals**

New-Item -ItemType Directory -Force C:\sysmon | Out-Null

Invoke-WebRequest https://download.sysinternals.com/files/Sysmon.zip -OutFile C:\sysmon\Sysmon.zip
Expand-Archive C:\sysmon\Sysmon.zip -DestinationPath C:\sysmon -Force

Invoke-WebRequest https://raw.githubusercontent.com/SwiftOnSecurity/sysmon-config/master/sysmonconfig-export.xml -OutFile C:\sysmon\sysmon-config.xml

cd C:\sysmon
.\Sysmon64.exe -accepteula -i sysmon-config.xml


