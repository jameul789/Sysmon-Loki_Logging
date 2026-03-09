# install-alloy.ps1
# Installs Grafana Alloy (Windows), deploys config.alloy from this repo, and restarts the Alloy service.
# Run in an elevated PowerShell. Intended to be fully unattended.

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Assert-Admin {
  $isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent() `
  ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

  if (-not $isAdmin) { throw "Run this script in an elevated PowerShell (Administrator)." }
}

Assert-Admin

# --- Resolve repo root and config path robustly ---
# (Works when run as a script file. Also works if someone copy/pastes, as long as they run it from the folder containing config.alloy.)
$root = if ($PSScriptRoot -and $PSScriptRoot.Trim()) { $PSScriptRoot } else { (Get-Location).Path }

$repoConfig = Join-Path $root "config.alloy"
if (-not (Test-Path $repoConfig)) {
  throw "Missing config file: $repoConfig (ensure config.alloy is in the same folder as this script)"
}

# --- Download Alloy installer ---
$dl = "C:\Temp\alloy"
New-Item -ItemType Directory -Force $dl | Out-Null

$installer = Join-Path $dl "alloy-installer-windows-amd64.exe"
$installerUrl = "https://github.com/grafana/alloy/releases/latest/download/alloy-installer-windows-amd64.exe"

Write-Host "Downloading Alloy installer..."
try {
  Invoke-WebRequest -Uri $installerUrl -OutFile $installer -UseBasicParsing
} catch {
  # BITS is often more reliable on flaky networks
  Start-BitsTransfer -Source $installerUrl -Destination $installer
}

# Guard against "HTML downloaded instead of EXE"
$installerSize = (Get-Item $installer).Length
if ($installerSize -lt 5MB) {
  throw "Downloaded installer looks too small ($installerSize bytes). Likely got HTML/redirect content instead of the installer."
}

# --- Install Alloy silently (unattended + wait) ---
Write-Host "Installing Alloy (silent)..."
Start-Process -FilePath $installer -ArgumentList "/S" -Wait -NoNewWindow

# Give Windows a moment to register files/service
Start-Sleep -Seconds 3

# --- Verify install succeeded ---
$installDir = "C:\Program Files\GrafanaLabs\Alloy"

$candidateBinaries = @(
  (Join-Path $installDir "alloy.exe"),
  (Join-Path $installDir "alloy-windows-amd64.exe")
)

$alloyExe = $candidateBinaries | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $alloyExe) {
  throw "Alloy executable not found. Checked: $($candidateBinaries -join ', ')"
}

# Ensure the Alloy service exists (installer should create it)
try {
  Get-Service -Name "Alloy" -ErrorAction Stop | Out-Null
} catch {
  throw "Alloy service not found after install. Installer may have failed."
}

Write-Host "Alloy installed successfully."

# --- Deploy config to ProgramData (stable location) ---
$destDir = "C:\ProgramData\GrafanaLabs\Alloy"
$bookmarkDir = Join-Path $destDir "bookmarks"
New-Item -ItemType Directory -Force $bookmarkDir | Out-Null

$destConfig = Join-Path $destDir "config.alloy"
Copy-Item -Force $repoConfig $destConfig

# --- Point the Alloy service at ProgramData config (avoids Program Files editing issues) ---
$svcKey = "HKLM:\SYSTEM\CurrentControlSet\Services\Alloy"
if (-not (Test-Path $svcKey)) {
  throw "Alloy service registry key not found. Is the service installed?"
}

# This makes the service run Alloy directly with your deployed config
Set-ItemProperty -Path $svcKey -Name ImagePath -Value "`"$alloyExe`" run `"$destConfig`""

# --- Restart Alloy service ---
Write-Host "Restarting Alloy service..."
Restart-Service -Name "Alloy" -Force

# --- Basic status output ---
Get-Service -Name "Alloy" | Format-Table Status, Name, DisplayName

Write-Host "Alloy installed and configured."
Write-Host "Config deployed to: $destConfig"
Write-Host "Bookmark directory: $bookmarkDir"
