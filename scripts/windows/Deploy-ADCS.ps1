#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Deploys Active Directory Certificate Services (AD CS) Enterprise Root CA.

.DESCRIPTION
    Installs and configures an Enterprise Root Certificate Authority integrated with
    Active Directory. This should be run after AD forest deployment.

    The script automatically:
    - Detects server FQDN and domain information
    - Installs ADCS-Cert-Authority role if needed
    - Installs IIS if needed (for HTTP CRL distribution)
    - Configures CDP/AIA paths automatically
    - Sets up CertEnroll virtual directory

    Features:
    - Enterprise Root CA deployment
    - Configurable validity periods and key sizes
    - Automatic AIA and CDP configuration
    - CRL publishing settings
    - Audit policy configuration
    - Certificate template management

.PARAMETER ConfigFile
    Path to JSON configuration file. If not provided, uses inline defaults.

.EXAMPLE
    .\Deploy-ADCS.ps1 -ConfigFile ".\adcs-config.json"

.EXAMPLE
    .\Deploy-ADCS.ps1
    # Uses all defaults with auto-detected values

.NOTES
    Prerequisites:
    - Server must be a domain controller or domain-joined
    - Must run as Domain Admin
    - AD DS must be fully deployed
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$ConfigFile
)

# Default configuration - minimal settings, everything else auto-detected
$DefaultConfig = @{
    CAType = "EnterpriseRootCA"  # Options: EnterpriseRootCA, EnterpriseSubordinateCA, StandaloneRootCA, StandaloneSubordinateCA
    CACommonName = $null  # Auto-generated from domain if null (e.g., REDTEAM-CA)
    ValidityPeriod = "Years"
    ValidityPeriodUnits = 10
    CryptoProviderName = "RSA#Microsoft Software Key Storage Provider"
    KeyLength = 4096
    HashAlgorithmName = "SHA256"
    DatabaseDirectory = "C:\Windows\System32\CertLog"
    LogDirectory = "C:\Windows\System32\CertLog"
    OverwriteExistingKey = $false
    OverwriteExistingDatabase = $false
    OverwriteExistingCAInDS = $false
    EnableAIA = $true
    EnableCDP = $true
    CRLPublishInterval = "1"
    CRLPublishIntervalUnits = "Days"
    DeltaCRLPublishInterval = "1"
    DeltaCRLPublishIntervalUnits = "Hours"
    CRLOverlapPeriod = "0"
    CRLOverlapUnits = "Hours"
    AuditFilter = "All"  # Options: None, StartAndStop, BackupAndRestore, IssueAndManage, RevokeCertificatesAndPublishCRLs, All
    InstallIIS = $true  # Install IIS if not already installed
}

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

# Pre-flight checks
Write-Status "Running pre-flight checks..." "INFO"

# Check if running in domain
try {
    $domain = Get-ADDomain -ErrorAction Stop
    Write-Status "Domain detected: $($domain.DNSRoot)" "SUCCESS"
} catch {
    Write-Status "Not running in an AD domain. AD CS requires domain membership." "ERROR"
    exit 1
}

# Get server information
$serverFQDN = [System.Net.Dns]::GetHostByName($env:COMPUTERNAME).HostName
Write-Status "Server FQDN: $serverFQDN" "INFO"

# Auto-generate CA name if not provided
if (-not $Config.CACommonName -or $Config.CACommonName -eq $null -or $Config.CACommonName -eq "") {
    $Config.CACommonName = "$($domain.NetBIOSName)-CA"
    Write-Status "Auto-generated CA name: $($Config.CACommonName)" "INFO"
}

# Auto-generate Distinguished Name Suffix from domain
$domainDN = $domain.DistinguishedName
Write-Status "CA DN Suffix: $domainDN" "INFO"

# Build proper CDP and AIA paths
# Note: <Tokens> like <CaName>, <CRLNameSuffix> etc are special variables that Windows CA replaces at runtime
# We only replace <ServerDNSName> with the actual FQDN for HTTP paths
$cdpPath = "http://$serverFQDN/CertEnroll/<CaName><CRLNameSuffix><DeltaCRLAllowed>.crl"
$aiaPath = "http://$serverFQDN/CertEnroll/<CaName><CertificateName>.crt"

Write-Status "CDP Path: $cdpPath" "INFO"
Write-Status "AIA Path: $aiaPath" "INFO"

