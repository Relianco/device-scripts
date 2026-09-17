#Requires -Version 5.1

<#
.SYNOPSIS
    Create an Active Directory user account and add to AD groups. Saves the password to a custom field.
.DESCRIPTION
    This script creates an Active Directory user account, adds the user to specified AD groups, and saves the password (custom or randomly generated) to a custom field in NinjaOne.
.NOTES
    Minimum OS Architecture Supported: Windows Server 2019 Core
    This script requires the ActiveDirectory module.
    The user data is expected to be passed as a base64-encoded JSON string via the userDataJson parameter.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [String]$userDataJson
)

begin {
    # Debug: Log all environment variables to see what NinjaOne is setting
    Write-Host "=== Environment Variables ==="
    Get-ChildItem Env: | ForEach-Object {
        Write-Host "$($_.Name)=$($_.Value)"
    }

    # Debug: Log the received parameter
    Write-Host "=== Received Parameters ==="
    Write-Host "userDataJson parameter (base64-encoded): $userDataJson"

    # Debug: Log the raw command-line arguments and bound parameters
    Write-Host "=== Raw Command-Line Arguments ==="
    Write-Host "PSBoundParameters:"
    $PSBoundParameters.GetEnumerator() | ForEach-Object {
        Write-Host "Parameter: $($_.Key) = $($_.Value)"
    }
    Write-Host "Unbound Arguments (args): $args"

    # Debug: Log the PowerShell version and execution context
    Write-Host "=== PowerShell Execution Context ==="
    Write-Host "PowerShell Version: $($PSVersionTable.PSVersion)"
    Write-Host "Execution Policy: $(Get-ExecutionPolicy)"
    Write-Host "Current Directory: $(Get-Location)"

    # Decode the base64-encoded JSON string
    Write-Host "=== Decoding Base64 userDataJson ==="
    try {
        $decodedJson = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($userDataJson))
        Write-Host "Successfully decoded userDataJson: $decodedJson"
    } catch {
        Write-Host -Object "[Error] Failed to decode base64 userDataJson. Error: $($_.Exception.Message)"
        Write-Host -Object "Raw userDataJson (base64): $userDataJson"
        exit 1
    }

    # Parse the decoded JSON string into a PowerShell object
    Write-Host "=== Parsing Decoded userDataJson ==="
    try {
        $UserData = ConvertFrom-Json -InputObject $decodedJson -ErrorAction Stop
        Write-Host "Successfully parsed userDataJson."
    } catch {
        Write-Host -Object "[Error] Failed to parse userDataJson. Error: $($_.Exception.Message)"
        Write-Host -Object "Raw decoded userDataJson: $decodedJson"
        exit 1
    }

    # Extract fields from the parsed JSON object
    Write-Host "=== Extracting Fields from userDataJson ==="
    $Username = $UserData.username
    $DisplayName = $UserData.displayName
    $EmailAlias = $UserData.emailAlias  # Match JSON key casing
    $DomainName = if ($UserData.domain) { $UserData.domain } else { $UserData.adDomain }
    $CustomField = "temppass"           # Hardcode to 'temppass' as expected by NinjaOne
    $PasswordLength = $UserData.passwordLength
    $CustomPassword = $UserData.password
    $DisableAfterDays = $UserData.disableAfterDays
    $PasswordExpireOption = $UserData.passwordExpireOption
    $AddToGroups = if ($UserData.addToGroups) { $UserData.addToGroups -split ',' } else { @() }
    $Title = $UserData.title
    $GivenName = $UserData.givenName
    $Surname = $UserData.surname
    $JobTitle = $UserData.jobTitle
    $StreetAddress = $UserData.streetAddress
    $PostalCode = $UserData.postalCode
    $CompanyName = $UserData.companyName
    $Department = $UserData.department
    $MobilePhone = $UserData.mobilePhone
    $BusinessPhones = $UserData.businessPhones
    $OtherMails = $UserData.otherMails
    $Autopassword = $UserData.Autopassword  # Match JSON key casing

    # Set default password length if not provided and Autopassword is true
    if ($Autopassword -and !$PasswordLength) {
        $PasswordLength = 16  # Default to 16 if not specified
        Write-Host "Autopassword is true and PasswordLength not provided. Using default PasswordLength: $PasswordLength"
    }

    # Debug: Log extracted fields
    Write-Host "=== Extracted Fields ==="
    Write-Host "Username: $Username"
    Write-Host "DisplayName: $DisplayName"
    Write-Host "EmailAlias: $EmailAlias"
    Write-Host "DomainName: $DomainName"
    Write-Host "CustomField: $CustomField"
    Write-Host "PasswordLength: $PasswordLength"
    Write-Host "CustomPassword: $CustomPassword"
    Write-Host "DisableAfterDays: $DisableAfterDays"
    Write-Host "PasswordExpireOption: $PasswordExpireOption"
    Write-Host "AddToGroups: $AddToGroups"
    Write-Host "Title: $Title"
    Write-Host "GivenName: $GivenName"
    Write-Host "Surname: $Surname"
    Write-Host "JobTitle: $JobTitle"
    Write-Host "StreetAddress: $StreetAddress"
    Write-Host "PostalCode: $PostalCode"
    Write-Host "CompanyName: $CompanyName"
    Write-Host "Department: $Department"
    Write-Host "MobilePhone: $MobilePhone"
    Write-Host "BusinessPhones: $BusinessPhones"
    Write-Host "OtherMails: $OtherMails"
    Write-Host "Autopassword: $Autopassword"

    # Validate input parameters for user creation, checking for absence, invalid characters, length, and options.
    Write-Host "=== Validating Input Parameters ==="
    if (!$Username) {
        Write-Host -Object "[Error] Please enter a username!"
        exit 1
    }

    if (!$CustomField) {
        Write-Host -Object "[Error] A Custom Field to store the password is required!"
        exit 1
    }

    # Ensure username does not contain illegal characters.
    if ($Username -match '[\[\]:;|=+*?<>/\\,"@]') {
        Write-Host -Object ("[Error] $Username contains one of the following invalid characters: " + ' " [ ] : ; | = + * ? < > / \ , @')
        exit 1
    }

    # Ensure the username does not contain spaces.
    if ($Username -match '\s') {
        Write-Host -Object ("[Error] '$Username' contains a space.")
        exit 1
    }

    # Validate password length if no custom password is provided and Autopassword is false
    if (!$CustomPassword -and !$Autopassword -and (!$PasswordLength -or $PasswordLength -lt 8)) {
        Write-Host -Object "[Error] Password length must be greater than or equal to 8 when no custom password is provided and Autopassword is false!"
        exit 1
    }

    # Validate disable after days, cannot be negative.
    if ($DisableAfterDays -and $DisableAfterDays -lt 0) {
        Write-Host -Object "[Error] Disable After Days cannot be less than 0."
        exit 1
    }

    # Validate password expiration options.
    $ValidExpireOption = "User Must Change Password", "Password Never Expires"
    if ($PasswordExpireOption -and $ValidExpireOption -notcontains $PasswordExpireOption) {
        Write-Host -Object "[Error] Invalid password expire option given. Must be either 'User Must Change Password' or 'Password Never Expires'"
        exit 1
    }

    # Define the New-SecurePassword function
    function New-SecurePassword {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $false)]
            [int]$Length = 16,
            [Parameter(Mandatory = $false)]
            [switch]$IncludeSpecialCharacters
        )
        # .NET class for generating cryptographically secure random numbers
        $cryptoProvider = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
        $baseChars = "abcdefghjknpqrstuvwxyzABCDEFGHIJKMNPQRSTUVWXYZ0123456789"
        $SpecialCharacters = '!@#$%&-'
        $passwordChars = $baseChars + $(if ($IncludeSpecialCharacters) { $SpecialCharacters } else { '' })
        $password = for ($i = 0; $i -lt $Length; $i++) {
            $byte = [byte[]]::new(1)
            $cryptoProvider.GetBytes($byte)
            $charIndex = $byte[0] % $passwordChars.Length
            $passwordChars[$charIndex]
        }
        
        return $password -join ''
    }

    # Import Active Directory module
    Write-Host "=== Importing Active Directory Module ==="
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        Write-Host "Active Directory module imported successfully."
    } catch {
        Write-Host -Object "[Error] Failed to import Active Directory module. Error: $($_.Exception.Message)"
        exit 1
    }

    # Check if script is running with necessary permissions
    Write-Host "=== Checking Permissions ==="
    $CurrentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    Write-Host "Script is running as user: $CurrentUser"
    
    # Verify that the user has permissions to create AD users
    try {
        $Test = Get-ADDomain -ErrorAction Stop
        Write-Host "Successfully accessed AD domain. Permissions are sufficient."
    } catch {
        Write-Host -Object "[Error] Insufficient permissions to access Active Directory. Error: $($_.Exception.Message)"
        exit 1
    }

    # Resolve the configured directory and OU before creating anything, the same way
    # the edit and offboard scripts do: a user created outside the managed OU could
    # never be edited or offboarded again.
    Write-Host "=== Resolving Configured Directory and OU ==="
    try {
        if (-not $DomainName -or -not $UserData.userOu) { throw 'Configured domain and user OU are required' }
        $domain = Get-ADDomain -Identity $DomainName -Server $DomainName -ErrorAction Stop
        if ($domain.DNSRoot -ine $DomainName) { throw 'Configured directory does not match the resolved domain' }
        $DirectoryServer = $domain.PDCEmulator
        if (-not $DirectoryServer) { throw 'Directory server could not be resolved' }
        $ManagedOu = Get-ADOrganizationalUnit -Identity $UserData.userOu -Server $DirectoryServer -ErrorAction Stop
        if (-not $ManagedOu.DistinguishedName.EndsWith(',' + $domain.DistinguishedName, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Configured user OU is outside the configured directory'
        }
    } catch {
        Write-Host -Object "Directory target rejected: $($_.Exception.Message)"
        exit 1
    }

    # Check if user already exists in AD
    Write-Host "=== Checking if User Exists in AD ==="
    if (Get-ADUser -Filter { SamAccountName -eq "$Username" } -Server $DirectoryServer) {
        Write-Host -Object "[Error] User $Username already exists in Active Directory!"
        exit 1
    }
    Write-Host "User $Username does not exist in AD. Proceeding with creation."
}

