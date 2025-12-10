#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Initializes Windows Server 2025 Core for Domain Controller role.

.DESCRIPTION
    Configures base system settings including hostname, static IP, DNS,
    timezone, and Windows features required for AD DS deployment.

.PARAMETER ConfigFile
    Path to JSON configuration file. If not provided, uses inline defaults.

.EXAMPLE
    .\Initialize-DCHost.ps1 -ConfigFile ".\dc-config.json"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$ConfigFile
)

# Default configuration
$DefaultConfig = @{
    Hostname = "DC01"
    Network = @{
        InterfaceAlias = "Ethernet0"
        IPAddress = "10.13.37.3"
        PrefixLength = 24
        DefaultGateway = "10.13.37.2"
        DNSServers = @("127.0.0.1", "10.13.37.2", "8.8.8.8")  # Loopback first, Gateway second, fallback third
    }
    TimeZone = "Central Standard Time"
    DisableIPv6 = $true
    EnableRDP = $false
    WindowsFeatures = @(
        "AD-Domain-Services",
        "DNS",
        "RSAT-AD-Tools",
        "RSAT-DNS-Server",
        "GPMC"
    )
}

# Load config from file if provided, otherwise use defaults
if ($ConfigFile -and (Test-Path $ConfigFile)) {
    Write-Host "[*] Loading configuration from: $ConfigFile" -ForegroundColor Cyan
    $Config = Get-Content $ConfigFile | ConvertFrom-Json -AsHashtable
} else {
    Write-Host "[*] Using default configuration" -ForegroundColor Yellow
    $Config = $DefaultConfig
}

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $color = switch($Status) {
        "INFO" { "Cyan" }
        "SUCCESS" { "Green" }
        "ERROR" { "Red" }
        "WARNING" { "Yellow" }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $color
}

# Set hostname
try {
    Write-Status "Setting hostname to: $($Config.Hostname)"
    if ($env:COMPUTERNAME -ne $Config.Hostname) {
        Rename-Computer -NewName $Config.Hostname -Force -ErrorAction Stop
        $requiresReboot = $true
        Write-Status "Hostname changed (reboot required)" "SUCCESS"
    } else {
        Write-Status "Hostname already set correctly" "SUCCESS"
    }
} catch {
    Write-Status "Failed to set hostname: $_" "ERROR"
    exit 1
}

# Configure network adapter
try {
    Write-Status "Configuring network interface: $($Config.Network.InterfaceAlias)"

    # Get the network adapter
    $adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1
    if (-not $adapter) {
        throw "No active network adapter found"
    }

    $actualAlias = $adapter.Name
    Write-Status "Using adapter: $actualAlias"

    # Remove existing IP configuration
    Remove-NetIPAddress -InterfaceAlias $actualAlias -Confirm:$false -ErrorAction SilentlyContinue
    Remove-NetRoute -InterfaceAlias $actualAlias -Confirm:$false -ErrorAction SilentlyContinue

    # Set static IP
    New-NetIPAddress -InterfaceAlias $actualAlias `
        -IPAddress $Config.Network.IPAddress `
        -PrefixLength $Config.Network.PrefixLength `
        -DefaultGateway $Config.Network.DefaultGateway `
        -ErrorAction Stop | Out-Null

    # Set DNS servers
    Set-DnsClientServerAddress -InterfaceAlias $actualAlias `
        -ServerAddresses $Config.Network.DNSServers `
        -ErrorAction Stop

    # Disable IPv6 if configured
    if ($Config.DisableIPv6) {
        Disable-NetAdapterBinding -Name $actualAlias -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
        Write-Status "IPv6 disabled" "SUCCESS"
    }

    Write-Status "Network configuration applied" "SUCCESS"
    Write-Status "  IP: $($Config.Network.IPAddress)/$($Config.Network.PrefixLength)" "INFO"
    Write-Status "  GW: $($Config.Network.DefaultGateway)" "INFO"
    Write-Status "  DNS: $($Config.Network.DNSServers -join ', ')" "INFO"

} catch {
    Write-Status "Network configuration failed: $_" "ERROR"
    exit 1
}

# Set timezone
try {
    Write-Status "Setting timezone to: $($Config.TimeZone)"
    Set-TimeZone -Name $Config.TimeZone -ErrorAction Stop
    Write-Status "Timezone configured" "SUCCESS"
} catch {
    Write-Status "Failed to set timezone: $_" "WARNING"
}

# Enable RDP if configured
if ($Config.EnableRDP) {
    try {
        Write-Status "Enabling Remote Desktop"
        Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' `
            -Name "fDenyTSConnections" -Value 0 -ErrorAction Stop
        Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction Stop
        Write-Status "RDP enabled" "SUCCESS"
    } catch {
        Write-Status "Failed to enable RDP: $_" "WARNING"
    }
}

# Install Windows Features
try {
    Write-Status "Installing Windows Features (this may take several minutes)..."
    foreach ($feature in $Config.WindowsFeatures) {
        Write-Status "Installing: $feature" "INFO"
    }

    $installResult = Install-WindowsFeature -Name $Config.WindowsFeatures `
        -IncludeManagementTools `
        -ErrorAction Stop

    if ($installResult.Success) {
        Write-Status "All features installed successfully" "SUCCESS"
        if ($installResult.RestartNeeded -eq "Yes") {
            $requiresReboot = $true
            Write-Status "Feature installation requires reboot" "WARNING"
        }
    } else {
        throw "Feature installation reported failure"
    }
} catch {
    Write-Status "Feature installation failed: $_" "ERROR"
    exit 1
}

# Configure Windows Firewall (allow ICMP for network testing)
try {
    Write-Status "Configuring Windows Firewall"
    netsh advfirewall firewall add rule name="ICMP Allow incoming V4 echo request" `
        protocol=icmpv4:8,any dir=in action=allow | Out-Null
    Write-Status "Firewall rules configured" "SUCCESS"
} catch {
    Write-Status "Firewall configuration warning: $_" "WARNING"
}

# Summary
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Host Initialization Complete" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Hostname: $($Config.Hostname)"
Write-Host "IP Address: $($Config.Network.IPAddress)"
Write-Host "Status: Ready for AD DS deployment"

if ($requiresReboot) {
    Write-Host "`n[!] REBOOT REQUIRED" -ForegroundColor Yellow
    Write-Host "Run this command after reboot:" -ForegroundColor Yellow
    Write-Host "  .\Deploy-ADForest.ps1" -ForegroundColor White

    $reboot = Read-Host "`nReboot now? (Y/N)"
    if ($reboot -eq "Y" -or $reboot -eq "y") {
        Write-Status "Rebooting in 10 seconds..." "WARNING"
        Start-Sleep -Seconds 10
        Restart-Computer -Force
    }
} else {
    Write-Host "`nNext step: .\Deploy-ADForest.ps1" -ForegroundColor Cyan
}