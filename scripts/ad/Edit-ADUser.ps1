#Requires -Version 5.1

<#
.SYNOPSIS
    Edit or offboard an Active Directory user account.
.DESCRIPTION
    This script edits AD user attributes, manages group membership, or offboards a user based on the provided UPN and options.
.NOTES
    Requires ActiveDirectory module. Expects base64-encoded JSON via userDataJson with 'upn' and optional 'offboardingOptions'.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [String]$userDataJson
)

begin {
    # Decode base64 JSON
    try {
        $decodedJson = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($userDataJson))
        $UserData = ConvertFrom-Json -InputObject $decodedJson -ErrorAction Stop
    } catch {
        Write-Output "Failed to decode or parse userDataJson: $($_.Exception.Message)"
        exit 1
    }

    # Extract fields
    $UPN = $UserData.upn
    $OffboardingOptions = $UserData.offboardingOptions

    foreach ($option in @('DeleteUser', 'DisableSignIn', 'ResetPass', 'hideFromGAL', 'RemoveGroups')) {
        if ($null -ne $OffboardingOptions.$option -and $OffboardingOptions.$option -isnot [bool]) {
            Write-Output 'Offboarding action flags must be JSON booleans'
            exit 1
        }
    }

    foreach ($option in @('passwordNeverExpires', 'cannotChangePassword', 'changePasswordAtLogon')) {
        if ($null -ne $UserData.$option -and $UserData.$option -isnot [bool]) {
            Write-Output 'Account-control flags must be JSON booleans'
            exit 1
        }
    }

    # Validate UPN
    if ($UPN -isnot [string] -or $UPN -notmatch '^[^\s@]+@[^\s@]+$') {
        Write-Output 'A full user principal name is required'
        exit 1
    }

    # Editable AD attributes
    $DisplayName = $UserData.displayName
    $GivenName = $UserData.givenName
    $Surname = $UserData.surname
    $EmailAlias = $UserData.emailAlias
    if ($EmailAlias -and $EmailAlias -notmatch '^[^\s@]+@[^\s@]+$') {
        Write-Output 'A replacement emailAlias must be a full user principal name'
        exit 1
    }
    $Company = $UserData.companyName
    $Title = $UserData.jobTitle
    $Department = $UserData.department
    $StreetAddress = $UserData.streetAddress
    $City = $UserData.city
    $State = $UserData.state
    $PostalCode = $UserData.postalCode
    $Country = $UserData.country
    $OfficePhone = $UserData.officePhone
    $MobilePhone = $UserData.mobilePhone
    $AddToGroups = if ($UserData.addToGroups) { @($UserData.addToGroups -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { @() }
    $RemoveFromGroups = if ($UserData.removeFromGroups) { @($UserData.removeFromGroups -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { @() }

    # Additional AD attributes
    $Description = $UserData.description
    $Office = $UserData.office
    $Manager = $UserData.manager
    $EmployeeId = $UserData.employeeId
    $EmployeeNumber = $UserData.employeeNumber
    $EmployeeType = $UserData.employeeType
    $Division = $UserData.division
    $Organization = $UserData.organization
    $HomePhone = $UserData.homePhone
    $Fax = $UserData.fax
    $Pager = $UserData.pager
    $HomePage = $UserData.homePage
    $Notes = $UserData.notes
    $ScriptPath = $UserData.scriptPath
    $ProfilePath = $UserData.profilePath
    $HomeDirectory = $UserData.homeDirectory
    $HomeDrive = $UserData.homeDrive
    $LogonWorkstations = $UserData.logonWorkstations
    $AccountExpirationDate = $UserData.accountExpirationDate
    $PasswordNeverExpires = if ($null -ne $UserData.passwordNeverExpires) { $UserData.passwordNeverExpires } else { $null }
    $CannotChangePassword = if ($null -ne $UserData.cannotChangePassword) { $UserData.cannotChangePassword } else { $null }
    $ChangePasswordAtLogon = if ($null -ne $UserData.changePasswordAtLogon) { $UserData.changePasswordAtLogon } else { $null }

    # Offboarding options with defaults
    $RemoveMobile = if ($null -ne $OffboardingOptions.RemoveMobile) { $OffboardingOptions.RemoveMobile } else { $false }
    $KeepCopy = if ($null -ne $OffboardingOptions.keepCopy) { $OffboardingOptions.keepCopy } else { $false }
    $ConvertToShared = if ($null -ne $OffboardingOptions.ConvertToShared) { $OffboardingOptions.ConvertToShared } else { $false }
    $RevokeSessions = if ($null -ne $OffboardingOptions.RevokeSessions) { $OffboardingOptions.RevokeSessions } else { $false }
    $RemoveLicenses = if ($null -ne $OffboardingOptions.RemoveLicenses) { $OffboardingOptions.RemoveLicenses } else { $false }
    $HideFromGAL = if ($null -ne $OffboardingOptions.HideFromGAL) { $OffboardingOptions.HideFromGAL } else { $false }
    $RemoveCalendarInvites = if ($null -ne $OffboardingOptions.removeCalendarInvites) { $OffboardingOptions.removeCalendarInvites } else { $false }
    $RemovePermissions = if ($null -ne $OffboardingOptions.removePermissions) { $OffboardingOptions.removePermissions } else { $false }
    $RemoveRules = if ($null -ne $OffboardingOptions.RemoveRules) { $OffboardingOptions.RemoveRules } else { $false }
    $RemoveGroups = if ($null -ne $OffboardingOptions.RemoveGroups) { $OffboardingOptions.RemoveGroups } else { $false }
    $DisableSignIn = if ($null -ne $OffboardingOptions.DisableSignIn) { $OffboardingOptions.DisableSignIn } else { $false }
    $ClearImmutableId = if ($null -ne $OffboardingOptions.clearImmutableId) { $OffboardingOptions.clearImmutableId } else { $false }
    $ResetPass = if ($null -ne $OffboardingOptions.ResetPass) { $OffboardingOptions.ResetPass } else { $false }
    $RemoveMFADevices = if ($null -ne $OffboardingOptions.RemoveMFADevices) { $OffboardingOptions.RemoveMFADevices } else { $false }
    $DeleteUser = if ($null -ne $OffboardingOptions.DeleteUser) { $OffboardingOptions.DeleteUser } else { $false }
    $DisableForwarding = if ($null -ne $OffboardingOptions.disableForwarding) { $OffboardingOptions.disableForwarding } else { $false }
    $ForwardEmailTo = if ($null -ne $OffboardingOptions.forwardEmailTo) { $OffboardingOptions.forwardEmailTo } else { @() }
    $OutOfOfficeMessage = if ($null -ne $OffboardingOptions.outOfOfficeMessage) { $OffboardingOptions.outOfOfficeMessage } else { '' }
    $GrantFullAccessNoAutomap = if ($null -ne $OffboardingOptions.grantFullAccessNoAutomap) { $OffboardingOptions.grantFullAccessNoAutomap } else { @() }
    $GrantFullAccessAutomap = if ($null -ne $OffboardingOptions.grantFullAccessAutomap) { $OffboardingOptions.grantFullAccessAutomap } else { @() }
    $GrantOnedriveFullAccess = if ($null -ne $OffboardingOptions.grantOnedriveFullAccess) { $OffboardingOptions.grantOnedriveFullAccess } else { @() }

    # Function to generate secure password
    function New-SecurePassword {
        param ([int]$Length = 16)
        $chars = "abcdefghjknpqrstuvwxyzABCDEFGHIJKMNPQRSTUVWXYZ0123456789!@#$%&-"
        $crypto = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
        $password = for ($i = 0; $i -lt $Length; $i++) {
            $byte = [byte[]]::new(1)
            $crypto.GetBytes($byte)
            $chars[$byte[0] % $chars.Length]
        }
        return $password -join ''
    }

    # Load AD module
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
    } catch {
        Write-Output "Failed to import ActiveDirectory module: $($_.Exception.Message)"
        exit 1
    }

    # Resolve the configured directory and OU before any account mutation.
    try {
        if (-not $UserData.domain -or -not $UserData.userOu) { throw 'Configured domain and user OU are required' }
        $domain = Get-ADDomain -Identity $UserData.domain -Server $UserData.domain -ErrorAction Stop
        if ($domain.DNSRoot -ine $UserData.domain) { throw 'Configured directory does not match the resolved domain' }
        $DirectoryServer = $domain.PDCEmulator
        if (-not $DirectoryServer) { throw 'Directory server could not be resolved' }
        $managedOu = Get-ADOrganizationalUnit -Identity $UserData.userOu -Server $DirectoryServer -ErrorAction Stop
        if (-not $managedOu.DistinguishedName.EndsWith(',' + $domain.DistinguishedName, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Configured user OU is outside the configured directory'
        }
        $candidates = @(Get-ADUser -Filter { UserPrincipalName -eq $UPN } -SearchBase $managedOu.DistinguishedName -SearchScope Subtree -Server $DirectoryServer -Properties PrimaryGroup -ErrorAction Stop)
        if ($candidates.Count -ne 1) { throw 'Expected exactly one user inside the configured user OU subtree' }
        $adUser = $candidates[0]
    } catch {
        Write-Output "Directory target rejected: $($_.Exception.Message)"
        exit 1
    }

}

# One JSON request per invocation. Windows PowerShell -File can skip process with empty redirected stdin.
end {
    $results = @()

    # Handle deletion first (terminates further actions if successful)
    if ($DeleteUser) {
        try {
            Remove-ADUser -Server $DirectoryServer -Identity $adUser -Confirm:$false -ErrorAction Stop
            $results += "Deleted AD user '$UPN' successfully"
            Write-Output ($results -join "`n")
            exit 0
        } catch {
            Write-Output "Failed to delete AD user '$UPN': $($_.Exception.Message)"
            exit 1
        }
    }

    # Reset password
    if ($ResetPass) {
        try {
            $newPassword = New-SecurePassword -Length 16
            $securePassword = ConvertTo-SecureString -String $newPassword -AsPlainText -Force
            Set-ADAccountPassword -Server $DirectoryServer -Identity $adUser -NewPassword $securePassword -Reset -ErrorAction Stop
            $results += "Reset password for '$UPN'"
        } catch {
            $results += "Failed to reset password for '$UPN': $($_.Exception.Message)"
        }
    }

    # Disable sign-in
    if ($DisableSignIn) {
        try {
            Disable-ADAccount -Server $DirectoryServer -Identity $adUser -ErrorAction Stop
            $results += "Disabled sign-in for '$UPN'"
        } catch {
            $results += "Failed to disable sign-in for '$UPN': $($_.Exception.Message)"
        }
    }

    # Hide from GAL
    if ($HideFromGAL) {
        try {
            Set-ADUser -Server $DirectoryServer -Identity $adUser -Replace @{msExchHideFromAddressLists = $true} -ErrorAction Stop
            $results += "Hid '$UPN' from Global Address List"
        } catch {
            $results += "Failed to hide '$UPN' from GAL: $($_.Exception.Message)"
        }
    }

    # Edit AD attributes
    $UserSplat = @{}
    $Replace = @{}
    if ($DisplayName) { $UserSplat['DisplayName'] = $DisplayName }
    if ($GivenName) { $UserSplat['GivenName'] = $GivenName }
    if ($Surname) { $UserSplat['Surname'] = $Surname }
    if ($EmailAlias) { $UserSplat['UserPrincipalName'] = $EmailAlias; $UserSplat['EmailAddress'] = $EmailAlias }
    if ($Company) { $UserSplat['Company'] = $Company }
    if ($Title) { $UserSplat['Title'] = $Title }
    if ($Department) { $UserSplat['Department'] = $Department }
    if ($StreetAddress) { $UserSplat['StreetAddress'] = $StreetAddress }
    if ($City) { $UserSplat['City'] = $City }
    if ($State) { $UserSplat['State'] = $State }
    if ($PostalCode) { $UserSplat['PostalCode'] = $PostalCode }
    if ($Country) { $UserSplat['Country'] = $Country }
    if ($OfficePhone) { $UserSplat['OfficePhone'] = $OfficePhone }
    if ($MobilePhone) { $UserSplat['MobilePhone'] = $MobilePhone }

    # Additional AD attributes
    if ($Description) { $UserSplat['Description'] = $Description }
    if ($Office) { $UserSplat['Office'] = $Office }
    if ($Manager) { $UserSplat['Manager'] = $Manager }
    if ($EmployeeId) { $UserSplat['EmployeeID'] = $EmployeeId }
    if ($EmployeeNumber) { $UserSplat['EmployeeNumber'] = $EmployeeNumber }
    if ($EmployeeType) { $Replace['employeeType'] = $EmployeeType }
    if ($Division) { $UserSplat['Division'] = $Division }
    if ($Organization) { $UserSplat['Organization'] = $Organization }
    if ($HomePhone) { $UserSplat['HomePhone'] = $HomePhone }
    if ($Fax) { $UserSplat['Fax'] = $Fax }
    if ($Pager) { $Replace['pager'] = $Pager }
    if ($HomePage) { $UserSplat['HomePage'] = $HomePage }
    if ($Notes) { $Replace['info'] = $Notes }
    if ($ScriptPath) { $UserSplat['ScriptPath'] = $ScriptPath }
    if ($ProfilePath) { $UserSplat['ProfilePath'] = $ProfilePath }
    if ($HomeDirectory) { $UserSplat['HomeDirectory'] = $HomeDirectory }
    if ($HomeDrive) { $UserSplat['HomeDrive'] = $HomeDrive }
    if ($LogonWorkstations) { $UserSplat['LogonWorkstations'] = $LogonWorkstations }
    
    # Handle special attributes that need different handling
    if ($AccountExpirationDate) { 
        try {
            $UserSplat['AccountExpirationDate'] = [DateTime]::Parse($AccountExpirationDate, [Globalization.CultureInfo]::InvariantCulture)
        } catch {
            $results += "Failed to parse accountExpirationDate"
        }
    }
    if ($null -ne $PasswordNeverExpires) { $UserSplat['PasswordNeverExpires'] = $PasswordNeverExpires }
    if ($null -ne $CannotChangePassword) { $UserSplat['CannotChangePassword'] = $CannotChangePassword }
    if ($null -ne $ChangePasswordAtLogon) { $UserSplat['ChangePasswordAtLogon'] = $ChangePasswordAtLogon }

    # These LDAP attributes are not Set-ADUser parameters (verified on Windows Server 2025).
    if ($Replace.Count -gt 0) { $UserSplat['Replace'] = $Replace }

    if ($UserSplat.Count -gt 0) {
        try {
            Set-ADUser -Server $DirectoryServer -Identity $adUser @UserSplat -ErrorAction Stop
            $results += "Updated AD attributes for '$UPN'"
        } catch {
            $results += "Failed to update AD attributes for '$UPN': $($_.Exception.Message)"
        }
    }

    # Manage group membership
    if ($AddToGroups.Count -gt 0) {
        foreach ($group in $AddToGroups) {
            try {
                Add-ADGroupMember -Server $DirectoryServer -Identity $group -Members $adUser -ErrorAction Stop
                $results += "Added '$UPN' to group '$group'"
            } catch {
                $results += "Failed to add '$UPN' to group '$group': $($_.Exception.Message)"
            }
        }
    }

    if ($RemoveFromGroups.Count -gt 0) {
        foreach ($group in $RemoveFromGroups) {
            try {
                Remove-ADGroupMember -Server $DirectoryServer -Identity $group -Members $adUser -Confirm:$false -ErrorAction Stop
                $results += "Removed '$UPN' from group '$group'"
            } catch {
                $results += "Failed to remove '$UPN' from group '$group': $($_.Exception.Message)"
            }
        }
    }

    # Remove from all groups (if specified)
    if ($RemoveGroups) {
        try {
            $currentGroups = Get-ADPrincipalGroupMembership -Server $DirectoryServer -Identity $adUser | Where-Object { $_.DistinguishedName -and $_.DistinguishedName -ine $adUser.PrimaryGroup }
            foreach ($group in $currentGroups) {
                Remove-ADGroupMember -Server $DirectoryServer -Identity $group -Members $adUser -Confirm:$false -ErrorAction Stop
            }
            $results += "Removed '$UPN' from all groups"
        } catch {
            $results += "Failed to remove '$UPN' from all groups: $($_.Exception.Message)"
        }
    }

    # If no actions were performed
    if ($results.Count -eq 0) {
        Write-Output "No supported edit actions supplied for '$UPN'"
        exit 2
    }

    Write-Output ($results -join "`n")
    if (@($results | Where-Object { $_ -like 'Failed to *' }).Count -gt 0) { exit 1 }
    exit 0
}