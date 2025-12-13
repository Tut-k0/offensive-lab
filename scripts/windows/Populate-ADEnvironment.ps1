#Requires -RunAsAdministrator
#Requires -Modules ActiveDirectory

<#
.SYNOPSIS
    Populates Active Directory with users, groups, OUs, and computer objects.

.DESCRIPTION
    Creates organizational structure, user accounts, security groups, and
    computer objects to simulate a small enterprise environment. Configurable
    via JSON for easy customization and eventual automation.

.PARAMETER ConfigFile
    Path to JSON configuration file. If not provided, uses inline defaults.

.PARAMETER OutputCredentialsCsv
    Outputs a CSV file of the credentials provisioned.

.EXAMPLE
    .\Populate-ADEnvironment.ps1 -ConfigFile ".\ad-populate-config.json" -OutputCredentialsCsv
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$ConfigFile,

    [Parameter(Mandatory=$false)]
    [switch]$OutputCredentialsCsv
)

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

# Weak passwords that meet AD complexity but are in rockyou
# Generated with: grep -E '^.{7,12}$' rockyou.txt | grep -E '[A-Z]' | grep -E '[a-z]' | grep -E '[0-9]' | grep -E '[!@#$%^&*]' | head -50
$WeakPasswordList = @(
    'P@ssw0rd'
    '!QAZ2wsx'
    '1qaz!QAZ'
    '1qaz@WSX'
    '!QAZ1qaz'
    'ZAQ!2wsx'
    '1qazZAQ!'
    '!QAZxsw2'
    'Pa$$w0rd'
    'ZAQ!1qaz'
    'zaq1!QAZ'
    '!QAZzaq1'
    'P@$$w0rd'
    '1qazXSW@'
    'Jesus#1'
    'zaq1@WSX'
    'Godis#1'
    'Password1!'
    '3edc#EDC'
    '2wsx@WSX'
    '12qw!@QW'
    '#EDC4rfv'
    'P@55w0rd'
    'Jesusis#1'
    '#1Bitch'
    '@WSX2wsx'
    '!Qaz2wsx'
    'zaq1ZAQ!'
    'ZAQ!xsw2'
    '#EDC3edc'
    'ZAQ!zaq1'
    'Raiders#1'
    'Babygirl#1'
    'Angel#1'
    '!Q@W3e4r'
    'dkiN9^o'
    'Passw0rd!'
    'Hottie#1'
    '@WSX3edc'
    'P@ssw0rd1'
    '@WSXxsw2'
    '7ujm&UJM'
    '1q2w!Q@W'
    '!@QW12qw'
    'ZSE$5rdx'
    'BHU*8uhb'
    'Ashley#1'
    'Abc123!@#'
    '$RFV5tgb'
    'p@SSW0RD'
)