# Check if AD CS role is already installed
$adcsInstalled = (Get-WindowsFeature -Name ADCS-Cert-Authority).Installed
if ($adcsInstalled) {
    # Check if already configured
    try {
        $existingCA = Get-CACrlDistributionPoint -ErrorAction SilentlyContinue
        if ($existingCA) {
            Write-Status "AD CS appears to be already configured on this server" "ERROR"
            Write-Host "Existing CA detected. If you want to reconfigure, you must first remove the existing CA:" -ForegroundColor Yellow
            Write-Host "  1. Uninstall-AdcsCertificationAuthority -Force" -ForegroundColor White
            Write-Host "  2. Uninstall-WindowsFeature ADCS-Cert-Authority" -ForegroundColor White
            exit 1
        }
    } catch {
        # Role installed but not configured, proceed
        Write-Status "AD CS role installed but not configured, proceeding..." "INFO"
    }
}

# Verify we're running as administrator
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object System.Security.Principal.WindowsPrincipal($currentUser)
$adminRole = [System.Security.Principal.WindowsBuiltInRole]::Administrator

if (-not $principal.IsInRole($adminRole)) {
    Write-Status "This script must be run as Administrator" "ERROR"
    exit 1
}

# Check domain functional level
if ($domain.DomainMode -lt "Windows2012R2Domain") {
    Write-Status "Domain functional level is below Windows Server 2012 R2" "WARNING"
    Write-Status "AD CS will work but some features may be limited" "WARNING"
}

Write-Status "Pre-flight checks passed" "SUCCESS"
Write-Host ""

# Install IIS if needed and configured
if ($Config.InstallIIS) {
    $iisInstalled = (Get-WindowsFeature -Name Web-Server).Installed
    if (-not $iisInstalled) {
        try {
            Write-Status "Installing IIS for CRL distribution..." "INFO"
            $iisFeatures = @(
                "Web-Server",
                "Web-Mgmt-Console",
                "Web-Dir-Browsing"
            )

            $iisResult = Install-WindowsFeature -Name $iisFeatures -IncludeManagementTools -ErrorAction Stop

            if ($iisResult.Success) {
                Write-Status "IIS installed successfully" "SUCCESS"
            } else {
                throw "IIS installation reported failure"
            }
        } catch {
            Write-Status "Failed to install IIS: $_" "WARNING"
            Write-Status "CRL distribution via HTTP will not be available" "WARNING"
            $Config.InstallIIS = $false
        }
    } else {
        Write-Status "IIS already installed" "INFO"
    }
}

# Install AD CS role if not already installed
if (-not $adcsInstalled) {
    try {
        Write-Status "Installing AD CS Certification Authority role..." "INFO"
        Write-Status "This may take several minutes..." "WARNING"

        $installResult = Install-WindowsFeature -Name ADCS-Cert-Authority `
            -IncludeManagementTools `
            -ErrorAction Stop

        if ($installResult.Success) {
            Write-Status "AD CS role installed successfully" "SUCCESS"
            if ($installResult.RestartNeeded -eq "Yes") {
                Write-Status "Role installation requires reboot" "ERROR"
                Write-Host "[!] A reboot is required. Please reboot and run this script again." -ForegroundColor Yellow
                Write-Host "After reboot, simply run: .\Deploy-ADCS.ps1" -ForegroundColor Cyan
                exit 0
            }
        } else {
            throw "Role installation reported failure"
        }
    } catch {
        Write-Status "Failed to install AD CS role: $_" "ERROR"
        exit 1
    }
} else {
    Write-Status "AD CS role already installed" "INFO"
}

# Display configuration summary
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  AD CS Deployment Configuration" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Server FQDN: $serverFQDN"
Write-Host "Domain: $($domain.DNSRoot)"
Write-Host "CA Type: $($Config.CAType)"
Write-Host "CA Common Name: $($Config.CACommonName)"
Write-Host "CA DN Suffix: $domainDN"
Write-Host "Validity Period: $($Config.ValidityPeriodUnits) $($Config.ValidityPeriod)"
Write-Host "Key Length: $($Config.KeyLength) bits"
Write-Host "Hash Algorithm: $($Config.HashAlgorithmName)"
Write-Host "Database Path: $($Config.DatabaseDirectory)"
Write-Host "Log Path: $($Config.LogDirectory)"
Write-Host "IIS Installed: $($Config.InstallIIS)"
Write-Host ""

