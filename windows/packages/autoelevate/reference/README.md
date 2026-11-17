# Hung AutoElevate service recovery reference

This records a manual recovery of an older agent that reported `Running` but
rejected SCM stop requests with error 1061. The normal package correctly refused
to run MSI while its service could not stop. Repeating the installer could not
resolve that condition. Recovery stopped the verified hung process safely, then
let the existing package upgrade and register the agent.

This directory is **not a deployment entry point**. It has no release manifest,
runner integration, or automatic process termination. [ServiceRecovery.ps1](ServiceRecovery.ps1)
preserves the reusable SCM snapshot/restore code and identity guards used during
the recovery. Loading it only defines types and functions. Calling
`[AeRecovery]::Write()` changes Windows service configuration and requires an
explicitly authorized, individually reviewed maintenance operation as SYSTEM.

Use the [normal package](../Invoke-AutoElevate.ps1) and
[package runbook](../../../../docs/autoelevate.md) first. This reference does not
replace the package's installer verification, planning, version detection,
registration, reporting, or reboot policy.

## Sequence used

1. Establish that the service really is stuck: capture service state, PID, binary
   path/version/hash/signature, the normal stop error and service recovery
   configuration. A `REBOOT_MESSAGE` label in `sc qfailure` output is not evidence
   of a reboot action; inspect the actual failure actions.
2. Verify the agent PID and both the service and process paths against the
   expected installed `AutoElevateAgent.exe`. Validate its Authenticode signature
   and vendor identity separately. The supplied identity helper checks PID/path
   equality only; it does not verify a publisher or decide whether killing a
   process is safe.
3. Download and hash-verify the package and any wrapper before changing services.
   Validate the version pin and registration metadata. Reuse the existing local
   registry license through the child process environment variable
   `AE_LICENSE_KEY`. Never put it in runner arguments, shell command text, logs,
   snapshots, or this repository. Clear the temporary environment value in a
   `finally` block. Missing or unverified registration data is a stop condition.
4. Snapshot failure actions, reset period, message, command, noncrash flag,
   startup mode and state for `AutoElevateAgent` and, if present,
   `AEDelayedStartService`. Refuse an active delayed-start service or recovery
   actions other than none/restart. This recipe does not handle reboot or custom
   command recovery actions.
5. Persist the original nonsecret snapshot before mutation in a random directory
   under Windows `SystemTemp`. Protect its ACL from inheritance; allow only
   SYSTEM and Administrators. Verify permissions and exact file readback. Keep
   it until restoration is verified; it is needed if the controlling process
   dies before `finally` runs.
6. Clear failure actions and the noncrash flag on both services; disable startup.
   Read back and prove both changes. With `SERVICE_FAILURE_ACTIONS`, zero actions
   requires a **nonnull** action buffer: a null pointer means leave actions
   unchanged. The helper deliberately allocates a buffer even for zero actions.
7. Attempt a normal stop again. Only if still stuck, reread the service and
   process: require the original PID, expected paths, unchanged binary hash and
   valid signature, plus recovery still cleared and startup still disabled.
   Then terminate only that exact agent PID. Bound the wait for `Stopped` and
   abort on a changed PID or any failed check. No reboot was used.
8. Restore **both** original startup modes before running MSI; keeping the
   delayed-start service disabled can break MSI's StartServices action. Keep
   failure recovery cleared during installation.
9. Invoke the existing package once with outer runner `Action=Repair` and child
   `DeploymentType=Repair`, `Action=Repair`. Do not use outer `Reinstall`: the
   runner expands it into Uninstall then Install. The package also rejects a
   direct child Reinstall. For the qualified older-to-pinned-version case,
   Repair plans an install/upgrade and supplies registration properties.
10. In `finally`, restore the exact original recovery settings and startup modes
    for both services, verify readback, and start the agent if originally
    running. Restoration failure is an overall failure even when MSI succeeds.
    Restoring `SC_ACTION_RESTART` requires `SERVICE_START` (0x10) in addition to
    `SERVICE_CHANGE_CONFIG` (0x02); the helper requests access 18 for this case.

The qualified recovery was from 2.8.2 to 2.11.1959. Requalify the plan, process
identity and vendor behavior for other versions; do not turn this recipe into a
fleet-wide kill/reinstall loop. It intentionally avoids vendor uninstall scripts
that also delete files or registry registration data.

## Evidence required after recovery

Check MSI result, installed version, running service, restored service settings,
local registration and the user-session helper processes. Then verify a fresh
portal record/heartbeat and an actual elevation event. Installer success alone
is insufficient to claim that elevation works. Elevation also does not establish
that an application's per-user prerequisite registration was repaired; verify
that separately in the initiating user's profile.

## Tests and limits

`tests/windows/autoelevate-recovery-reference.Tests.ps1` compiles the native helper
and tests recovery-access selection, clear-state guards and PID/path refusal
without invoking SCM, downloading files or installing anything. Existing package
plan/upgrade tests cover the normal Repair route. These tests do not simulate
Windows SCM, ACL persistence, MSI or process termination end to end. The reference
is deliberately missing an automatic orchestration entry point; the reviewed
sequence above remains necessary when reusing its building blocks.

Native API references:

- [ChangeServiceConfig2 access requirements](https://learn.microsoft.com/en-us/windows/win32/api/winsvc/nf-winsvc-changeserviceconfig2w)
- [SERVICE_FAILURE_ACTIONS pointer semantics](https://learn.microsoft.com/en-us/windows/win32/api/winsvc/ns-winsvc-service_failure_actionsw)
