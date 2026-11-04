# Maintenance review and validation

Implementation: `8ecc515e557ae3093592addbad886d6d2a1ef340` on `lane/maintenance`, based on main `ef12f6743d24a00de53bd741b036d96bd3d4dec4`. Pull request: [90](https://github.com/Relianco/device-scripts/pull/90).

Separate implementation and review agents used the requested gpt-6.1-sol model. Independent task reviews and a whole-branch review completed. All blocking findings were fixed and re-reviewed: cleanup ancestor validation; Setup transitions during scans; profile size completeness; bounded profile evidence and final deletion vetoes; native completion/output lifetime; bounded nonrecursive service control; historical upgrade residue; report-directory ownership; bounded update events; malformed staged state; and useful bounded stdout.

Profile age uses validated UTC ProfileList load/unload evidence. NTUSER modification alone does not reset registry-derived age. Recent CIM contradictions or positive interactive evidence protect a profile; invalid/incomplete collection requires review. The configurable default is 60 days, but removal remains explicitly opt-in. These are profile-age estimates with provenance, not a claim of perfect interactive-login history.

The full repository PowerShell suite passed at integrated commit `3fe7a7d`. After the final patch, both affected suites, PowerShell parsing, release JSON validation, secret scanning and the documented pinned argument construction passed. Remote GitHub package blobs were compared with local SHA256 before report pilots.

Windows-only native parent-exit/file-handle and NTFS ACL regression tests are included but were not executed on the Linux development host. Source review and C# compilation do not establish Windows runtime behavior. Optional live servicing and profile deletion require qualification after the active upgrade; no destructive-path validation is claimed by a report-only pilot. External RMM job-object termination behavior is not established.

Review decisions: keep the packages report-first; defer mutations during active/staged/unknown servicing; preserve management policy and rollback assets; use separate work lanes with a fixed shared lock/marker contract; and expose uncertain profile evidence for review. The main tradeoff is retained data or deferred work when safety evidence is incomplete.

## Report pilots

Both authorized Windows laptops ran storage Report with 60-day profile retention configured and removal disabled. The owned report directory initially failed validation under a pre-existing shared parent; a reviewed fix isolated both packages under `%ProgramData%\RelianMaintenance`, retaining legacy markers as read-only safety inputs. Retry reports succeeded, displayed PSADT progress according to toolkit logs, reported approximately 47 and 58 GiB free, and withheld profile/recursive scans and cleanup because Setup was active. No cleanup actions occurred.

Updater Report pilots exposed a typed-null `File.Replace` checkpoint bug and a hashtable-count artifact for an unrequested scan. Real repeated-write and actual passive-report regressions reproduced both; the reviewed fix passed. Both retries returned expected `deferred` status with empty actions/errors, no requested scan, an unset scan count and notifications reported shown. Ninja displays deferred exit 2 as a failed action; the structured result distinguishes intentional deferral from an execution error.

The existing OS editions/releases were identified as out of support. This does not establish the cause of a missing feature offer or prove the update engine is damaged. No servicing, update-cache reset, service mutation, profile deletion or reboot was exercised during the USB upgrades. Visual appearance was not independently captured; toolkit logs and notification outcomes confirm the UI path executed.

The storage pilot used commit `ee46fcf`; its package is unchanged at `8ecc515`, which was used for the successful updater retry. Device identifiers, full report paths and raw evidence remain in ignored local memory. Post-upgrade full triage, candidate review and harmless Windows native/ACL regression execution remain the next qualification steps before optional destructive or servicing actions.