process {
    # Determine the password to use: custom password if provided, otherwise generate a random one
    Write-Host "=== Determining Password ==="
    if ($CustomPassword) {
        $Password = $CustomPassword
        Write-Host "Using provided custom password."
    } else {
        Write-Host "Generating a random password..."
        $i = 0
        do {
            $Password = New-SecurePassword -Length $PasswordLength -IncludeSpecialCharacters
            $i++
            Write-Host "Password generation attempt $i"
        } while ($i -lt 1000 -and !($Password -match '[@!#$%&\-]+' -and $Password -match '[A-Z]+' -and $Password -match '[a-z]+' -and $Password -match '[0-9]+'))
        
        if ($i -eq 1000) {
            Write-Host "[Error] Unable to generate a secure password after 1000 tries."
            exit 1
        }
        Write-Host "Successfully generated a secure password."
    }

    # Convert password to SecureString
    Write-Host "=== Converting Password to SecureString ==="
    try {
        $SecurePassword = ConvertTo-SecureString -String $Password -AsPlainText -Force
        Write-Host "Password converted to SecureString successfully."
    } catch {
        Write-Host "[Error] Failed to convert password to SecureString. Error: $($_.Exception.Message)"
        exit 1
    }

    # Attempt to set the custom field with the password
    Write-Host "=== Setting Custom Field in NinjaOne ==="
    try {
        Write-Host "Attempting to set password in Custom Field '$CustomField'."
        Set-NinjaProperty -Name $CustomField -Value $Password
        Write-Host "Successfully set password in Custom Field '$CustomField'!"
    }
    catch {
        Write-Host "[Error] Failed to set custom field. Error: $($_.Exception.Message)"
        exit 1
    }

    # Prepare parameters for New-ADUser
    Write-Host "=== Preparing Parameters for New-ADUser ==="
    $UserSplat = @{
        Server               = $DirectoryServer
        Path                 = $ManagedOu.DistinguishedName
        SamAccountName       = $Username
        Name                 = if ($DisplayName) { $DisplayName } else { $Username }
        UserPrincipalName    = if ($EmailAlias) { $EmailAlias } else { "$Username@$DomainName" }
        GivenName            = if ($UserData.givenName) { $UserData.givenName } else { ($DisplayName -split ' ')[0] }  # Use givenName if provided, else first part of DisplayName
        Surname              = if ($UserData.surname) { $UserData.surname } else { ($DisplayName -split ' ')[-1] }     # Use surname if provided, else last part of DisplayName
        Enabled              = $true  # Enable users by default
        AccountPassword      = $SecurePassword
        PasswordNeverExpires = $false
        ChangePasswordAtLogon = $false
        EmailAddress         = if ($EmailAlias) { $EmailAlias } else { "$Username@$DomainName" }
    }

    # Conditionally add optional fields if they are non-empty
    if ($UserData.title) { $UserSplat['Title'] = $UserData.title }
    if ($UserData.jobTitle) { $UserSplat['Title'] = $UserData.jobTitle } # JobTitle overrides Title if both are provided
    if ($UserData.streetAddress) { $UserSplat['StreetAddress'] = $UserData.streetAddress }
    if ($UserData.postalCode) { $UserSplat['PostalCode'] = $UserData.postalCode }
    if ($UserData.companyName) { $UserSplat['Company'] = $UserData.companyName }
    if ($UserData.department) { $UserSplat['Department'] = $UserData.department }
    if ($UserData.mobilePhone) { $UserSplat['MobilePhone'] = $UserData.mobilePhone }
    if ($UserData.businessPhones) { $UserSplat['OfficePhone'] = $UserData.businessPhones } # Map businessPhones to OfficePhone
    if ($UserData.otherMails) { $UserSplat['OtherAttributes'] = @{ 'otherMailbox' = $UserData.otherMails } } # Map otherMails to otherMailbox

    Write-Host "=== New-ADUser Parameters ==="
    foreach ($key in $UserSplat.Keys) {
        Write-Host "$key = $($UserSplat[$key])"
    }

    # Set Password Expiration Options
    Write-Host "=== Setting Password Expiration Options ==="
    if ($PasswordExpireOption -eq "Password Never Expires") {
        $UserSplat['PasswordNeverExpires'] = $true
        Write-Host "Password set to never expire."
    }
    elseif ($PasswordExpireOption -eq "User Must Change Password") {
        $UserSplat['ChangePasswordAtLogon'] = $true
        Write-Host "User must change password at logon."
    }

    # Set Account Expiration Date
    Write-Host "=== Setting Account Expiration Date ==="
    if ($DisableAfterDays -and $DisableAfterDays -gt 0) {
        $AccountExpires = (Get-Date).AddDays($DisableAfterDays)
        $UserSplat['AccountExpirationDate'] = $AccountExpires
        Write-Host "Account expiration date set to: $AccountExpires"
    }

    # Create the new AD user
    Write-Host "=== Creating New AD User ==="
    try {
        New-ADUser @UserSplat -Verbose -ErrorAction Stop
        Write-Host "User '$Username' has been created successfully."
    } catch {
        Write-Host "[Error] Failed to create AD user '$Username'. Error: $($_.Exception.Message)"
        exit 1
    }

    # Add user to specified AD groups. Membership of the primary group (Domain Users
    # by default) is implicit, and adding it fails — skip it instead of reporting a
    # failed run for a user that was created correctly.
    Write-Host "=== Adding User to AD Groups ==="
    $CreatedUser = Get-ADUser -Identity $Username -Server $DirectoryServer -Properties PrimaryGroup -ErrorAction SilentlyContinue
    $PrimaryGroupName = if ($CreatedUser -and $CreatedUser.PrimaryGroup) {
        (Get-ADGroup -Identity $CreatedUser.PrimaryGroup -Server $DirectoryServer -ErrorAction SilentlyContinue).Name
    } else { $null }
    foreach ($Group in $AddToGroups) {
        $GroupName = "$Group".Trim()
        if (-not $GroupName) { continue }
        if ($PrimaryGroupName -and $GroupName -ieq $PrimaryGroupName) {
            Write-Host "User '$Username' already belongs to its primary group '$GroupName'."
            continue
        }
        try {
            Add-ADGroupMember -Identity $GroupName -Members $Username -Server $DirectoryServer -ErrorAction Stop
            Write-Host "User '$Username' was added to the AD group '$GroupName'."
        } catch {
            Write-Host "[Error] Failed to add user to group '$GroupName'. Error: $($_.Exception.Message)"
            $ExitCode = 1
        }
    }

    # Exit the script with the final status code
    Write-Host "=== Script Execution Complete ==="
    Write-Host "Exit Code: $ExitCode"
    exit $ExitCode
}