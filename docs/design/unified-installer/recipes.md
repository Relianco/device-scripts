# Unified installer recipe specimens

These JSON specimens use the [proposed contract](../../superpowers/specs/2026-11-02-unified-installer-design.md#contract-and-common-semantics). They are design inputs, not executable manifests or qualified production releases. No installer was run. A recipe revision is not a qualification claim. All three use minimum-version compliance and preserve newer versions; all exclude repair, reinstall, downgrade, scope migration, and rollback.

Intune publication additionally requires a qualified `ensureAbsent` capability, absent-state postconditions, and a real uninstall entrypoint. These ensure-present-only specimens are engine proof candidates; none is yet an Intune publication candidate. GSA also has the intermediate-reboot gate. A removal substep inside replacement does not qualify standalone uninstall.

The release builder must resolve primitives, OS floor, identity fixtures, release-input content, toolkit/brand pins, and approved profiles into a lock before publication. Null `minimumOsBuild` means unresolved and **blocks release**, not “any Windows.” `qualification` is build metadata with the only releasable value `passed`; these examples deliberately remain `pending`. Recipe IDs and policy names below are proposed, not existing commands. Each primitive must be reviewed engine source, never fetched/evaluated from its name.

## Global Secure Access: remove first

The unmerged [GSA proposal at db87fa6](https://github.com/Relianco/device-scripts/blob/db87fa6/windows/packages/global-secure-access/Invoke-GlobalSecureAccess.ps1#L1-L186) records version 2.34.222 and its SHA256, matches Microsoft bundle registration, rejects mixed old/current clients, validates cached uninstallers, and uses `/quiet /norestart`. It currently deletes temporary staging on exit, including intermediate reboot. This specimen proposes durable retention and re-entry; it does not claim the old script already provides them.

```json
{
  "schemaVersion": 1,
  "recipeRevision": 1,
  "engineCompatibility": { "major": 1 },
  "qualification": "pending",
  "application": { "id": "gsa", "channel": "stable", "vendor": "Microsoft Corporation", "architecture": "x64" },
  "capabilities": ["ensurePresent"],
  "context": { "executionIdentity": "system", "installationScope": "machine", "notificationAudience": "eligibleSession" },
  "applicability": { "os": "windows", "minimumOsBuild": null, "architectures": ["x64"], "enrollmentSafe": false, "prerequisites": [] },
  "desiredState": { "presence": "present", "targetVersion": "2.34.222", "comparison": "minimum", "strategy": "removeFirst", "downgrade": "reject" },
  "discovery": { "primitive": "gsaBundleV1", "hive": "HKLM", "views": ["Registry64", "Registry32"], "identityEvidence": ["publisher", "bundleRegistration", "cachedBundle", "normalizedVersion"], "coexistence": "reject" },
  "payload": { "source": { "kind": "releaseInput", "name": "gsaInstaller" }, "sha256": "d274b91fea1b14c4fbb59391c38905dbaa64ce57ba7fa226fedf523e06205413", "fileType": "exe", "version": "2.34.222", "signer": "Microsoft Corporation" },
  "commands": {
    "install": { "primitive": "stagedExe", "arguments": ["/install", "/quiet", "/norestart"], "timeoutSeconds": 3600, "successCodes": [0], "rebootCodes": [3010, 1641] },
    "remove": { "primitive": "validatedGsaCachedBundle", "arguments": ["/uninstall", "/quiet", "/norestart"], "timeoutSeconds": 3600, "successCodes": [0], "rebootCodes": [3010, 1641] }
  },
  "parameters": { "contentSource": { "type": "enum", "values": ["packaged", "approvedCache"], "default": "packaged" } },
  "configuration": {},
  "secretReferences": [],
  "postconditions": { "primitive": "gsaReplacementV1", "require": ["oldBundlesAbsent", "targetBundlePresent", "versionSatisfied", "clientFilesPresent"] },
  "recovery": { "reentry": "explicit", "intermediateReboot": "possible", "offlineClosureRequired": true, "compensation": "none", "intuneIntermediateReboot": "blocked" },
  "interaction": { "processPolicy": "qualifiedAllowlist", "forceClose": false, "waitSeconds": 300, "deferral": "adapterPolicy", "deadlineAction": "block" }
}
```

There is no public source URL invented for the supplied GSA bytes. `approvedCache` means an adapter-configured safe content root; the caller supplies neither path nor digest. Build validation must prove removal's full vendor cache dependencies and replacement's offline requirements before accepting `offlineClosureRequired`. Microsoft documents [quiet installation and administrator requirements](https://learn.microsoft.com/en-us/entra/global-secure-access/how-to-install-windows-client); neither establishes reboot recovery for this engine. VM proof must include old bundle chains, network loss, absent/damaged cache, 3010/1641, abrupt restart, and unavailable original download source after removal. Intune qualification excludes this replacement until intermediate continuation has an owner and evidence.

## 7-Zip: machine MSI in place

The [repository release pin](../../../windows/releases/7-zip.json#L1-L9) specifies x64 MSI 26.04.00.0, URL, and hash. The existing [normalizer](../../../windows/packages/7-zip/Invoke-7Zip.ps1#L21-L46) treats 26.04 and 26.04.00.0 alike. This is evidence of intended policy, not proof that every MSI product identity supports in-place upgrade.

```json
{
  "schemaVersion": 1,
  "recipeRevision": 1,
  "engineCompatibility": { "major": 1 },
  "qualification": "pending",
  "application": { "id": "7zip", "channel": "stable", "vendor": "Igor Pavlov", "architecture": "x64" },
  "capabilities": ["ensurePresent"],
  "context": { "executionIdentity": "system", "installationScope": "machine", "notificationAudience": "eligibleSession" },
  "applicability": { "os": "windows", "minimumOsBuild": null, "architectures": ["x64"], "enrollmentSafe": false, "prerequisites": [] },
  "desiredState": { "presence": "present", "targetVersion": "26.04.00.0", "comparison": "minimum", "strategy": "inPlace", "downgrade": "reject" },
  "discovery": { "primitive": "sevenZipMsiV1", "hive": "HKLM", "views": ["Registry64", "Registry32"], "identityEvidence": ["qualifiedMsiIdentity", "publisher", "normalizedVersion", "binaryArchitecture"], "coexistence": "reject" },
  "payload": { "source": { "kind": "https", "url": "https://github.com/ip7z/7zip/releases/download/26.04/7z2604-x64.msi" }, "sha256": "0b01334a418654293513449f61d6bfc99e5196ca371e3c3dc961eda57cd535c6", "fileType": "msi", "version": "26.04.00.0", "signer": null },
  "commands": {
    "install": { "primitive": "machineMsiInstall", "properties": { "ALLUSERS": "1", "REBOOT": "ReallySuppress" }, "ui": "quiet", "timeoutSeconds": 1800, "successCodes": [0], "rebootCodes": [3010, 1641] }
  },
  "parameters": {},
  "configuration": {},
  "secretReferences": [],
  "postconditions": { "primitive": "sevenZipInstalledV1", "require": ["qualifiedMsiIdentity", "machineScope", "versionSatisfied", "binaryArchitecture"] },
  "recovery": { "reentry": "explicit", "intermediateReboot": "none", "offlineClosureRequired": false, "compensation": "none", "intuneIntermediateReboot": "blocked" },
  "interaction": { "processPolicy": "qualifiedAllowlist", "forceClose": false, "waitSeconds": 300, "deferral": "adapterPolicy", "deadlineAction": "block" }
}
```

`machineMsiInstall` owns typed properties, quiet execution, and verified ProductCode/UpgradeCode handling; it is not a string passed unchecked to a shell. A null signer expresses no signer requirement, not permission to omit hash validation. The [vendor FAQ](https://www.7-zip.org/faq.html) documents silent MSI usage. VM qualification must prove machine scope, older-version upgrade, same-ProductCode behavior under the selected PSADT primitive, newer-version preservation, and stale/missing registration or executable handling. The runtime and detector must agree when DisplayVersion is missing; neither may silently accept evidence the other rejects.

## VS Code User Setup: native standard user

Microsoft documents that [User Setup needs no administrator rights](https://code.visualstudio.com/docs/setup/windows) and installs beneath `%LOCALAPPDATA%\Programs\Microsoft VS Code`. Official update metadata observed on 2026-11-02 supplied version 1.144.1, commit and SHA256 below. Its [source version](https://github.com/microsoft/vscode/blob/261c84cb1eddf11235f9e2c921425e9663fbe556/package.json#L3) agrees. The [moving metadata endpoint](https://update.code.visualstudio.com/api/update/win32-x64-user/stable/latest) is evidence-discovery only; release builds must retain its response and verify actual bytes/signature.

```json
{
  "schemaVersion": 1,
  "recipeRevision": 1,
  "engineCompatibility": { "major": 1 },
  "qualification": "pending",
  "application": { "id": "vscode-user", "channel": "stable", "vendor": "Microsoft Corporation", "architecture": "x64" },
  "capabilities": ["ensurePresent"],
  "context": { "executionIdentity": "owningUser", "installationScope": "user", "notificationAudience": "eligibleSession" },
  "applicability": { "os": "windows", "minimumOsBuild": null, "architectures": ["x64"], "enrollmentSafe": false, "prerequisites": [] },
  "desiredState": { "presence": "present", "targetVersion": "1.144.1", "comparison": "minimum", "strategy": "inPlace", "downgrade": "reject" },
  "discovery": { "primitive": "vscodeOwningUserV1", "hive": "HKCU", "views": ["Registry64", "Registry32"], "identityEvidence": ["qualifiedCommercialIdentity", "owningUserRoot", "executableVersion", "binaryArchitecture"], "coexistence": "reject" },
  "payload": { "source": { "kind": "https", "url": "https://vscode.download.prss.microsoft.com/dbazure/download/stable/261c84cb1eddf11235f9e2c921425e9663fbe556/VSCodeUserSetup-x64-1.144.1.exe" }, "sha256": "14f02cb5bce31cc9cff94712b17a6dfc811895c1cfc77ffba4ab78d3528b40c6", "fileType": "exe", "version": "1.144.1", "signer": "Microsoft Corporation" },
  "commands": {
    "install": { "primitive": "stagedExe", "arguments": ["/VERYSILENT", "/SUPPRESSMSGBOXES", "/SP-", "/NORESTART", "/RESTARTEXITCODE=3010", "/NOCLOSEAPPLICATIONS", "/NORESTARTAPPLICATIONS"], "timeoutSeconds": 1800, "successCodes": [0], "rebootCodes": [3010] }
  },
  "parameters": {},
  "configuration": {},
  "secretReferences": [],
  "postconditions": { "primitive": "vscodeUserInstalledV1", "require": ["owningUserRegistration", "owningUserRoot", "versionSatisfied", "binaryArchitecture"] },
  "recovery": { "reentry": "explicit", "intermediateReboot": "none", "offlineClosureRequired": false, "compensation": "none", "intuneIntermediateReboot": "blocked" },
  "interaction": { "processPolicy": "qualifiedAllowlist", "forceClose": false, "waitSeconds": 300, "deferral": "adapterPolicy", "deadlineAction": "block" }
}
```

The pinned [installer source](https://github.com/microsoft/vscode/blob/261c84cb1eddf11235f9e2c921425e9663fbe556/build/win32/code.iss#L42) declares lowest privilege for User Setup. [Inno arguments](https://jrsoftware.org/ishelp/topic_setupcmdline.htm) justify the silent/restart switches; user scope comes from this artifact, not a hypothetical `/CURRENTUSER`. Explicit no-close/no-restart-application switches require runtime proof against VS Code's installer behavior.

Commercial ARP identity, binary version format, process allowlist, and architecture checks remain qualification inputs; Code OSS IDs cannot stand in for the commercial build. Another user's copy never satisfies this recipe. Machine-copy coexistence blocks the proposed v1 policy; it does not trigger cleanup. Preserve user data. A future uninstall capability must validate a registered uninstaller under the owning installation root and use separately qualified [uninstaller arguments](https://jrsoftware.org/ishelp/topic_uninstcmdline.htm), which do not document the installer's custom restart-exit switch. Uninstall is therefore intentionally absent here.

Across specimens, timeouts and process policy are proposed bounds pending measured VM evidence. `intermediateReboot: none` is a qualified expectation, not permission to ignore an unexpected reboot; unexpected interruption always enters reconciliation. The notification audience is an upper bound: Intune profiles reduce it to none and use provider notices. All release blockers must be resolved without changing these safety semantics implicitly.
