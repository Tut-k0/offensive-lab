#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Deploys Active Directory Domain Services and creates a new forest.

.DESCRIPTION
    Promotes the server to a Domain Controller, creates a new AD forest and domain,
    and configures DNS services. Requires Initialize-DCHost.ps1 to be run first.

.PARAMETER ConfigFile
    Path to JSON configuration file. If not provided, uses inline defaults.

.EXAMPLE
    .\Deploy-ADForest.ps1 -ConfigFile ".\ad-config.json"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$ConfigFile
)

# Load config from file if provided
if ($ConfigFile -and (Test-Path $ConfigFile)) {
    Write-Host "[*] Loading configuration from: $ConfigFile" -ForegroundColor Cyan
    $Config = Get-Content $ConfigFile | ConvertFrom-Json
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

function New-RandomPassword {
    <#
    .SYNOPSIS
        Generates a random password.

    .PARAMETER Length
        Length of the password to generate
    #>
    param(
        [int]$Length = 32
    )

    # Character sets for password complexity
    $uppercase = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
    $lowercase = 'abcdefghijklmnopqrstuvwxyz'
    $numbers = '0123456789'
    $special = '!@#$%^&*()_+-=[]{}|;:,.<>?'

    # Combine all character sets
    $allChars = $uppercase + $lowercase + $numbers + $special

    # Ensure at least one character from each set
    $password = @(
        $uppercase[(Get-Random -Maximum $uppercase.Length)]
        $lowercase[(Get-Random -Maximum $lowercase.Length)]
        $numbers[(Get-Random -Maximum $numbers.Length)]
        $special[(Get-Random -Maximum $special.Length)]
    )

    # Fill remaining length with random characters from all sets
    for ($i = $password.Count; $i -lt $Length; $i++) {
        $password += $allChars[(Get-Random -Maximum $allChars.Length)]
    }

    # Shuffle the password to avoid predictable patterns
    $shuffled = $password | Sort-Object { Get-Random }

    return -join $shuffled
}

# Generate DSRM password if not provided
if (-not $Config.SafeModePassword -or $Config.SafeModePassword -eq $null -or $Config.SafeModePassword -eq "") {
    Write-Status "DSRM password not provided - generating secure password..." "WARNING"
    $Config.SafeModePassword = New-RandomPassword -Length 32
    $generatedPassword = $true
} else {
    $generatedPassword = $false
}

# Pre-flight checks
Write-Status "Running pre-flight checks..." "INFO"

# Check if AD DS role is installed
$addsInstalled = (Get-WindowsFeature AD-Domain-Services).Installed
if (-not $addsInstalled) {
    Write-Status "AD-Domain-Services role not found. Run Initialize-DCHost.ps1 first." "ERROR"
    exit 1
}

# Check if already a domain controller
$isDC = (Get-WmiObject -Class Win32_ComputerSystem).DomainRole -ge 4
if ($isDC) {
    Write-Status "This server is already a Domain Controller" "ERROR"
    exit 1
}

# Verify network configuration
$netConfig = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike "169.254.*" -and $_.IPAddress -ne "127.0.0.1" }
if (-not $netConfig) {
    Write-Status "No valid IP configuration found" "ERROR"
    exit 1
}

Write-Status "Pre-flight checks passed" "SUCCESS"
Write-Host ""

# Display configuration summary
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  AD Forest Deployment Configuration" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Domain Name: $($Config.DomainName)"
Write-Host "NetBIOS Name: $($Config.DomainNetBIOSName)"
Write-Host "Forest Functional Level: $($Config.ForestMode)"
Write-Host "Domain Functional Level: $($Config.DomainMode)"
Write-Host "Install DNS: $($Config.InstallDNS)"
if ($Config.InstallDNS -and $Config.CreateDNSForwarder) {
    Write-Host "DNS Forwarders: $($Config.DNSForwarders -join ', ')"
}
if ($generatedPassword) {
    Write-Host "DSRM Password: (auto-generated)"
} else {
    Write-Host "DSRM Password: (user-provided)"
}
Write-Host ""

# Convert SafeMode password to SecureString
$securePassword = ConvertTo-SecureString $Config.SafeModePassword -AsPlainText -Force

# Prepare parameters for Install-ADDSForest
$forestParams = @{
    DomainName = $Config.DomainName
    DomainNetbiosName = $Config.DomainNetBIOSName
    ForestMode = $Config.ForestMode
    DomainMode = $Config.DomainMode
    InstallDns = $Config.InstallDNS
    SafeModeAdministratorPassword = $securePassword
    DatabasePath = $Config.DatabasePath
    LogPath = $Config.LogPath
    SysvolPath = $Config.SysvolPath
    Force = $true
    NoRebootOnCompletion = $true
}

# Deploy the forest
try {
    Write-Status "Starting AD DS forest deployment..." "INFO"
    Write-Status "This will take several minutes. Do not interrupt." "WARNING"
    Write-Host ""

    Install-ADDSForest @forestParams -ErrorAction Stop

    Write-Status "AD DS forest deployment completed successfully" "SUCCESS"

} catch {
    Write-Status "Forest deployment failed: $_" "ERROR"
    Write-Status "Check the logs at: C:\Windows\Debug\dcpromo.log" "INFO"
    exit 1
}

# Configure DNS Forwarders if requested
if ($Config.InstallDNS -and $Config.CreateDNSForwarder) {
    try {
        Write-Status "Configuring DNS forwarders..." "INFO"
        Start-Sleep -Seconds 5  # Brief pause for DNS service

        # Clear any existing forwarders first
        Set-DnsServerForwarder -IPAddress $Config.DNSForwarders -ErrorAction Stop

        Write-Status "DNS forwarders configured" "SUCCESS"
    } catch {
        Write-Status "DNS forwarder configuration failed: $_" "WARNING"
        Write-Status "You may need to configure this manually after reboot" "INFO"
    }
}

# Post-deployment summary
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  AD Forest Deployment Complete" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Domain: $($Config.DomainName)"
Write-Host "NetBIOS: $($Config.DomainNetBIOSName)"
if ($generatedPassword) {
    Write-Host ""
    Write-Host "[!] DISPLAYING AUTOGENERATED DSRM PASSWORD (save this if you wish to use it)" -ForegroundColor Red
    Write-Host "DSRM Password: " -NoNewline -ForegroundColor Yellow
    Write-Host "$($Config.SafeModePassword)" -ForegroundColor Red
    Write-Host ""
    Write-Host "What is DSRM?" -ForegroundColor Cyan
    Write-Host "  - Directory Services Restore Mode is a special boot mode for DC recovery" -ForegroundColor Gray
    Write-Host "  - Used for offline AD database maintenance and restoration" -ForegroundColor Gray
    Write-Host "  - This is a LOCAL administrator password (separate from domain admin)" -ForegroundColor Gray
    Write-Host "  - Boot into DSRM: Restart and press F8, select 'Directory Services Restore Mode'" -ForegroundColor Gray
}
Write-Host ""
Write-Host "[!] REBOOT REQUIRED" -ForegroundColor Yellow
Write-Host "After reboot, log in as: $($Config.DomainNetBIOSName)\Administrator" -ForegroundColor Yellow
Write-Host "Then run: .\Populate-ADEnvironment.ps1" -ForegroundColor Cyan
Write-Host ""

Write-Status "Rebooting in 20 seconds..." "WARNING"
Start-Sleep -Seconds 20
Restart-Computer -Force
