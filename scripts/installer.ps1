param(
    [string]$LokiHost = "192.168.100.138",
    [int]$LokiPort = 3100,
    [string]$SysmonConfigUrl = "https://raw.githubusercontent.com/jameul789/Sysmon-Loki_Logging/main/configs/sysmon-caspian.xml",
    [int]$SysmonInstallAttempts = 3,
    [int]$HttpRetryCount = 12,
    [int]$HttpRetryDelaySeconds = 5,
    [switch]$ForceRewriteAlloyConfig
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "Continue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Write-Section {
    param([Parameter(Mandatory)][string]$Title)

    Write-Host ""
    Write-Host "=========================================="
    Write-Host " $Title"
    Write-Host "=========================================="
    Write-Host ""
}

function Assert-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)

    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this script in an elevated PowerShell session."
    }
}

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function Download-File {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination
    )

    $tempDestination = "$Destination.download"

    if (Test-Path -LiteralPath $tempDestination) {
        Remove-Item -LiteralPath $tempDestination -Force -ErrorAction SilentlyContinue
    }

    Write-Host "Downloading: $Url"

    try {
        Invoke-WebRequest -Uri $Url -OutFile $tempDestination -UseBasicParsing
    }
    catch {
        Write-Warning "Invoke-WebRequest failed, falling back to BITS: $($_.Exception.Message)"
        Start-BitsTransfer -Source $Url -Destination $tempDestination
    }

    if (-not (Test-Path -LiteralPath $tempDestination)) {
        throw "Download failed: $Url"
    }

    Move-Item -LiteralPath $tempDestination -Destination $Destination -Force

    if (-not (Test-Path -LiteralPath $Destination)) {
        throw "Downloaded file not found after move: $Destination"
    }

    $fileInfo = Get-Item -LiteralPath $Destination
    if ($fileInfo.Length -le 0) {
        throw "Downloaded file is empty: $Destination"
    }
}

