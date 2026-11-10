# Unity Accounting / esiLaw prompt repairs

Use these references when esiLaw repeatedly requests administrator approval
for `UnityAccountingEventLog.exe` or an installer published by **SAP SE**.
The prompts can have separate causes. Identify the executable and its trigger
before choosing a repair.

These findings came from esiLaw 5.5.5.1 and Crystal Reports runtime
13.0.24.2970 (32-bit). Recheck the application behavior for other versions.
The scripts contain no customer configuration or credentials.

## Start with evidence

[`Get-UnityPromptEvidence.ps1`](Get-UnityPromptEvidence.ps1) reports the
custom event log, source binding, SAP user registration, and runtime evidence.
Supply the affected console user's exact account and SID. Run elevated so
the script can inspect the loaded user hive. Entra accounts can have
`S-1-12-1` SIDs; do not assume every user SID starts with `S-1-5-21`.

Use the existing
[`Invoke-MsiRepair.ps1`](../msi-repair/Invoke-MsiRepair.ps1) with
`Section=Evidence` and the product code below for installer events.
Evidence mode does not run a repair. An MSI exit code of zero proves that
transaction succeeded; it does not prove the next application launch is fixed.

Capture the prompt's executable path, publisher, hash, parent process, and
command line. Preserve reports privately: they can contain account names,
user paths, and installed software details.

## UnityAccountingEventLog.exe: the custom log is missing

The inspected application calls `EventLog.Exists("UnityAccounting")`.
When the **log** is missing, it starts the helper with the `runas` verb.
The helper creates both a log and a source named `UnityAccounting`.
Registering that source under `Application` does not satisfy the log check.

Use the existing
[`Invoke-EventlogSource.ps1`](../eventlog-source/Invoke-EventlogSource.ps1).
Inspect before changing anything:

```powershell
$package = '../eventlog-source/Invoke-EventlogSource.ps1'
& $package -Action Install -PinVersion '1.0.0' `
    -Section Evidence -Source UnityAccounting `
    -LogName UnityAccounting
```

Commands in this section assume your working directory is this folder.
For managed delivery, use the hash-pinned runner and pass these arguments
through its base64 JSON `PackageArguments`.

If the source is under `Application`, remove it only when this package owns
that registration. The package checks its ownership marker and refuses
unowned sources:

```powershell
& $package -Action Uninstall -PinVersion '1.0.0' `
    -Source UnityAccounting -LogName Application
```

Then create the expected pair:

```powershell
& $package -Action Install -PinVersion '1.0.0' `
    -Source UnityAccounting -LogName UnityAccounting `
    -CreateLog true
```

Read back both log existence and source binding. If ownership is unknown,
investigate the existing source instead of deleting registry keys manually.
The package never deletes a log. Removing its owned source is the supported
undo operation; the custom log and its records remain.

## SAP SE: the application's user-registration check fails

The observed application explicitly launched `msiexec /i` with
`CR_RT_32b_13024.msi /passive`. Its prerequisite check looked for a populated
`HKCU\Software\SAP BusinessObjects` tree. Runtime files were installed, but
the affected user's registration was absent.

The source MSI defines this literal value:

- Key: `SOFTWARE\SAP BusinessObjects\Crystal Reports for .NET Framework 4.0\Installer`
- Name: `BusinessObjects`
- Type and data: `REG_SZ`, string `1`
- Product: `{817393F4-AAE9-4217-B3BF-C94D79D20F6B}`
- Version: `13.0.24.2970`
- Source SHA256:
  `116283c08b3d6693e7d91b8d1165e373f67dffcb2945189642f2195428bc2ecd`

The MSI component uses a machine registry value as its key path, which
Windows Installer uses to detect the component. That value can exist while
the user value is missing. A successful machine repair therefore does not
establish that the affected user's prerequisite check will pass.

[`Invoke-UnityCrystalRegistration.ps1`](Invoke-UnityCrystalRegistration.ps1)
preserves the guarded repair used for this case. It reads the user's cached
source MSI, verifies its hash and SAP signature, checks the vendor-authored
row and installed runtime, and targets the explicitly named loaded user hive.
It never runs the MSI or changes application validation flags.

Start in `Report` mode. Replace the placeholders with independently verified
identity values; the script refuses a different console user:

```powershell
$arguments = @{
    DeploymentType = 'Install'
    Action = 'Install'
    PinVersion = '1.0.0'
    ExpectedSid = '<affected-user-SID>'
    ExpectedAccount = '<domain-or-authority>\<account>'
    Mode = 'Report'
}
& ./Invoke-UnityCrystalRegistration.ps1 @arguments
```

After reviewing the evidence, set `Mode` to `Apply` for an authorized repair.
The script backs up the prior value state before adding the absent string.
It refuses an existing conflicting value and checks both registry views.
A different source MSI or runtime version requires a new investigation;
do not replace the pinned hash merely to bypass a refusal.

Keep the returned backup path with your private incident record. To undo a
confirmed write, review that backup and remove only the added value from
the same user hive, after checking that it still matches the recorded value.
There is no automatic rollback command. Do not delete the SAP tree: the
backup records the leaf state, not ownership of its ancestors.

## Verify the result

1. Read back the custom log/source pair and the SAP string in both views.
2. Ask the affected user to reopen the application normally.
3. Check whether both prompts are gone and the application opens correctly.
4. If a prompt remains, capture its exact executable and process ancestry.

The original repair established registry readback. A prompt-free launch after
the final user-registration change remained unconfirmed at documentation time.
Keep that distinction in future incident notes.

AutoElevate installation and hung-service recovery belong to the separate
[AutoElevate runbook](../../../docs/autoelevate.md). An elevation rule can
handle a request while the application's underlying prerequisite check
still needs repair. Avoid broad publisher or generic `msiexec.exe` rules.