# Default configuration - simulates small enterprise
$DefaultConfig = @{
    DomainDN = "DC=redteam,DC=lab"
    OrganizationalUnits = @(
        @{ Name = "Corporate"; Path = "" },
        @{ Name = "Workstations"; Path = "OU=Corporate" },
        @{ Name = "Servers"; Path = "OU=Corporate" },
        @{ Name = "Users"; Path = "OU=Corporate" },
        @{ Name = "Groups"; Path = "OU=Corporate" },
        @{ Name = "Service Accounts"; Path = "OU=Corporate" },
        @{ Name = "IT"; Path = "OU=Users,OU=Corporate" },
        @{ Name = "HR"; Path = "OU=Users,OU=Corporate" },
        @{ Name = "Finance"; Path = "OU=Users,OU=Corporate" },
        @{ Name = "Sales"; Path = "OU=Users,OU=Corporate" }
    )
    Groups = @(
        @{ Name = "IT Admins"; Scope = "Global"; Category = "Security"; Description = "IT Department Administrators"; Path = "OU=Groups,OU=Corporate" },
        @{ Name = "Help Desk"; Scope = "Global"; Category = "Security"; Description = "Help Desk Team"; Path = "OU=Groups,OU=Corporate" },
        @{ Name = "HR Staff"; Scope = "Global"; Category = "Security"; Description = "Human Resources"; Path = "OU=Groups,OU=Corporate" },
        @{ Name = "Finance Team"; Scope = "Global"; Category = "Security"; Description = "Finance Department"; Path = "OU=Groups,OU=Corporate" },
        @{ Name = "Sales Team"; Scope = "Global"; Category = "Security"; Description = "Sales Department"; Path = "OU=Groups,OU=Corporate" },
        @{ Name = "Remote Access"; Scope = "Global"; Category = "Security"; Description = "VPN/Remote Access Users"; Path = "OU=Groups,OU=Corporate" },
        @{ Name = "File Share RW"; Scope = "Global"; Category = "Security"; Description = "File Share Read/Write"; Path = "OU=Groups,OU=Corporate" },
        @{ Name = "File Share RO"; Scope = "Global"; Category = "Security"; Description = "File Share Read Only"; Path = "OU=Groups,OU=Corporate" }
    )
    Users = @(
        # IT Department
        @{
            Username = "jsmith"
            FirstName = "John"
            LastName = "Smith"
            Department = "IT"
            Title = "IT Manager"
            OU = "OU=IT,OU=Users,OU=Corporate"
            Groups = @("IT Admins", "Remote Access", "File Share RW")
            Description = "IT Department Manager"
            WeakPassword = $false
            PasswordNeverExpires = $true
        },
        @{
            Username = "bwilliams"
            FirstName = "Bob"
            LastName = "Williams"
            Department = "IT"
            Title = "Systems Administrator"
            OU = "OU=IT,OU=Users,OU=Corporate"
            Groups = @("IT Admins", "Remote Access", "File Share RW")
            Description = "Systems Administrator"
            WeakPassword = $false
            PasswordNeverExpires = $true
        },
        @{
            Username = "agarcia"
            FirstName = "Alice"
            LastName = "Garcia"
            Department = "IT"
            Title = "Help Desk Technician"
            OU = "OU=IT,OU=Users,OU=Corporate"
            Groups = @("Help Desk", "File Share RW")
            Description = "Help Desk Support"
            WeakPassword = $false
            PasswordNeverExpires = $true
        },
        # HR Department
        @{
            Username = "mjohnson"
            FirstName = "Mary"
            LastName = "Johnson"
            Department = "HR"
            Title = "HR Director"
            OU = "OU=HR,OU=Users,OU=Corporate"
            Groups = @("HR Staff", "Remote Access", "File Share RW")
            Description = "Human Resources Director"
            WeakPassword = $false
            PasswordNeverExpires = $true
        },
        @{
            Username = "tmartinez"
            FirstName = "Tom"
            LastName = "Martinez"
            Department = "HR"
            Title = "HR Specialist"
            OU = "OU=HR,OU=Users,OU=Corporate"
            Groups = @("HR Staff", "File Share RO")
            Description = "HR Specialist"
            WeakPassword = $false
            PasswordNeverExpires = $true
        },
        # Finance Department
        @{
            Username = "sdavis"
            FirstName = "Sarah"
            LastName = "Davis"
            Department = "Finance"
            Title = "CFO"
            OU = "OU=Finance,OU=Users,OU=Corporate"
            Groups = @("Finance Team", "Remote Access", "File Share RW")
            Description = "Chief Financial Officer"
            WeakPassword = $false
            PasswordNeverExpires = $true
        },
        @{
            Username = "rlopez"
            FirstName = "Robert"
            LastName = "Lopez"
            Department = "Finance"
            Title = "Accountant"
            OU = "OU=Finance,OU=Users,OU=Corporate"
            Groups = @("Finance Team", "File Share RW")
            Description = "Senior Accountant"
            WeakPassword = $false
            PasswordNeverExpires = $true
        },
        # Sales Department
        @{
            Username = "klee"
            FirstName = "Kevin"
            LastName = "Lee"
            Department = "Sales"
            Title = "Sales Manager"
            OU = "OU=Sales,OU=Users,OU=Corporate"
            Groups = @("Sales Team", "Remote Access", "File Share RW")
            Description = "Sales Department Manager"
            WeakPassword = $false
            PasswordNeverExpires = $true
        },
        @{
            Username = "jwhite"
            FirstName = "Jennifer"
            LastName = "White"
            Department = "Sales"
            Title = "Account Executive"
            OU = "OU=Sales,OU=Users,OU=Corporate"
            Groups = @("Sales Team", "Remote Access", "File Share RO")
            Description = "Senior Account Executive"
            WeakPassword = $false
            PasswordNeverExpires = $true
        },
        @{
            Username = "dharris"
            FirstName = "David"
            LastName = "Harris"
            Department = "Sales"
            Title = "Sales Representative"
            OU = "OU=Sales,OU=Users,OU=Corporate"
            Groups = @("Sales Team", "File Share RO")
            Description = "Sales Representative"
            WeakPassword = $false
            PasswordNeverExpires = $true
        }
    )
    ServiceAccounts = @(
        @{
            Username = "svc_backup"
            Description = "Backup Service Account"
            OU = "OU=Service Accounts,OU=Corporate"
            WeakPassword = $false
            PasswordNeverExpires = $true
        },
        @{
            Username = "svc_sql"
            Description = "SQL Server Service Account"
            OU = "OU=Service Accounts,OU=Corporate"
            WeakPassword = $false
            PasswordNeverExpires = $true
        },
        @{
            Username = "svc_web"
            Description = "Web Application Service Account"
            OU = "OU=Service Accounts,OU=Corporate"
            WeakPassword = $false
            PasswordNeverExpires = $true
        }
    )
    Computers = @(
        @{ Name = "WS01"; OU = "OU=Workstations,OU=Corporate"; Description = "Windows 11 Workstation" },
        @{ Name = "WS02"; OU = "OU=Workstations,OU=Corporate"; Description = "Windows 11 Workstation" },
        @{ Name = "WEB01"; OU = "OU=Servers,OU=Corporate"; Description = "Web Server (DMZ)" },
        @{ Name = "FILE01"; OU = "OU=Servers,OU=Corporate"; Description = "File Server" },
        @{ Name = "SQL01"; OU = "OU=Servers,OU=Corporate"; Description = "SQL Server" }
    )
}

