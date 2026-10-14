#Requires -Version 7.4
#Requires -Modules VMware.VimAutomation.Core

<#
.SYNOPSIS
    Exports every VM tag assignment from a vCenter Server to a CSV file.

.DESCRIPTION
    Connects to vCenter, reads the tag assignments of every VM, and writes one row per
    assignment with the columns VMName, TagCategory, and Tag. The rows are sorted by VM name,
    category, and tag so the file is easy to review and diff.

    The CSV is the input for Import-NutanixCategories.ps1, which recreates the tags as Prism
    Central categories after a Nutanix Move migration.

    Only VM tags are exported. Tags on hosts, datastores, folders, and other objects are
    ignored.

.PARAMETER VCenter
    Host name or IP address of the vCenter Server. Connect-VIServer prompts for credentials
    unless a stored credential or an existing session is available.

.PARAMETER Path
    Path of the CSV file to write. Defaults to ./vsphere-tags.csv in the current directory.

.EXAMPLE
    ./Export-VSphereTags.ps1 -VCenter vcenter01.lab.local

    Exports all VM tag assignments to ./vsphere-tags.csv.

.EXAMPLE
    ./Export-VSphereTags.ps1 -VCenter vcenter01.lab.local -Path ./exports/prod-tags.csv

    Exports all VM tag assignments to a custom path.

.INPUTS
    None.

.OUTPUTS
    None. The tag assignments are written to the CSV file named by -Path.

.NOTES
    Requires VCF PowerCLI 9.x or VMware PowerCLI 13.x. Both ship the
    VMware.VimAutomation.Core module.

.LINK
    https://rajpatel.co/?p=1549
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Progress messages are for the operator running the script interactively, not for the pipeline.')]
param(
    [Parameter(Mandatory)]
    [string]$VCenter,

    [string]$Path = './vsphere-tags.csv'
)

Connect-VIServer -Server $VCenter | Out-Null

Get-TagAssignment -Entity (Get-VM) |
    ForEach-Object {
        [pscustomobject]@{
            VMName      = $_.Entity.Name
            TagCategory = $_.Tag.Category.Name
            Tag         = $_.Tag.Name
        }
    } |
    Sort-Object -Property VMName, TagCategory, Tag |
    Export-Csv -Path $Path -NoTypeInformation

Disconnect-VIServer -Server $VCenter -Confirm:$false
Write-Host "Exported tag assignments to $Path"