function Invoke-External {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter()][string[]]$Arguments = @(),
        [switch]$IgnoreExitCode
    )

    & $FilePath @Arguments
    $exitCode = $LASTEXITCODE

    if (-not $IgnoreExitCode -and $exitCode -ne 0) {
        $joinedArgs = ($Arguments -join " ")
        throw "Command failed with exit code $exitCode : `"$FilePath`" $joinedArgs"
    }

    return $exitCode
}

function Get-SysmonService {
    Get-Service -Name "sysmon*" -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Test-BuiltInSysmonEnabled {
    try {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName "Sysmon" -ErrorAction Stop
        return ($feature.State -eq "Enabled")
    }
    catch {
        return $false
    }
}

function Wait-ForServiceStatus {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet("Running","Stopped")][string]$DesiredStatus,
        [int]$TimeoutSeconds = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    do {
        $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if ($service -and $service.Status.ToString() -eq $DesiredStatus) {
            return $service
        }

        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)

    $current = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($current) {
        throw "Service '$Name' did not reach state '$DesiredStatus' within $TimeoutSeconds seconds. Current state: $($current.Status)"
    }

    throw "Service '$Name' was not found while waiting for state '$DesiredStatus'."
}

function Wait-ForSysmonChannel {
    param([int]$TimeoutSeconds = 60)

    Write-Host "Waiting for Sysmon event channel to appear..."

    $logName = "Microsoft-Windows-Sysmon/Operational"
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    do {
        try {
            $null = Get-WinEvent -ListLog $logName -ErrorAction Stop
            Write-Host "Sysmon event channel found: $logName"
            return
        }
        catch {
            Start-Sleep -Seconds 2
        }
    } while ((Get-Date) -lt $deadline)

    throw "Sysmon event channel did not appear within $TimeoutSeconds seconds: $logName"
}

function Expand-ZipSafe {
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    if (-not (Test-Path -LiteralPath $ZipPath)) {
        throw "Zip file not found: $ZipPath"
    }

    Ensure-Directory $DestinationPath
    Expand-Archive -Path $ZipPath -DestinationPath $DestinationPath -Force
}

function Install-OrUpdate-Sysmon {
    param(
        [Parameter(Mandatory)][string]$SysmonDir,
        [Parameter(Mandatory)][string]$ConfigUrl,
        [Parameter(Mandatory)][int]$InstallAttempts
    )

    Write-Section "Installing Sysmon"

    if (Test-BuiltInSysmonEnabled) {
        throw "Built-in Sysmon is enabled on this machine. Standalone Sysmon does not support coexistence with built-in Sysmon."
    }

    Ensure-Directory $SysmonDir

    $zipPath = Join-Path $SysmonDir "Sysmon.zip"
    $sysmonExe = Join-Path $SysmonDir "Sysmon64.exe"
    $sysmonConfig = Join-Path $SysmonDir "swiftonsecurity-caspian.xml"
    $sysmonZipUrl = "https://download.sysinternals.com/files/Sysmon.zip"

    Download-File -Url $sysmonZipUrl -Destination $zipPath
    Expand-ZipSafe -ZipPath $zipPath -DestinationPath $SysmonDir

    if (-not (Test-Path -LiteralPath $sysmonExe)) {
        throw "Sysmon64.exe not found after extraction: $sysmonExe"
    }

    Download-File -Url $ConfigUrl -Destination $sysmonConfig

    $existingService = Get-SysmonService
    if ($existingService) {
        Write-Host "Sysmon already present as service '$($existingService.Name)'. Updating configuration..."
        Invoke-External -FilePath $sysmonExe -Arguments @("-c", $sysmonConfig)
        Wait-ForSysmonChannel -TimeoutSeconds 60
        $svc = Get-SysmonService
        Write-Host "Sysmon configured."
        Write-Host "Sysmon service: $($svc.Name)"
        Write-Host "Sysmon status : $($svc.Status)"
        return
    }

    $lastExitCode = $null
    for ($attempt = 1; $attempt -le $InstallAttempts; $attempt++) {
        Write-Host "Installing Sysmon (attempt $attempt of $InstallAttempts)..."

        $lastExitCode = Invoke-External -FilePath $sysmonExe -Arguments @("-accepteula", "-i", $sysmonConfig) -IgnoreExitCode
        Start-Sleep -Seconds 5

        $service = Get-SysmonService
        if ($service) {
            Write-Host "Sysmon service detected: $($service.Name)"
            break
        }

        Write-Warning "Sysmon service not present after attempt $attempt. Exit code: $lastExitCode"
    }

    $service = Get-SysmonService
    if (-not $service) {
        throw "Sysmon installation did not create a service after $InstallAttempts attempts. Last exit code: $lastExitCode"
    }

    try {
        Wait-ForServiceStatus -Name $service.Name -DesiredStatus "Running" -TimeoutSeconds 30 | Out-Null
    }
    catch {
        Write-Warning "Sysmon service exists but did not reach Running state in time: $($_.Exception.Message)"
    }

    Wait-ForSysmonChannel -TimeoutSeconds 60

    $service = Get-SysmonService
    Write-Host "Sysmon installed/configured."
    Write-Host "Sysmon service: $($service.Name)"
    Write-Host "Sysmon status : $($service.Status)"
}

function Write-AlloyConfig {
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$LokiPushUrl,
        [Parameter(Mandatory)][string]$BookmarkPath,
        [switch]$Force
    )

    Write-Section "Writing Alloy configuration"

    $config = @"
loki.write "main" {
  endpoint {
    url = "$LokiPushUrl"
  }
}

loki.source.windowsevent "sysmon_filtered" {
  eventlog_name = "Microsoft-Windows-Sysmon/Operational"
  xpath_query   = "*[System[(EventID=1 or EventID=3 or EventID=8 or EventID=10 or EventID=12 or EventID=13 or EventID=14 or EventID=15)]]"
  bookmark_path = "$BookmarkPath"

  labels = {
    job  = "windows",
    host = sys.env("COMPUTERNAME"),
    log  = "sysmon",
  }

  forward_to = [loki.write.main.receiver]
}
"@

    $parent = Split-Path -Path $ConfigPath -Parent
    Ensure-Directory $parent

    if ((Test-Path -LiteralPath $ConfigPath) -and (-not $Force)) {
        Write-Host "Existing Alloy config found at $ConfigPath. Leaving it unchanged."
        return
    }

    Set-Content -Path $ConfigPath -Value $config -Encoding UTF8

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Failed to write Alloy config: $ConfigPath"
    }

    $content = Get-Content -LiteralPath $ConfigPath -Raw
    if ([string]::IsNullOrWhiteSpace($content)) {
        throw "Alloy config file is empty: $ConfigPath"
    }

    Write-Host "Alloy config written to: $ConfigPath"
}

function Get-AlloyExePath {
    try {
        $svc = Get-CimInstance Win32_Service -Filter "Name='Alloy'" -ErrorAction Stop
        if ($svc -and $svc.PathName) {
            if ($svc.PathName -match '^\s*"([^"]+alloy\.exe)"') {
                $candidate = $matches[1]
                if (Test-Path -LiteralPath $candidate) {
                    return $candidate
                }
            }
            elseif ($svc.PathName -match '^\s*([^\s].*?alloy\.exe)\s') {
                $candidate = $matches[1].Trim('"')
                if (Test-Path -LiteralPath $candidate) {
                    return $candidate
                }
            }
            else {
                $candidate = $svc.PathName.Trim('"')
                if (Test-Path -LiteralPath $candidate) {
                    return $candidate
                }
            }
        }
    }
    catch {
    }

    $candidates = @()

    if ($env:ProgramFiles) {
        $candidates += (Join-Path $env:ProgramFiles "GrafanaLabs\Alloy\alloy.exe")
    }

    if (${env:ProgramFiles(x86)}) {
        $candidates += (Join-Path ${env:ProgramFiles(x86)} "GrafanaLabs\Alloy\alloy.exe")
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    $uninstallKeys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    foreach ($key in $uninstallKeys) {
        try {
            $apps = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
            foreach ($app in $apps) {
                if ($app.DisplayName -like "*Alloy*") {
                    foreach ($field in @("InstallLocation", "DisplayIcon")) {
                        $value = $app.$field
                        if (-not [string]::IsNullOrWhiteSpace($value)) {
                            $candidate = $value.Trim('"')
                            if ($candidate -like "*.exe") {
                                if (Test-Path -LiteralPath $candidate) {
                                    return $candidate
                                }
                            }
                            else {
                                $exe = Join-Path $candidate "alloy.exe"
                                if (Test-Path -LiteralPath $exe) {
                                    return $exe
                                }
                            }
                        }
                    }
                }
            }
        }
        catch {
        }
    }

    $roots = @()
    if ($env:ProgramFiles) { $roots += $env:ProgramFiles }
    if (${env:ProgramFiles(x86)}) { $roots += ${env:ProgramFiles(x86)} }

    foreach ($root in $roots | Select-Object -Unique) {
        try {
            $found = Get-ChildItem -Path $root -Filter "alloy.exe" -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -match 'GrafanaLabs\\Alloy\\alloy\.exe$' } |
                Select-Object -First 1 -ExpandProperty FullName

            if ($found) {
                return $found
            }
        }
        catch {
        }
    }

    return $null
}

function Test-AlloyConfig {
    param(
        [Parameter(Mandatory)][string]$AlloyExe,
        [Parameter(Mandatory)][string]$ConfigPath
    )

    if (-not (Test-Path -LiteralPath $AlloyExe)) {
        throw "Alloy executable not found: $AlloyExe"
    }

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Alloy config not found: $ConfigPath"
    }

    try {
        Write-Host "Validating Alloy config..."
        Invoke-External -FilePath $AlloyExe -Arguments @("validate", $ConfigPath)
    }
    catch {
        Write-Warning "Alloy config validation command failed or is unavailable in this installed version: $($_.Exception.Message)"
        Write-Warning "Continuing with service start; if the service fails, check Alloy logs."
    }
}

function Uninstall-AlloyIfBroken {
    Write-Section "Repairing broken Alloy installation"

    $service = Get-Service -Name "Alloy" -ErrorAction SilentlyContinue
    if ($service) {
        try {
            if ($service.Status -eq "Running") {
                Stop-Service -Name "Alloy" -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 3
            }
        }
        catch {
        }
    }

    $uninstallExeCandidates = @(
        (Join-Path $env:ProgramFiles "GrafanaLabs\Alloy\uninstall.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "GrafanaLabs\Alloy\uninstall.exe")
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

    $uninstalled = $false

    foreach ($uninstallExe in $uninstallExeCandidates) {
        try {
            Write-Host "Running Alloy uninstaller: $uninstallExe"
            Start-Process -FilePath $uninstallExe -ArgumentList "/S" -Wait -NoNewWindow
            Start-Sleep -Seconds 5
            $uninstalled = $true
            break
        }
        catch {
            Write-Warning "Failed to run Alloy uninstaller at $uninstallExe : $($_.Exception.Message)"
        }
    }

    if (-not $uninstalled) {
        Write-Warning "Alloy uninstaller was not found. Removing service and install folders manually."

        try {
            sc.exe stop Alloy | Out-Null
        }
        catch {
        }

        try {
            sc.exe delete Alloy | Out-Null
        }
        catch {
        }

        Start-Sleep -Seconds 3

        $pathsToRemove = @(
            (Join-Path $env:ProgramFiles "GrafanaLabs\Alloy"),
            (Join-Path ${env:ProgramFiles(x86)} "GrafanaLabs\Alloy")
        ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

        foreach ($path in $pathsToRemove) {
            try {
                Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
            }
            catch {
                Write-Warning "Failed to remove path: $path"
            }
        }
    }

    if (Test-Path -LiteralPath "HKLM:\SOFTWARE\GrafanaLabs\Alloy") {
        try {
            Remove-Item -LiteralPath "HKLM:\SOFTWARE\GrafanaLabs\Alloy" -Recurse -Force -ErrorAction SilentlyContinue
        }
        catch {
            Write-Warning "Failed to remove HKLM:\SOFTWARE\GrafanaLabs\Alloy"
        }
    }
}

function Install-OrUpdate-Alloy {
    param(
        [Parameter(Mandatory)][string]$LiveConfigPath,
        [Parameter(Mandatory)][string]$DataDir
    )

    Write-Section "Installing Grafana Alloy"

    $tempDir = "C:\Temp\alloy"
    Ensure-Directory $tempDir
    Ensure-Directory $DataDir

    $installerPath = Join-Path $tempDir "alloy-installer-windows-amd64.exe"
    $installerUrl = "https://github.com/grafana/alloy/releases/latest/download/alloy-installer-windows-amd64.exe"

    $service = Get-Service -Name "Alloy" -ErrorAction SilentlyContinue
    $alloyExe = Get-AlloyExePath

    if ($service -and -not $alloyExe) {
        Write-Warning "Alloy service exists but alloy.exe could not be located. Treating installation as broken."
        Uninstall-AlloyIfBroken
        $service = $null
    }

    if (-not $service) {
        Download-File -Url $installerUrl -Destination $installerPath

        $installerInfo = Get-Item -LiteralPath $installerPath
        if ($installerInfo.Length -lt 5MB) {
            throw "Downloaded Alloy installer looks too small ($($installerInfo.Length) bytes): $installerPath"
        }

        $signature = Get-AuthenticodeSignature -FilePath $installerPath
        if ($signature.Status -ne "Valid") {
            throw "Alloy installer signature is not valid. Status: $($signature.Status)"
        }

        Write-Host "Installing Alloy silently..."
        Start-Process -FilePath $installerPath -ArgumentList "/S" -Wait -NoNewWindow
        Start-Sleep -Seconds 5
    }
    else {
        Write-Host "Alloy service already present. Reusing existing installation."
    }

    $service = Get-Service -Name "Alloy" -ErrorAction SilentlyContinue
    if (-not $service) {
        throw "Alloy service not found after install."
    }

    $alloyRegKey = "HKLM:\SOFTWARE\GrafanaLabs\Alloy"
    if (-not (Test-Path -LiteralPath $alloyRegKey)) {
        throw "Alloy registry config key not found: $alloyRegKey"
    }

    $alloyExe = Get-AlloyExePath
    if ($alloyExe) {
        Test-AlloyConfig -AlloyExe $alloyExe -ConfigPath $LiveConfigPath
    }
    else {
        Write-Warning "Could not locate alloy.exe even after reinstall. Skipping validation."
    }

    if ($service.Status -eq "Running") {
        Write-Host "Stopping Alloy service before updating arguments..."
        Stop-Service -Name "Alloy" -Force
        Wait-ForServiceStatus -Name "Alloy" -DesiredStatus "Stopped" -TimeoutSeconds 30 | Out-Null
    }

    $arguments = [string[]]@(
        "run",
        $LiveConfigPath,
        "--storage.path=$DataDir"
    )

    Set-ItemProperty -Path $alloyRegKey -Name "Arguments" -Value $arguments -Type MultiString

    Write-Host "Starting Alloy service..."
    Start-Service -Name "Alloy"
    Wait-ForServiceStatus -Name "Alloy" -DesiredStatus "Running" -TimeoutSeconds 30 | Out-Null

    $service = Get-Service -Name "Alloy"
    Write-Host "Alloy installed/configured."
    Write-Host "Alloy status: $($service.Status)"
    Write-Host ("Alloy exe   : {0}" -f $(if ($alloyExe) { $alloyExe } else { "not found" }))
}

function Test-HttpEndpoint {
    param(
        [Parameter(Mandatory)][string]$Url,
        [int]$RetryCount = 12,
        [int]$DelaySeconds = 5,
        [Parameter(Mandatory)][string]$FriendlyName
    )

    Write-Section "Testing $FriendlyName connectivity"

    $lastError = $null

    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        try {
            Write-Host ("Attempt {0} of {1}: {2}" -f $attempt, $RetryCount, $Url)
            $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5
            if ($response.StatusCode -eq 200) {
                Write-Host "$FriendlyName is reachable."
                return
            }

            $lastError = "$FriendlyName returned HTTP $($response.StatusCode)"
        }
        catch {
            $lastError = $_.Exception.Message
        }

        if ($attempt -lt $RetryCount) {
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    throw "$FriendlyName readiness check failed after $RetryCount attempts. Last error: $lastError"
}

function Test-SysmonChannel {
    Write-Section "Checking Sysmon event channel"

    $events = Get-WinEvent -LogName "Microsoft-Windows-Sysmon/Operational" -MaxEvents 5 -ErrorAction SilentlyContinue

    if (-not $events) {
        Write-Warning "No Sysmon events found yet. Generate activity and test again."
        return
    }

    $events | Select-Object TimeCreated, Id, ProviderName | Format-Table -AutoSize
}

function Show-Diagnostics {
    Write-Section "Diagnostics"

    Write-Host "Sysmon services:"
    Get-Service -Name "sysmon*" -ErrorAction SilentlyContinue | Format-Table Name, Status, DisplayName -AutoSize

    Write-Host ""
    Write-Host "Alloy service:"
    Get-Service -Name "Alloy" -ErrorAction SilentlyContinue | Format-Table Name, Status, DisplayName -AutoSize

    Write-Host ""
    Write-Host "Alloy service CIM details:"
    Get-CimInstance Win32_Service -Filter "Name='Alloy'" -ErrorAction SilentlyContinue |
        Select-Object Name, State, StartMode, PathName |
        Format-List

    Write-Host ""
    Write-Host "Alloy registry settings:"
    Get-ItemProperty "HKLM:\SOFTWARE\GrafanaLabs\Alloy" -ErrorAction SilentlyContinue | Format-List *

    Write-Host ""
    Write-Host "Recent Application log events:"
    Get-WinEvent -LogName "Application" -MaxEvents 20 -ErrorAction SilentlyContinue |
        Where-Object { $_.ProviderName -eq "Alloy" -or $_.Message -match "Alloy" } |
        Select-Object TimeCreated, Id, ProviderName, LevelDisplayName, Message |
        Format-Table -Wrap -AutoSize

    Write-Host ""
    Write-Host "Recent System log events:"
    Get-WinEvent -LogName "System" -MaxEvents 20 -ErrorAction SilentlyContinue |
        Select-Object TimeCreated, Id, ProviderName, LevelDisplayName, Message |
        Format-Table -Wrap -AutoSize
}

Assert-Admin

$lokiPushUrl = "http://$LokiHost`:$LokiPort/loki/api/v1/push"
$lokiReadyUrl = "http://$LokiHost`:$LokiPort/ready"

$alloyBaseDir = "C:\ProgramData\GrafanaLabs\Alloy"
$alloyBookmarksDir = Join-Path $alloyBaseDir "bookmarks"
$alloyDataDir = Join-Path $alloyBaseDir "data"
$alloyConfigPath = Join-Path $alloyBaseDir "config.alloy"
$sysmonDir = "C:\sysmon"
$bookmarkPath = "C:\\ProgramData\\GrafanaLabs\\Alloy\\bookmarks\\sysmon.xml"

try {
    Write-Host ""
    Write-Host "Starting bootstrap install..."
    Write-Host ""

    Ensure-Directory "C:\Temp"
    Ensure-Directory "C:\Temp\alloy"
    Ensure-Directory $sysmonDir
    Ensure-Directory $alloyBaseDir
    Ensure-Directory $alloyBookmarksDir
    Ensure-Directory $alloyDataDir

    Install-OrUpdate-Sysmon -SysmonDir $sysmonDir -ConfigUrl $SysmonConfigUrl -InstallAttempts $SysmonInstallAttempts
    Write-AlloyConfig -ConfigPath $alloyConfigPath -LokiPushUrl $lokiPushUrl -BookmarkPath $bookmarkPath -Force:$ForceRewriteAlloyConfig
    Install-OrUpdate-Alloy -LiveConfigPath $alloyConfigPath -DataDir $alloyDataDir
    Test-HttpEndpoint -Url $lokiReadyUrl -RetryCount $HttpRetryCount -DelaySeconds $HttpRetryDelaySeconds -FriendlyName "Loki"
    Test-SysmonChannel

    Write-Host ""
    Write-Host "Bootstrap install completed."
    Write-Host "Live Alloy config : $alloyConfigPath"
    Write-Host "Alloy data dir    : $alloyDataDir"
    Write-Host "Alloy bookmarks   : $alloyBookmarksDir"
    Write-Host "Sysmon dir        : $sysmonDir"
    Write-Host ""
    Write-Host "Next test:"
    Write-Host "1. Open notepad.exe"
    Write-Host '2. Query Loki with: {job="windows",log="sysmon"}'
}
catch {
    Write-Error $_.Exception.Message
    Show-Diagnostics
    throw
}