# Load config from file if provided
if ($ConfigFile -and (Test-Path $ConfigFile)) {
    Write-Host "[*] Loading configuration from: $ConfigFile" -ForegroundColor Cyan
    $Config = Get-Content $ConfigFile | ConvertFrom-Json
} else {
    Write-Host "[*] Using default configuration" -ForegroundColor Yellow
    $Config = $DefaultConfig
}

# Pre-flight checks
Write-Status "Running pre-flight checks..." "INFO"

# Verify we're on a DC
try {
    $domain = Get-ADDomain -ErrorAction Stop
    Write-Status "Connected to domain: $($domain.DNSRoot)" "SUCCESS"
} catch {
    Write-Status "Not connected to AD domain. Ensure DC promotion completed." "ERROR"
    exit 1
}

# Verify Active Directory module
if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Status "ActiveDirectory module not found" "ERROR"
    exit 1
}

Import-Module ActiveDirectory -ErrorAction Stop

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Populating AD Environment" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Domain: $($domain.DNSRoot)"
Write-Host "OUs: $($Config.OrganizationalUnits.Count)"
Write-Host "Groups: $($Config.Groups.Count)"
Write-Host "Users: $($Config.Users.Count)"
Write-Host "Service Accounts: $($Config.ServiceAccounts.Count)"
Write-Host "Computers: $($Config.Computers.Count)"
Write-Host ""
Write-Host ""

