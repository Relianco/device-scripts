#Requires -Version 5.1

<#
.SYNOPSIS
    Offboard an Active Directory user account.
.DESCRIPTION
    This script offboards an AD user with options like disabling sign-in, resetting password, or deletion.
.NOTES
    Requires ActiveDirectory module. Expects base64-encoded JSON via userDataJson with 'upn' and 'offboardingOptions'.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [String]$userDataJson
)

begin {
    try {
        $decodedJson = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($userDataJson))
        $UserData = ConvertFrom-Json -InputObject $decodedJson -ErrorAction Stop
    } catch {
        Write-Output "Failed to decode or parse userDataJson: $($_.Exception.Message)"
        exit 1
    }

    $UPN = $UserData.upn
    $OffboardingOptions = $UserData.offboardingOptions

    foreach ($option in @('DeleteUser', 'DisableSignIn', 'ResetPass', 'hideFromGAL', 'RemoveGroups')) {
        if ($null -ne $OffboardingOptions.$option -and $OffboardingOptions.$option -isnot [bool]) {
            Write-Output 'Offboarding action flags must be JSON booleans'
            exit 1
        }
    }

    if ($UPN -isnot [string] -or $UPN -notmatch '^[^\s@]+@[^\s@]+$') {
        Write-Output 'A full user principal name is required'
        exit 1
    }

    $hideFromGAL = if ($null -ne $OffboardingOptions.hideFromGAL) { $OffboardingOptions.hideFromGAL } else { $false }
    $DisableSignIn = if ($null -ne $OffboardingOptions.DisableSignIn) { $OffboardingOptions.DisableSignIn } else { $false }
    $ResetPass = if ($null -ne $OffboardingOptions.ResetPass) { $OffboardingOptions.ResetPass } else { $false }
    $DeleteUser = if ($null -ne $OffboardingOptions.DeleteUser) { $OffboardingOptions.DeleteUser } else { $false }

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
        $candidates = @(Get-ADUser -Filter { UserPrincipalName -eq $UPN } -SearchBase $managedOu.DistinguishedName -SearchScope Subtree -Server $DirectoryServer -ErrorAction Stop)
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

    if ($DeleteUser) {
        try {
            Remove-ADUser -Server $DirectoryServer -Identity $adUser -Confirm:$false -ErrorAction Stop
            $results += "Deleted AD user '$UPN' successfully"
        } catch {
            Write-Output "Failed to delete AD user '$UPN': $($_.Exception.Message)"
            exit 1
        }
    } else {
        if ($DisableSignIn) {
            try {
                Disable-ADAccount -Server $DirectoryServer -Identity $adUser -ErrorAction Stop
                $results += "Disabled sign-in for '$UPN'"
            } catch {
                $results += "Failed to disable sign-in for '$UPN': $($_.Exception.Message)"
            }
        }

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

        if ($hideFromGAL) {
            try {
                Set-ADUser -Server $DirectoryServer -Identity $adUser -Replace @{msExchHideFromAddressLists = $true} -ErrorAction Stop
                $results += "Hid '$UPN' from Global Address List"
            } catch {
                $results += "Failed to hide '$UPN' from GAL: $($_.Exception.Message)"
            }
        }

        if ($results.Count -gt 0 -and @($results | Where-Object { $_ -like 'Failed to *' }).Count -eq 0) {
            $results += "Offboarded AD user '$UPN' successfully"
        } elseif ($results.Count -eq 0) {
            $results += "No offboarding actions performed for '$UPN'"
        }
    }

    Write-Output ($results -join "`n")
    if (@($results | Where-Object { $_ -like 'Failed to *' }).Count -gt 0) { exit 1 }
    exit 0
}