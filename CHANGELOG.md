# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0.0] - 2026-10-14

First release. The scripts come from the blog post
[Moving vSphere Tags to Nutanix Categories with PowerShell and the v4 API](https://rajpatel.co/?p=1549)
with the fixes below. API usage is unchanged: prism v4.0 for categories and tasks, vmm v4.0 for VMs.

### Added

- Comment-based help and `[CmdletBinding()]` on both scripts, so `Get-Help` works.
- `-TaskTimeoutSeconds` (default 300) on `Import-NutanixCategories.ps1`. A task that is still
  `QUEUED` or `RUNNING` after the timeout marks the VM as failed and the run moves on.
- Optional `TargetVMName` column in the CSV. When it is filled in, the AHV VM is looked up by that
  name instead of `VMName`, for VMs renamed during the migration.
- A run summary: VMs updated, skipped, failed, and categories created. The exit code is 1 when
  any VM failed.
- Pester 5 tests for both scripts, using mocks only.
- GitHub Actions workflow that runs PSScriptAnalyzer and Pester.
- Sample CSV in `examples/`.

### Fixed

- A failure on one VM no longer stops the whole run. Each VM is handled in its own `try`/`catch`,
  and the warning includes the HTTP status and the Nutanix error body when available.
- Two tags that clean to the same category (for example `App/Web` and `App Web`) are now sent to
  `associate-categories` once, with a warning naming the collision.
- `-DryRun` caches would-be categories, so "Would create category" is printed once per category
  instead of once per VM, and the summary lists each one exactly once.
- Any task status other than `SUCCEEDED` is treated as a failure and reported.
- Category names are trimmed again after being cut to 64 characters, so a name never ends in a
  space.
- A category name that is empty after cleanup fails that VM with a clear message instead of
  reaching the API.