# Create Organizational Units
Write-Status "Creating Organizational Units..." "INFO"
foreach ($ou in $Config.OrganizationalUnits) {
    try {
        $ouPath = if ($ou.Path) { "$($ou.Path),$($Config.DomainDN)" } else { $Config.DomainDN }
        $ouDN = "OU=$($ou.Name),$ouPath"

        if (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$ouDN'" -ErrorAction SilentlyContinue) {
            Write-Status "  OU already exists: $($ou.Name)" "WARNING"
        } else {
            New-ADOrganizationalUnit -Name $ou.Name -Path $ouPath -ErrorAction Stop
            Write-Status "  Created OU: $($ou.Name)" "SUCCESS"
        }
    } catch {
        Write-Status "  Failed to create OU $($ou.Name): $_" "ERROR"
    }
}

# Create Groups
Write-Status "`nCreating Security Groups..." "INFO"
foreach ($group in $Config.Groups) {
    try {
        $groupPath = "$($group.Path),$($Config.DomainDN)"

        if (Get-ADGroup -Filter "Name -eq '$($group.Name)'" -ErrorAction SilentlyContinue) {
            Write-Status "  Group already exists: $($group.Name)" "WARNING"
        } else {
            New-ADGroup -Name $group.Name `
                -GroupScope $group.Scope `
                -GroupCategory $group.Category `
                -Description $group.Description `
                -Path $groupPath `
                -ErrorAction Stop
            Write-Status "  Created group: $($group.Name)" "SUCCESS"
        }
    } catch {
        Write-Status "  Failed to create group $($group.Name): $_" "ERROR"
    }
}

# Create Users
Write-Status "`nCreating User Accounts..." "INFO"
$createdUsers = @()

foreach ($user in $Config.Users) {
    try {
        $userPath = "$($user.OU),$($Config.DomainDN)"
        $userPrincipalName = "$($user.Username)@$($domain.DNSRoot)"

        if (Get-ADUser -Filter "SamAccountName -eq '$($user.Username)'" -ErrorAction SilentlyContinue) {
            Write-Status "  User already exists: $($user.Username)" "WARNING"
        } else {
            # Generate password based on WeakPassword flag
            if ($user.WeakPassword) {
                $password = $WeakPasswordList | Get-Random
                $passwordType = "weak"
            } else {
                $passwordLength = Get-Random -Minimum 8 -Maximum 13
                $password = New-RandomPassword -Length $passwordLength
                $passwordType = "strong"
            }

            $securePassword = ConvertTo-SecureString $password -AsPlainText -Force

            New-ADUser -SamAccountName $user.Username `
                -UserPrincipalName $userPrincipalName `
                -Name "$($user.FirstName) $($user.LastName)" `
                -GivenName $user.FirstName `
                -Surname $user.LastName `
                -DisplayName "$($user.FirstName) $($user.LastName)" `
                -Department $user.Department `
                -Title $user.Title `
                -Description $user.Description `
                -AccountPassword $securePassword `
                -Enabled $true `
                -ChangePasswordAtLogon $false `
                -PasswordNeverExpires $user.PasswordNeverExpires `
                -Path $userPath `
                -ErrorAction Stop

            Write-Status "  Created user: $($user.Username) ($($user.FirstName) $($user.LastName)) [$passwordType]" "SUCCESS"

            # Store credentials for output
            $createdUsers += [PSCustomObject]@{
                Username = $user.Username
                FullName = "$($user.FirstName) $($user.LastName)"
                UPN = $userPrincipalName
                Password = $password
                PasswordType = $passwordType
                Department = $user.Department
                Title = $user.Title
            }

            # Add user to groups
            foreach ($groupName in $user.Groups) {
                try {
                    Add-ADGroupMember -Identity $groupName -Members $user.Username -ErrorAction Stop
                    Write-Status "    Added to group: $groupName" "INFO"
                } catch {
                    Write-Status "    Failed to add to group $groupName`: $_" "WARNING"
                }
            }
        }
    } catch {
        Write-Status "  Failed to create user $($user.Username): $_" "ERROR"
    }
}

# Create Service Accounts
Write-Status "`nCreating Service Accounts..." "INFO"
$createdServiceAccounts = @()

foreach ($svc in $Config.ServiceAccounts) {
    try {
        $svcPath = "$($svc.OU),$($Config.DomainDN)"
        $userPrincipalName = "$($svc.Username)@$($domain.DNSRoot)"

        if (Get-ADUser -Filter "SamAccountName -eq '$($svc.Username)'" -ErrorAction SilentlyContinue) {
            Write-Status "  Service account already exists: $($svc.Username)" "WARNING"
        } else {
            # Generate password based on WeakPassword flag
            if ($svc.WeakPassword) {
                $password = $WeakPasswordList | Get-Random
                $passwordType = "weak"
            } else {
                # Generate strong password for service accounts (24-32 chars)
                $passwordLength = Get-Random -Minimum 24 -Maximum 33
                $password = New-RandomPassword -Length $passwordLength
                $passwordType = "strong"
            }

            $securePassword = ConvertTo-SecureString $password -AsPlainText -Force

            New-ADUser -SamAccountName $svc.Username `
                -UserPrincipalName $userPrincipalName `
                -Name $svc.Username `
                -Description $svc.Description `
                -AccountPassword $securePassword `
                -Enabled $true `
                -PasswordNeverExpires $svc.PasswordNeverExpires `
                -ChangePasswordAtLogon $false `
                -Path $svcPath `
                -ErrorAction Stop

            Write-Status "  Created service account: $($svc.Username)" "SUCCESS"

            # Store credentials for output
            $createdServiceAccounts += [PSCustomObject]@{
                Username = $svc.Username
                UPN = $userPrincipalName
                Password = $password
                PasswordType = $passwordType
                Description = $svc.Description
            }
        }
    } catch {
        Write-Status "  Failed to create service account $($svc.Username): $_" "ERROR"
    }
}

# Create Computer Objects
Write-Status "`nCreating Computer Objects..." "INFO"
foreach ($computer in $Config.Computers) {
    try {
        $compPath = "$($computer.OU),$($Config.DomainDN)"

        if (Get-ADComputer -Filter "Name -eq '$($computer.Name)'" -ErrorAction SilentlyContinue) {
            Write-Status "  Computer already exists: $($computer.Name)" "WARNING"
        } else {
            New-ADComputer -Name $computer.Name `
                -SAMAccountName $computer.Name `
                -Description $computer.Description `
                -Path $compPath `
                -Enabled $true `
                -ErrorAction Stop

            Write-Status "  Created computer: $($computer.Name)" "SUCCESS"
        }
    } catch {
        Write-Status "  Failed to create computer $($computer.Name): $_" "ERROR"
    }
}

# Final summary
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  AD Environment Population Complete" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan

$summary = @{
    OUs = (Get-ADOrganizationalUnit -Filter * -SearchBase $Config.DomainDN | Where-Object { $_.DistinguishedName -ne $Config.DomainDN }).Count
    Groups = (Get-ADGroup -Filter * -SearchBase $Config.DomainDN).Count
    Users = (Get-ADUser -Filter * -SearchBase $Config.DomainDN | Where-Object { $_.SamAccountName -ne 'Administrator' -and $_.SamAccountName -ne 'Guest' -and $_.SamAccountName -ne 'krbtgt' }).Count
    Computers = (Get-ADComputer -Filter * -SearchBase $Config.DomainDN).Count
}

Write-Host "Organizational Units: $($summary.OUs)"
Write-Host "Security Groups: $($summary.Groups)"
Write-Host "User Accounts: $($summary.Users)"
Write-Host "Computer Objects: $($summary.Computers)"
Write-Host ""

# Display generated credentials
if ($createdUsers.Count -gt 0 -or $createdServiceAccounts.Count -gt 0) {
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host "  GENERATED CREDENTIALS" -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host "[!] SAVE THESE CREDENTIALS - They will not be displayed again!" -ForegroundColor Red
    Write-Host ""

    if ($createdUsers.Count -gt 0) {
        Write-Host "User Accounts:" -ForegroundColor Cyan
        Write-Host ""
        foreach ($u in $createdUsers) {
            $passwordDisplay = if ($u.PasswordType -eq "weak") { "[WEAK]" } else { "[STRONG]" }
            Write-Host "  Username:   " -NoNewline -ForegroundColor Gray
            Write-Host "$($u.Username)" -ForegroundColor White
            Write-Host "  Full Name:  " -NoNewline -ForegroundColor Gray
            Write-Host "$($u.FullName)" -ForegroundColor White
            Write-Host "  UPN:        " -NoNewline -ForegroundColor Gray
            Write-Host "$($u.UPN)" -ForegroundColor White
            Write-Host "  Password:   " -NoNewline -ForegroundColor Gray
            if ($u.PasswordType -eq "weak") {
                Write-Host "$($u.Password) $passwordDisplay" -ForegroundColor Red
            } else {
                Write-Host "$($u.Password) $passwordDisplay" -ForegroundColor Green
            }
            Write-Host "  Department: " -NoNewline -ForegroundColor Gray
            Write-Host "$($u.Department)" -ForegroundColor White
            Write-Host "  Title:      " -NoNewline -ForegroundColor Gray
            Write-Host "$($u.Title)" -ForegroundColor White
            Write-Host ""
        }
    }

    if ($createdServiceAccounts.Count -gt 0) {
        Write-Host "Service Accounts:" -ForegroundColor Cyan
        Write-Host ""
        foreach ($s in $createdServiceAccounts) {
            $passwordDisplay = if ($s.PasswordType -eq "weak") { "[WEAK]" } else { "[STRONG]" }
            Write-Host "  Username:    " -NoNewline -ForegroundColor Gray
            Write-Host "$($s.Username)" -ForegroundColor White
            Write-Host "  UPN:         " -NoNewline -ForegroundColor Gray
            Write-Host "$($s.UPN)" -ForegroundColor White
            Write-Host "  Password:    " -NoNewline -ForegroundColor Gray
            if ($s.PasswordType -eq "weak") {
                Write-Host "$($s.Password) $passwordDisplay" -ForegroundColor Red
            } else {
                Write-Host "$($s.Password) $passwordDisplay" -ForegroundColor Green
            }
            Write-Host "  Description: " -NoNewline -ForegroundColor Gray
            Write-Host "$($s.Description)" -ForegroundColor White
            Write-Host ""
        }
    }

    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host ""
}

Write-Host "AD Population Complete!" -ForegroundColor Green
Write-Host ""

# Optionally export credentials to a file
if ($OutputCredentialsCsv) {
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $credFile = "AD_Credentials_$timestamp.csv"

    $allCredentials = @()
    foreach ($u in $createdUsers) {
        $allCredentials += [PSCustomObject]@{
            Type = "User"
            Username = $u.Username
            Password = $u.Password
            PasswordType = $u.PasswordType
            UPN = $u.UPN
            FullName = $u.FullName
            Department = $u.Department
            Title = $u.Title
        }
    }
    foreach ($s in $createdServiceAccounts) {
        $allCredentials += [PSCustomObject]@{
            Type = "ServiceAccount"
            Username = $s.Username
            Password = $s.Password
            PasswordType = $s.PasswordType
            UPN = $s.UPN
            FullName = $s.Username
            Department = "N/A"
            Title = $s.Description
        }
    }

    $allCredentials | Export-Csv -Path $credFile -NoTypeInformation -ErrorAction Stop
    Write-Status "Credentials exported to: $credFile" "SUCCESS"
    Write-Host "[!] Store this file securely and delete after documenting!" -ForegroundColor Yellow
}
