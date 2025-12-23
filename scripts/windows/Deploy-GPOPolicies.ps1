#Requires -RunAsAdministrator
#Requires -Modules GroupPolicy, ActiveDirectory

<#
.SYNOPSIS
    Configures domain-wide Group Policy Objects for security baseline or vulnerability testing.

.DESCRIPTION
    Creates and configures GPOs for various security settings including Windows Defender,
    SMB signing, credential protection, and network protocols. Designed to be idempotent
    and support switching between security postures.

.PARAMETER ConfigFile
    Path to JSON configuration file.

.PARAMETER Profile
    Preset profile to use: secure, vulnerable, or mixed. Overrides SecurityPosture in config.

.PARAMETER Force
    Force recreation of existing GPOs (clean slate).

.EXAMPLE
    .\Deploy-GPOPolicies.ps1 -ConfigFile ".\gpo-config.json"
    .\Deploy-GPOPolicies.ps1 -ConfigFile ".\gpo-config.json" -GPOProfile secure
    .\Deploy-GPOPolicies.ps1 -GPOProfile vulnerable -Force

.NOTES
    - For DC-specific settings (SMB signing), this modifies the Default Domain Controller Policy
    - Defender changes may require service restart to take full effect
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigFile,

    [Parameter(Mandatory = $false)]
    [ValidateSet("secure", "vulnerable", "mixed")]
    [string]$GPOProfile,

    [Parameter(Mandatory = $false)]
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$DefaultConfig = @{
    SecurityPosture = "vulnerable"
    Policies        = @{
        WindowsDefender   = @{
            Enabled            = $false
            RealTimeProtection = $false
            SampleSubmission   = $false  # Always off by default - don't phone home during engagements
        }
        SMBSigning        = @{
            ClientRequired = $false
            ClientEnabled  = $false
            ServerRequired = $false
            ServerEnabled  = $false
        }
        LLMNR             = @{ Enabled = $true }
        NBTNS             = @{ Enabled = $true }
        WPAD              = @{ Enabled = $true }
        Firewall          = @{
            DomainProfile  = "Off"
            PrivateProfile = "Off"
            PublicProfile  = "Off"
        }
        RestrictedAdmin   = @{ Enabled = $false }
        LSAProtection     = @{ Enabled = $false }
        WDigest           = @{ Enabled = $true }
        PowerShellLogging = @{
            ModuleLogging      = $false
            ScriptBlockLogging = $false
            Transcription      = $false
        }
        UAC               = @{
            EnableLUA                  = $false
            ConsentPromptBehaviorAdmin = 0
        }
    }
}

function Write-Status {
    param(
        [string]$Message,
        [ValidateSet("INFO", "SUCCESS", "ERROR", "WARNING")]
        [string]$Status = "INFO"
    )
    $colors = @{ INFO = "Cyan"; SUCCESS = "Green"; ERROR = "Red"; WARNING = "Yellow" }
    Write-Host "[$Status] $Message" -ForegroundColor $colors[$Status]
}

function Get-MergedConfig {
    param($BaseConfig, $GPOProfile, $ConfigFile)

    # Start with defaults (as hashtable)
    $config = $BaseConfig

    # Load from file if provided
    if ($ConfigFile -and (Test-Path $ConfigFile)) {
        Write-Status "Loading configuration from: $ConfigFile"
        $jsonContent = Get-Content $ConfigFile -Raw | ConvertFrom-Json

        # Convert JSON to hashtable structure
        $config = @{
            SecurityPosture = $jsonContent.SecurityPosture
            Policies        = @{}
            PresetProfiles  = @{}
        }

        # Convert policies
        foreach ($prop in $jsonContent.Policies.PSObject.Properties) {
            $config.Policies[$prop.Name] = @{}
            foreach ($subProp in $prop.Value.PSObject.Properties) {
                if ($subProp.Name -ne "Description") {
                    $config.Policies[$prop.Name][$subProp.Name] = $subProp.Value
                }
            }
        }

        # Convert preset profiles
        if ($jsonContent.PresetProfiles) {
            foreach ($profile in $jsonContent.PresetProfiles.PSObject.Properties) {
                $config.PresetProfiles[$profile.Name] = @{
                    Description = $profile.Value.Description
                    Overrides   = @{}
                }
                if ($profile.Value.Overrides) {
                    foreach ($override in $profile.Value.Overrides.PSObject.Properties) {
                        $config.PresetProfiles[$profile.Name].Overrides[$override.Name] = $override.Value
                    }
                }
            }
        }
    }

    # Apply preset profile overrides
    if ($GPOProfile -and $config.PresetProfiles -and $config.PresetProfiles[$GPOProfile]) {
        Write-Status "Applying preset profile: $GPOProfile"
        $overrides = $config.PresetProfiles[$GPOProfile].Overrides

        foreach ($key in $overrides.Keys) {
            $parts = $key -split '\.'
            if ($parts.Count -eq 2) {
                $section = $parts[0]
                $setting = $parts[1]
                if ($config.Policies[$section]) {
                    $config.Policies[$section][$setting] = $overrides[$key]
                }
            }
        }
        $config.SecurityPosture = $GPOProfile
        Write-Status "Profile applied: $($config.PresetProfiles[$GPOProfile].Description)" "SUCCESS"
    }

    return $config
}

