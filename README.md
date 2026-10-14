# vSphere tags to Nutanix categories

[![CI](https://github.com/the-real-rajp/vsphere-tags-to-nutanix-categories/actions/workflows/ci.yml/badge.svg)](https://github.com/the-real-rajp/vsphere-tags-to-nutanix-categories/actions/workflows/ci.yml)

Nutanix Move migrates VMs from vSphere to AHV, but it does not carry over their vCenter tags.
These two PowerShell scripts rebuild the tags as Prism Central categories after cutover:
`Export-VSphereTags.ps1` writes every VM tag assignment in vCenter to a CSV, and
`Import-NutanixCategories.ps1` reads that CSV, creates the matching categories in Prism Central
through the v4 REST API, and associates them with the migrated VMs.

The scripts are explained in the blog post
[Moving vSphere Tags to Nutanix Categories with PowerShell and the v4 API](https://rajpatel.co/?p=1549).
This repository is the canonical copy.

## Requirements

- Prism Central pc.2024.3 or later. The import script uses the v4.0 API paths (`prism/v4.0` for
  categories and tasks, `vmm/v4.0` for VMs), which exist from pc.2024.3 onward and keep working on
  later releases.
- PowerShell 7.4 or later.
- VCF PowerCLI 9.x or VMware PowerCLI 13.x, for the export only. Both ship the
  `VMware.VimAutomation.Core` module the export script requires.
- A Prism Central service account with an API key, scoped to create categories and update VMs.

No Nutanix SDK is needed. Pester and PSScriptAnalyzer are used for development and CI only.

## Usage

### 1. Export the tags from vCenter

```powershell
./Export-VSphereTags.ps1 -VCenter vcenter01.lab.local -Path ./vsphere-tags.csv
```

Connect-VIServer prompts for credentials unless you already have a session or a stored
credential. The script writes one row per tag assignment with the columns `VMName`,
`TagCategory`, and `Tag`, sorted by VM name, category, and tag. Only VM tags are exported.

### 2. Review the CSV

Open the CSV and check that it has what you expect. Delete rows you do not want in Prism Central.

If a VM was renamed during the migration, add a `TargetVMName` column and fill in the new AHV
name on that VM's rows. The import script then looks the VM up by that name. Leave the column
empty for VMs that kept their name. See [`examples/vsphere-tags.sample.csv`](examples/vsphere-tags.sample.csv).

### 3. Dry run against Prism Central

```powershell
$env:NTNX_API_KEY = '<api key of the service account>'
./Import-NutanixCategories.ps1 -PrismCentral pc01.lab.local -Path ./vsphere-tags.csv -DryRun
```

A dry run sends only GET requests. It reports which VMs it found, which categories it would create
(each one once), and how many categories it would associate with each VM. Nothing is changed.

### 4. Import

```powershell
./Import-NutanixCategories.ps1 -PrismCentral pc01.lab.local -Path ./vsphere-tags.csv
```

For every VM in the CSV the script looks up the AHV VM by name, looks up or creates each category,
reads the VM's ETag, calls `associate-categories` with the unique category IDs, and waits for the
task to finish. A failure on one VM is written as a warning and the script moves on to the next VM.
The run ends with a summary of VMs updated, skipped, and failed, and categories created. The exit
code is 1 when any VM failed, so the script can be rerun after fixing the cause. Rerunning is safe
for the categories, which are looked up before they are created.

Parameters of the import script:

| Parameter | Default | Purpose |
| --- | --- | --- |
| `-PrismCentral` | required | Host name or IP of Prism Central (port 9440) |
| `-Path` | `./vsphere-tags.csv` | CSV to import |
| `-KeyPrefix` | none | Text prepended to every category key, see below |
| `-DryRun` | off | Report only, send no POST requests |
| `-SkipCertificateCheck` | off | Skip TLS validation, labs only |
| `-TaskTimeoutSeconds` | `300` | How long to wait for each `associate-categories` task |

Both scripts have comment-based help: `Get-Help ./Import-NutanixCategories.ps1 -Full`.

## Naming rules

Prism Central is stricter about category names than vCenter is about tag names. The import script
converts every tag category to a category key and every tag to a category value as follows.

- **64 characters at most.** Longer names are cut to 64 characters and trimmed, so a name never
  ends in a space.
- **Forbidden characters.** Each of `/ , ! " # % ' ( ) * + : ; = ? \ | [ ] ^ &` becomes a space,
  and runs of whitespace collapse to one space. `App/Web` becomes `App Web`.
- **No leading `$`.** A leading `$` is removed. `$Owner` becomes `Owner`.
- Every rename is reported with a warning, once per name. A name that is empty after cleanup fails
  that VM.
- **Collisions.** Two tags can clean to the same key and value, for example `App/Web` and
  `App Web`. The category is associated with the VM once and a warning names both tags.
- **Cardinality.** vSphere tag categories can allow one tag or many tags per object. Prism Central
  categories have no such setting: a VM can carry several values of the same key. The script does
  not enforce the vSphere cardinality, it recreates the assignments as they were.
- **System categories.** Prism Central ships system categories such as `Environment` or
  `AppType`. If a vCenter tag category has the same name as one of them, use `-KeyPrefix` (for
  example `-KeyPrefix 'vmw_'`) to keep the imported categories separate. The prefix is applied to
  keys only, never to values.

## Limitations

- Only VM tags are exported. Tags on hosts, datastores, folders, and other objects are ignored.
- The import must run after cutover, once the VMs exist in Prism Central under the names in the
  CSV (or in `TargetVMName`). A name that matches zero or several AHV VMs is skipped, never
  guessed.
- What Prism Central does when a category is associated with a VM that already has it is not
  verified (it may be a no-op or an error). The script survives either: an error marks that VM as
  failed and the run continues.
- The scripts have not yet been run against a live vCenter or Prism Central. The tests use mocks
  only. Run a dry run first and review its output before importing.

## Security

- The API key is read from the `NTNX_API_KEY` environment variable only. It is never accepted as a
  parameter, never written to the output, and must never be committed.
- `-SkipCertificateCheck` disables TLS certificate validation. Use it only against a lab Prism
  Central with a self-signed certificate.

## Development

```powershell
Install-Module Pester -MinimumVersion 5.5 -MaximumVersion 5.99.99 -Scope CurrentUser
Install-Module PSScriptAnalyzer -Scope CurrentUser

Invoke-ScriptAnalyzer -Path . -Recurse
Invoke-Pester -Path ./tests
```

CI runs both on every push and pull request. See [CHANGELOG.md](CHANGELOG.md) for what changed
compared with the scripts in the blog post.

## License

[MIT](LICENSE)