# Prepare parameters for Install-AdcsCertificationAuthority
$caParams = @{
    CAType = $Config.CAType
    CACommonName = $Config.CACommonName
    CADistinguishedNameSuffix = $domainDN
    ValidityPeriod = $Config.ValidityPeriod
    ValidityPeriodUnits = $Config.ValidityPeriodUnits
    CryptoProviderName = $Config.CryptoProviderName
    KeyLength = $Config.KeyLength
    HashAlgorithmName = $Config.HashAlgorithmName
    DatabaseDirectory = $Config.DatabaseDirectory
    LogDirectory = $Config.LogDirectory
    OverwriteExistingKey = $Config.OverwriteExistingKey
    OverwriteExistingDatabase = $Config.OverwriteExistingDatabase
    Force = $true
}

# Add OverwriteExistingCAInDS only for Enterprise CAs
if ($Config.CAType -like "Enterprise*") {
    $caParams.Add("OverwriteExistingCAInDS", $Config.OverwriteExistingCAInDS)
}

# Configure and install the CA
try {
    Write-Status "Configuring Certificate Authority..." "INFO"
    Write-Status "This will take several minutes. Do not interrupt." "WARNING"
    Write-Host ""

    Install-AdcsCertificationAuthority @caParams -ErrorAction Stop

    Write-Status "Certificate Authority configured successfully" "SUCCESS"

} catch {
    Write-Status "CA configuration failed: $_" "ERROR"
    Write-Status "Check Event Viewer > Application and Services > Microsoft > Windows > CertificationAuthority" "INFO"
    exit 1
}

# Wait for CA service to start
Write-Status "Waiting for Certificate Services to start..." "INFO"
Start-Sleep -Seconds 10

# Verify CA is running
try {
    $caService = Get-Service -Name CertSvc -ErrorAction Stop
    if ($caService.Status -ne "Running") {
        Start-Service -Name CertSvc -ErrorAction Stop
        Start-Sleep -Seconds 5
    }
    Write-Status "Certificate Services is running" "SUCCESS"
} catch {
    Write-Status "Failed to verify Certificate Services status: $_" "WARNING"
}

# Configure CRL Distribution Points (CDP)
if ($Config.EnableCDP) {
    try {
        Write-Status "Configuring CRL Distribution Points..." "INFO"

        # Remove default CDP entries
        $cdps = Get-CACrlDistributionPoint
        foreach ($cdp in $cdps) {
            Remove-CACrlDistributionPoint -Uri $cdp.Uri -Force -ErrorAction SilentlyContinue
        }

        # Add file system CDP (always needed)
        # Note: Tokens like <CaName> are dynamically replaced by the CA service at runtime
        Add-CACRLDistributionPoint -Uri "C:\Windows\System32\CertSrv\CertEnroll\<CaName><CRLNameSuffix><DeltaCRLAllowed>.crl" `
            -PublishToServer -PublishDeltaToServer -Force -ErrorAction SilentlyContinue

        # Add LDAP CDP for domain (tokens are replaced by CA service at runtime)
        Add-CACRLDistributionPoint -Uri "ldap:///CN=<CATruncatedName><CRLNameSuffix>,CN=<ServerShortName>,CN=CDP,CN=Public Key Services,CN=Services,<ConfigurationContainer><CDPObjectClass>" `
            -AddToCertificateCdp -Force -ErrorAction SilentlyContinue

        # Add HTTP CDP if IIS is installed (FQDN is real, other tokens replaced at runtime)
        if ($Config.InstallIIS) {
            Add-CACRLDistributionPoint -Uri $cdpPath -AddToCertificateCdp -AddToFreshestCrl -Force -ErrorAction Stop
        }

        Write-Status "CDP configured" "SUCCESS"
    } catch {
        Write-Status "Failed to configure CDP: $_" "WARNING"
    }
}