function Set-GPORegistryValue {
    param(
        [string]$GPOName,
        [string]$Key,
        [string]$ValueName,
        $Value,
        [string]$Type = "DWord"
    )

    try {
        Set-GPRegistryValue -Name $GPOName -Key $Key -ValueName $ValueName -Value $Value -Type $Type -ErrorAction Stop | Out-Null
        Write-Verbose "Set $Key\$ValueName = $Value"
    }
    catch {
        Write-Status "Failed to set ${Key}\${ValueName}: $_" "WARNING"
    }
}

function New-OrGetGPO {
    param(
        [string]$Name,
        [string]$Comment,
        [switch]$Force
    )

    $existingGPO = Get-GPO -Name $Name -ErrorAction SilentlyContinue

    if ($existingGPO -and $Force) {
        Write-Status "Removing existing GPO: $Name" "WARNING"
        Remove-GPO -Name $Name -Confirm:$false
        $existingGPO = $null
    }

    if (-not $existingGPO) {
        $gpo = New-GPO -Name $Name -Comment $Comment
        Write-Status "Created GPO: $Name" "SUCCESS"
        return $gpo
    }

    Write-Status "Using existing GPO: $Name" "INFO"
    return $existingGPO
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Domain Security Policy Deployment" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Cyan

$Config = Get-MergedConfig -BaseConfig $DefaultConfig -GPOProfile $GPOProfile -ConfigFile $ConfigFile
$domain = Get-ADDomain
$domainDN = $domain.DistinguishedName

Write-Status "Security Posture: $($Config.SecurityPosture.ToUpper())" "INFO"
Write-Status "Domain: $domainDN" "INFO"

# Create main GPO for domain-wide settings
$gpoName = "Lab Security Policy"
$gpo = New-OrGetGPO -Name $gpoName -Comment "Security lab baseline configuration - $($Config.SecurityPosture)" -Force:$Force

# Windows Defender
Write-Status "Configuring Windows Defender..." "INFO"
$defPath = "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender"

# DisableAntiSpyware: 1 = Disable Defender, 0 = Enable
Set-GPORegistryValue -GPOName $gpoName -Key $defPath -ValueName "DisableAntiSpyware" `
    -Value ([int](-not $Config.Policies.WindowsDefender.Enabled))

# Real-time protection
Set-GPORegistryValue -GPOName $gpoName -Key "$defPath\Real-Time Protection" -ValueName "DisableRealtimeMonitoring" `
    -Value ([int](-not $Config.Policies.WindowsDefender.RealTimeProtection))

# Sample submission: 0=Always prompt, 1=Send safe samples, 2=Never send, 3=Send all
# We use 2 (Never) when SampleSubmission is false
Set-GPORegistryValue -GPOName $gpoName -Key "$defPath\Spynet" -ValueName "SubmitSamplesConsent" `
    -Value $(if ($Config.Policies.WindowsDefender.SampleSubmission) { 1 } else { 2 })

# Also disable SpyNet reporting (cloud protection telemetry) when samples are off
Set-GPORegistryValue -GPOName $gpoName -Key "$defPath\Spynet" -ValueName "SpynetReporting" `
    -Value ([int]$Config.Policies.WindowsDefender.SampleSubmission)

# To fully re-enable Defender when switching to secure, we need to ensure the service can start
if ($Config.Policies.WindowsDefender.Enabled) {
    # Remove any "disable" policies that might be blocking it
    try {
        Remove-GPRegistryValue -Name $gpoName -Key $defPath -ValueName "DisableAntiVirus" -ErrorAction SilentlyContinue
        Remove-GPRegistryValue -Name $gpoName -Key $defPath -ValueName "DisableRoutinelyTakingAction" -ErrorAction SilentlyContinue
    } catch { }
}

# SMB Signing
Write-Status "Configuring SMB signing..." "INFO"
$smbClientPath = "HKLM\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters"
$smbServerPath = "HKLM\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters"

# GPO for domain workstations (non-DCs)
Set-GPORegistryValue -GPOName $gpoName -Key $smbClientPath -ValueName "RequireSecuritySignature" `
    -Value ([int]$Config.Policies.SMBSigning.ClientRequired)
Set-GPORegistryValue -GPOName $gpoName -Key $smbClientPath -ValueName "EnableSecuritySignature" `
    -Value ([int]$Config.Policies.SMBSigning.ClientEnabled)
Set-GPORegistryValue -GPOName $gpoName -Key $smbServerPath -ValueName "RequireSecuritySignature" `
    -Value ([int]$Config.Policies.SMBSigning.ServerRequired)
Set-GPORegistryValue -GPOName $gpoName -Key $smbServerPath -ValueName "EnableSecuritySignature" `
    -Value ([int]$Config.Policies.SMBSigning.ServerEnabled)

# For the local DC: GPO registry isn't enough - must use Set-SmbServerConfiguration
# This is because Windows Server 2025 DCs have security policy settings that override registry
if (Get-Service NTDS -ErrorAction SilentlyContinue) {
    Write-Status "Detected Domain Controller - applying SMB settings directly..." "INFO"
    try {
        Set-SmbClientConfiguration -EnableSecuritySignature ([bool]$Config.Policies.SMBSigning.ClientEnabled) `
            -RequireSecuritySignature ([bool]$Config.Policies.SMBSigning.ClientRequired) `
            -Confirm:$false
        Set-SmbServerConfiguration -EnableSecuritySignature ([bool]$Config.Policies.SMBSigning.ServerEnabled) `
            -RequireSecuritySignature ([bool]$Config.Policies.SMBSigning.ServerRequired) `
            -Confirm:$false
        Write-Status "DC SMB signing configured via cmdlet" "SUCCESS"
    }
    catch {
        Write-Status "Failed to configure DC SMB signing: $_" "ERROR"
    }
}

# LLMNR / NetBIOS / WPAD
Write-Status "Configuring name resolution protocols..." "INFO"

# So for vulnerable (LLMNR.Enabled = true), we want EnableMulticast = 1 or not set
# For secure (LLMNR.Enabled = false), we want EnableMulticast = 0
Set-GPORegistryValue -GPOName $gpoName -Key "HKLM\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient" `
    -ValueName "EnableMulticast" -Value ([int]$Config.Policies.LLMNR.Enabled)

# NetBIOS NodeType: 1=B-node(broadcast), 2=P-node(point-to-point), 4=M-node, 8=H-node
# To disable NetBIOS name resolution, we use NodeType 2 (P-node, no broadcasts)
# Note: Full NetBIOS disable is per-adapter via DHCP option or registry
$netbiosNodeType = if ($Config.Policies.NBTNS.Enabled) { 1 } else { 2 }
Set-GPORegistryValue -GPOName $gpoName -Key "HKLM\SYSTEM\CurrentControlSet\Services\NetBT\Parameters" `
    -ValueName "NodeType" -Value $netbiosNodeType

# WPAD: WpadOverride 1 = disable WPAD
Set-GPORegistryValue -GPOName $gpoName -Key "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Wpad" `
    -ValueName "WpadOverride" -Value ([int](-not $Config.Policies.WPAD.Enabled))

# Windows Firewall
Write-Status "Configuring Windows Firewall..." "INFO"
foreach ($profile in @("Domain", "Private", "Public")) {
    $fwPath = "HKLM\SOFTWARE\Policies\Microsoft\WindowsFirewall\${profile}Profile"
    $enabled = if ($Config.Policies.Firewall."${profile}Profile" -eq "On") { 1 } else { 0 }
    Set-GPORegistryValue -GPOName $gpoName -Key $fwPath -ValueName "EnableFirewall" -Value $enabled
}

# Credential Protection
Write-Status "Configuring credential protection settings..." "INFO"
$lsaPath = "HKLM\SYSTEM\CurrentControlSet\Control\Lsa"

# Restricted Admin Mode: DisableRestrictedAdmin 0 = enabled, 1 = disabled
Set-GPORegistryValue -GPOName $gpoName -Key $lsaPath -ValueName "DisableRestrictedAdmin" `
    -Value ([int](-not $Config.Policies.RestrictedAdmin.Enabled))

# LSA Protection (RunAsPPL): 1 = enabled
Set-GPORegistryValue -GPOName $gpoName -Key $lsaPath -ValueName "RunAsPPL" `
    -Value ([int]$Config.Policies.LSAProtection.Enabled)

# WDigest: UseLogonCredential 1 = cache plaintext credentials
Set-GPORegistryValue -GPOName $gpoName -Key "HKLM\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest" `
    -ValueName "UseLogonCredential" -Value ([int]$Config.Policies.WDigest.Enabled)

# PowerShell Logging (explicit enable/disable for idempotency)
Write-Status "Configuring PowerShell logging..." "INFO"
$psPath = "HKLM\SOFTWARE\Policies\Microsoft\Windows\PowerShell"

Set-GPORegistryValue -GPOName $gpoName -Key "$psPath\ModuleLogging" -ValueName "EnableModuleLogging" `
    -Value ([int]$Config.Policies.PowerShellLogging.ModuleLogging)

Set-GPORegistryValue -GPOName $gpoName -Key "$psPath\ScriptBlockLogging" -ValueName "EnableScriptBlockLogging" `
    -Value ([int]$Config.Policies.PowerShellLogging.ScriptBlockLogging)

Set-GPORegistryValue -GPOName $gpoName -Key "$psPath\Transcription" -ValueName "EnableTranscripting" `
    -Value ([int]$Config.Policies.PowerShellLogging.Transcription)

if ($Config.Policies.PowerShellLogging.Transcription) {
    Set-GPORegistryValue -GPOName $gpoName -Key "$psPath\Transcription" -ValueName "OutputDirectory" `
        -Value "C:\PSTranscripts" -Type String
}