# Configure Authority Information Access (AIA)
if ($Config.EnableAIA) {
    try {
        Write-Status "Configuring Authority Information Access..." "INFO"

        # Remove default AIA entries
        $aias = Get-CAAuthorityInformationAccess
        foreach ($aia in $aias) {
            Remove-CAAuthorityInformationAccess -Uri $aia.Uri -Force -ErrorAction SilentlyContinue
        }

        # Add LDAP AIA for domain (tokens are replaced by CA service at runtime)
        Add-CAAuthorityInformationAccess -Uri "ldap:///CN=<CATruncatedName>,CN=AIA,CN=Public Key Services,CN=Services,<ConfigurationContainer><CAObjectClass>" `
            -AddToCertificateAia -Force -ErrorAction SilentlyContinue

        # Add HTTP AIA if IIS is installed (FQDN is real, other tokens replaced at runtime)
        if ($Config.InstallIIS) {
            Add-CAAuthorityInformationAccess -Uri $aiaPath -AddToCertificateAia -Force -ErrorAction Stop
        }

        Write-Status "AIA configured" "SUCCESS"
    } catch {
        Write-Status "Failed to configure AIA: $_" "WARNING"
    }
}

# Configure CRL publication settings
try {
    Write-Status "Configuring CRL publication settings..." "INFO"

    # Set CRL period (suppress verbose output)
    certutil -setreg CA\CRLPeriod $Config.CRLPublishIntervalUnits 2>&1 | Out-Null
    certutil -setreg CA\CRLPeriodUnits $Config.CRLPublishInterval 2>&1 | Out-Null

    # Set Delta CRL period
    certutil -setreg CA\CRLDeltaPeriod $Config.DeltaCRLPublishIntervalUnits 2>&1 | Out-Null
    certutil -setreg CA\CRLDeltaPeriodUnits $Config.DeltaCRLPublishInterval 2>&1 | Out-Null

    # Set CRL overlap period
    certutil -setreg CA\CRLOverlapPeriod $Config.CRLOverlapUnits 2>&1 | Out-Null
    certutil -setreg CA\CRLOverlapUnits $Config.CRLOverlapPeriod 2>&1 | Out-Null

    Write-Status "CRL publication settings configured" "SUCCESS"
} catch {
    Write-Status "Failed to configure CRL settings: $_" "WARNING"
}

# Configure auditing
try {
    Write-Status "Configuring CA auditing..." "INFO"

    $auditValue = switch ($Config.AuditFilter) {
        "None" { 0 }
        "StartAndStop" { 1 }
        "BackupAndRestore" { 2 }
        "IssueAndManage" { 4 }
        "RevokeCertificatesAndPublishCRLs" { 8 }
        "All" { 127 }
        default { 127 }
    }

    certutil -setreg CA\AuditFilter $auditValue 2>&1 | Out-Null
    Write-Status "CA auditing configured ($($Config.AuditFilter))" "SUCCESS"
} catch {
    Write-Status "Failed to configure auditing: $_" "WARNING"
}

# Restart Certificate Services to apply all changes
try {
    Write-Status "Restarting Certificate Services to apply configuration..." "INFO"
    Restart-Service -Name CertSvc -Force -ErrorAction Stop
    Start-Sleep -Seconds 5
    Write-Status "Certificate Services restarted" "SUCCESS"
} catch {
    Write-Status "Failed to restart Certificate Services: $_" "WARNING"
    Write-Status "You may need to manually restart the service" "INFO"
}

# Publish initial CRL
try {
    Write-Status "Publishing initial Certificate Revocation List..." "INFO"
    certutil -CRL | Out-Null
    Write-Status "Initial CRL published" "SUCCESS"
} catch {
    Write-Status "Failed to publish initial CRL: $_" "WARNING"
}

# Configure certificate templates (Enterprise CA only)
if ($Config.CAType -like "Enterprise*") {
    try {
        Write-Status "Configuring certificate templates..." "INFO"

        # Get default templates
        $templates = @(
            "User"
            "Computer"
            "WebServer"
            "DomainController"
            "KerberosAuthentication"
            "SmartcardLogon"
            "CodeSigning"
        )

        foreach ($template in $templates) {
            try {
                certutil -SetCAtemplates "+$template" -ErrorAction SilentlyContinue | Out-Null
            } catch {
                # Template may not exist, continue
            }
        }

        Write-Status "Certificate templates configured" "SUCCESS"
    } catch {
        Write-Status "Failed to configure certificate templates: $_" "WARNING"
    }
}

# Create CertEnroll virtual directory for HTTP distribution (if IIS is available)
if ($Config.InstallIIS) {
    try {
        Write-Status "Configuring CertEnroll virtual directory..." "INFO"

        $iisInstalled = (Get-WindowsFeature -Name Web-Server).Installed

        if ($iisInstalled) {
            $certEnrollPath = "C:\Windows\System32\CertSrv\CertEnroll"

            # Import IIS module
            Import-Module WebAdministration -ErrorAction Stop

            # Check if virtual directory already exists
            $vdirExists = Get-WebVirtualDirectory -Site "Default Web Site" -Name "CertEnroll" -ErrorAction SilentlyContinue

            if (-not $vdirExists) {
                # Create virtual directory
                New-WebVirtualDirectory -Site "Default Web Site" -Name "CertEnroll" -PhysicalPath $certEnrollPath -ErrorAction Stop

                # Enable directory browsing
                Set-WebConfigurationProperty -Filter /system.webServer/directoryBrowse -Name enabled -Value true -PSPath "IIS:\Sites\Default Web Site\CertEnroll" -ErrorAction SilentlyContinue

                # Set MIME types for certificate files (check if they exist first)
                try {
                    $existingMimeTypes = Get-WebConfigurationProperty -PSPath "IIS:\Sites\Default Web Site\CertEnroll" -Filter "system.webServer/staticContent" -Name "collection"

                    $hasCrt = $existingMimeTypes | Where-Object { $_.fileExtension -eq '.crt' }
                    $hasCrl = $existingMimeTypes | Where-Object { $_.fileExtension -eq '.crl' }

                    if (-not $hasCrt) {
                        Add-WebConfigurationProperty -PSPath "IIS:\Sites\Default Web Site\CertEnroll" -Filter "system.webServer/staticContent" -Name "." -Value @{fileExtension='.crt'; mimeType='application/pkix-cert'} -ErrorAction SilentlyContinue
                    }
                    if (-not $hasCrl) {
                        Add-WebConfigurationProperty -PSPath "IIS:\Sites\Default Web Site\CertEnroll" -Filter "system.webServer/staticContent" -Name "." -Value @{fileExtension='.crl'; mimeType='application/pkix-crl'} -ErrorAction SilentlyContinue
                    }
                } catch {
                    # MIME types may already exist, ignore
                }

                Write-Status "CertEnroll virtual directory created" "SUCCESS"
                Write-Status "CRL distribution available at: http://$serverFQDN/CertEnroll/" "INFO"
            } else {
                Write-Status "CertEnroll virtual directory already exists" "INFO"
            }
        }
    } catch {
        Write-Status "Failed to configure CertEnroll virtual directory: $_" "WARNING"
        Write-Status "This is optional but recommended for enterprise deployments" "INFO"
    }
}

# Get CA certificate information
try {
    $caCert = Get-ChildItem Cert:\LocalMachine\CA | Select-Object -First 1
    $caInfo = @{
        Subject = $caCert.Subject
        Issuer = $caCert.Issuer
        Thumbprint = $caCert.Thumbprint
        NotBefore = $caCert.NotBefore
        NotAfter = $caCert.NotAfter
        SerialNumber = $caCert.SerialNumber
    }
} catch {
    $caInfo = $null
    Write-Status "Could not retrieve CA certificate information" "WARNING"
}

# Post-deployment summary
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  AD CS Deployment Complete" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Server: $serverFQDN"
Write-Host "Domain: $($domain.DNSRoot)"
Write-Host "CA Name: $($Config.CACommonName)"
Write-Host "CA Type: $($Config.CAType)"

if ($caInfo) {
    Write-Host "`nCA Certificate Information:" -ForegroundColor Cyan
    Write-Host "  Subject: $($caInfo.Subject)"
    Write-Host "  Thumbprint: $($caInfo.Thumbprint)"
    Write-Host "  Valid From: $($caInfo.NotBefore)"
    Write-Host "  Valid Until: $($caInfo.NotAfter)"
    Write-Host "  Serial Number: $($caInfo.SerialNumber)"
}

if ($Config.InstallIIS) {
    Write-Host "`nCRL Distribution:" -ForegroundColor Cyan
    Write-Host "  HTTP: http://$serverFQDN/CertEnroll/"
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Verification Commands" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Check CA status:" -ForegroundColor Yellow
Write-Host "  certutil -ping" -ForegroundColor White
Write-Host ""
Write-Host "View CA configuration:" -ForegroundColor Yellow
Write-Host "  certutil -getreg CA\" -ForegroundColor White
Write-Host ""
Write-Host "View CA certificate:" -ForegroundColor Yellow
Write-Host "  certutil -ca.cert" -ForegroundColor White
Write-Host ""
Write-Host "Check CRL:" -ForegroundColor Yellow
Write-Host "  certutil -CRL" -ForegroundColor White
Write-Host ""
Write-Host "List certificate templates:" -ForegroundColor Yellow
Write-Host "  certutil -CATemplates" -ForegroundColor White
Write-Host ""
Write-Host "Access CA management console:" -ForegroundColor Yellow
Write-Host "  mmc certsrv.msc" -ForegroundColor White
Write-Host ""

# Check for warnings or issues
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "  Important Notes" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "[*] CA deployment complete on $serverFQDN" -ForegroundColor Green
Write-Host "[*] Certificate templates are available for enrollment" -ForegroundColor Green

if (-not $Config.InstallIIS) {
    Write-Host "[!] IIS not installed - HTTP CRL distribution unavailable" -ForegroundColor Yellow
    Write-Host "    Install IIS for better CRL distribution in enterprise" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "AD CS deployment completed successfully!" -ForegroundColor Green
Write-Host ""