# UAC
Write-Status "Configuring UAC..." "INFO"
$uacPath = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
Set-GPORegistryValue -GPOName $gpoName -Key $uacPath -ValueName "EnableLUA" `
    -Value ([int]$Config.Policies.UAC.EnableLUA)
Set-GPORegistryValue -GPOName $gpoName -Key $uacPath -ValueName "ConsentPromptBehaviorAdmin" `
    -Value $Config.Policies.UAC.ConsentPromptBehaviorAdmin

# Link GPO
Write-Status "Linking GPO to domain..." "INFO"
$existingLink = Get-GPInheritance -Target $domainDN |
    Select-Object -ExpandProperty GpoLinks |
    Where-Object { $_.DisplayName -eq $gpoName }

if (-not $existingLink) {
    New-GPLink -Name $gpoName -Target $domainDN -LinkEnabled Yes | Out-Null
    Write-Status "Linked GPO to $domainDN" "SUCCESS"
}
else {
    Write-Status "GPO already linked" "INFO"
}

# Force gpupdate
Write-Status "Forcing Group Policy update..." "INFO"
Invoke-Command -ScriptBlock { gpupdate /force } | Out-Null
Write-Status "Group Policy updated" "SUCCESS"

# Summary
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Deployment Complete" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan

$postureColor = switch ($Config.SecurityPosture) {
    "secure" { "Green" }
    "vulnerable" { "Red" }
    default { "Yellow" }
}
Write-Host "Security Posture: $($Config.SecurityPosture.ToUpper())" -ForegroundColor $postureColor

Write-Host "`nKey Settings:" -ForegroundColor White
Write-Host "  Defender:        $(if ($Config.Policies.WindowsDefender.Enabled) { 'Enabled' } else { 'DISABLED' })"
Write-Host "  Sample Submit:   $(if ($Config.Policies.WindowsDefender.SampleSubmission) { 'Enabled' } else { 'DISABLED' })"
Write-Host "  SMB Signing:     $(if ($Config.Policies.SMBSigning.ServerRequired) { 'Required' } else { 'NOT REQUIRED' })"
Write-Host "  LLMNR:           $(if ($Config.Policies.LLMNR.Enabled) { 'ENABLED (poisonable)' } else { 'Disabled' })"
Write-Host "  NBT-NS:          $(if ($Config.Policies.NBTNS.Enabled) { 'ENABLED (poisonable)' } else { 'Disabled' })"
Write-Host "  WDigest:         $(if ($Config.Policies.WDigest.Enabled) { 'ENABLED (plaintext creds)' } else { 'Disabled' })"
Write-Host "  LSA Protection:  $(if ($Config.Policies.LSAProtection.Enabled) { 'Enabled' } else { 'DISABLED' })"
Write-Host "  PS Logging:      $(if ($Config.Policies.PowerShellLogging.ScriptBlockLogging) { 'Enabled' } else { 'DISABLED' })"

Write-Host "`n[!] Notes:" -ForegroundColor Yellow
Write-Host "    - Clients need 'gpupdate /force' or reboot to apply"
Write-Host "    - DC SMB signing changes take effect immediately (no reboot needed)"
Write-Host "    - Defender state changes may require service restart"
