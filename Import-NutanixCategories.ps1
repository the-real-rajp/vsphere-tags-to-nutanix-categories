#Requires -Version 7.4

<#
.SYNOPSIS
    Recreates vSphere tags as Prism Central categories and associates them with migrated AHV VMs.

.DESCRIPTION
    Reads the CSV written by Export-VSphereTags.ps1 (columns VMName, TagCategory, Tag, and an
    optional TargetVMName) and, for every VM in it:

      1. Looks up the AHV VM by name through the vmm v4.0 API. A name that matches zero or
         several VMs is skipped, never guessed.
      2. Converts each tag category and tag into a category key and value that Prism Central
         accepts, and prepends -KeyPrefix to the key when one is given.
      3. Looks up each category and creates the missing ones through the prism v4.0 API.
         Results are cached, so every category is looked up and created at most once per run.
      4. Reads the VM's ETag and calls associate-categories with the unique category extIds,
         then waits for the resulting task to finish.

    A failure on one VM is written as a warning and does not stop the run. A summary is
    printed at the end, and the exit code is 1 when any VM failed.

    The API key is read from the NTNX_API_KEY environment variable. It is never accepted as a
    parameter and never written to the output.

    The script uses the v4.0 API paths on purpose. They exist from pc.2024.3 onward, which
    keeps the script working across mixed Prism Central versions during a migration.

.PARAMETER PrismCentral
    Host name or IP address of Prism Central. The script connects to port 9440.

.PARAMETER Path
    Path of the CSV file to import. Defaults to ./vsphere-tags.csv in the current directory.

.PARAMETER KeyPrefix
    Text prepended to every category key, for example 'vmw_'. Use it when a tag category has
    the same name as a Prism Central system category. The prefix is not applied to values.

.PARAMETER DryRun
    Reports what would happen without creating categories or changing VMs. Only GET requests
    are sent.

.PARAMETER SkipCertificateCheck
    Skips TLS certificate validation. Use it only against a lab Prism Central with a
    self-signed certificate.

.PARAMETER TaskTimeoutSeconds
    How long to wait for each associate-categories task to leave the QUEUED or RUNNING state
    before the VM is treated as failed. Defaults to 300.

.EXAMPLE
    $env:NTNX_API_KEY = '<api key>'
    ./Import-NutanixCategories.ps1 -PrismCentral pc01.lab.local -DryRun

    Shows which categories would be created and which VMs would be updated.

.EXAMPLE
    ./Import-NutanixCategories.ps1 -PrismCentral pc01.lab.local -Path ./vsphere-tags.csv -KeyPrefix 'vmw_'

    Imports the CSV and prefixes every category key with vmw_.

.INPUTS
    None. The CSV is read from -Path.

.OUTPUTS
    None. Progress goes to the host, problems go to the warning stream, and the exit code is 1
    when any VM failed.

.NOTES
    Requires PowerShell 7.4 or later and Prism Central pc.2024.3 or later. No Nutanix SDK is
    needed.

.LINK
    https://rajpatel.co/?p=1549
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Progress messages are for the operator running the script interactively, not for the pipeline.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'SkipCertificateCheck',
    Justification = 'Used by Invoke-Ntnx. The rule does not see parameters that are only read inside nested functions.')]
param(
    [Parameter(Mandatory)]
    [string]$PrismCentral,

    [string]$Path = './vsphere-tags.csv',

    [string]$KeyPrefix = '',

    [switch]$DryRun,

    [switch]$SkipCertificateCheck,

    [ValidateRange(1, 86400)]
    [int]$TaskTimeoutSeconds = 300
)

$ApiKey = $env:NTNX_API_KEY
if (-not $ApiKey) { throw 'Set $env:NTNX_API_KEY to a service account API key first.' }

$base         = "https://${PrismCentral}:9440/api"
$headers      = @{ 'X-ntnx-api-key' = $ApiKey; 'Accept' = 'application/json' }
$cache        = @{}                                          # "key|value" -> category extId
$renameWarned = @{}                                          # names already reported as renamed
$wouldCreate  = [System.Collections.Generic.List[string]]::new()   # dry run: "key:value" per missing category
$stats        = @{ Updated = 0; Skipped = 0; Failed = 0; CategoriesCreated = 0 }

# Sends one request to Prism Central and returns its data and ETag. HTTP errors are rethrown
# with the method, URI, status, and the Nutanix error body so the per-VM warning is useful.
function Invoke-Ntnx {
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [object]$Body,
        [string]$ETag
    )
    $h = $headers.Clone()
    if ($Method -ne 'Get') { $h['NTNX-Request-Id'] = [guid]::NewGuid().ToString() }
    if ($ETag) { $h['If-Match'] = $ETag }
    $params = @{
        Method                  = $Method
        Uri                     = $Uri
        Headers                 = $h
        ContentType             = 'application/json'
        ResponseHeadersVariable = 'responseHeaders'
        SkipCertificateCheck    = $SkipCertificateCheck
    }
    if ($Body) { $params.Body = $Body | ConvertTo-Json -Depth 5 }

    try {
        $response = Invoke-RestMethod @params
    }
    catch {
        $status  = $_.Exception.Response.StatusCode
        $message = if ($null -ne $status) {
            "$($Method.ToUpper()) $Uri returned HTTP $([int]$status) ($status)"
        }
        else {
            "$($Method.ToUpper()) $Uri failed: $($_.Exception.Message)"
        }
        if ($_.ErrorDetails.Message) { $message += ". Response body: $($_.ErrorDetails.Message)" }
        throw [System.InvalidOperationException]::new($message, $_.Exception)
    }

    $responseHeaderTable = Get-Variable -Name responseHeaders -ValueOnly -ErrorAction Ignore
    [pscustomobject]@{
        Data = $response.data
        ETag = $responseHeaderTable['ETag'] | Select-Object -First 1
    }
}

# Category keys and values: 64 characters at most, none of / , ! " # % ' ( ) * + : ; = ? \ | [ ] ^ &
# and no leading $. Forbidden characters become a single space, and the result is trimmed
# again after truncation so a name never ends in a space.
function ConvertTo-NtnxName {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)
    $clean = ($Name -replace '[/,!"#%''()*+:;=?\\|\[\]^&]', ' ' -replace '\s+', ' ').Trim().TrimStart('$').Trim()
    if ($clean.Length -gt 64) { $clean = $clean.Substring(0, 64).Trim() }
    if ($clean.Length -eq 0) { throw "'$Name' is empty after removing forbidden characters and cannot be used as a category name" }
    if ($clean -ne $Name -and -not $renameWarned.ContainsKey($Name)) {
        $renameWarned[$Name] = $true
        Write-Warning "Renamed '$Name' to '$clean'"
    }
    $clean
}

# Returns the extId of the category key:value, creating it when it does not exist. Results are
# cached for the run. In a dry run a placeholder is cached instead, so each missing category is
# reported once rather than once per VM.
function Get-NtnxCategoryId {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Value
    )
    $id = "${Key}|${Value}"
    if ($cache.ContainsKey($id)) { return $cache[$id] }

    $filter = [uri]::EscapeDataString("key eq '$Key' and value eq '$Value'")
    $found  = @((Invoke-Ntnx -Method Get -Uri "$base/prism/v4.0/config/categories?`$filter=$filter").Data | Where-Object { $_ })
    if ($found.Count -gt 0) {
        $cache[$id] = $found[0].extId
        return $cache[$id]
    }
    if ($DryRun) {
        Write-Host "Would create category ${Key}:${Value}"
        $wouldCreate.Add("${Key}:${Value}")
        $cache[$id] = "dry-run:${Key}:${Value}"
        return $cache[$id]
    }
    $body = @{ key = $Key; value = $Value; description = 'Imported from a vSphere tag' }
    $new  = Invoke-Ntnx -Method Post -Uri "$base/prism/v4.0/config/categories" -Body $body
    Write-Host "Created category ${Key}:${Value}"
    $stats.CategoriesCreated++
    $cache[$id] = $new.Data.extId
    return $cache[$id]
}

# Polls a task until it leaves QUEUED or RUNNING, or until the timeout. Returns the final status
# and throws when the task is still running at the deadline.
function Wait-NtnxTask {
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Seconds 2
        $task = (Invoke-Ntnx -Method Get -Uri "$base/prism/v4.0/config/tasks/$TaskId").Data
        if ($task.status -notin 'QUEUED', 'RUNNING') { return $task.status }
    } while ([datetime]::UtcNow -lt $deadline)
    throw "Task $TaskId is still $($task.status) after $TimeoutSeconds seconds, timed out"
}

$rows = @(Import-Csv -Path $Path)
if ($rows.Count -eq 0) { throw "No rows found in $Path" }

$columns = $rows[0].PSObject.Properties.Name
foreach ($required in 'VMName', 'TagCategory', 'Tag') {
    if ($columns -notcontains $required) { throw "$Path has no '$required' column. Expected the CSV written by Export-VSphereTags.ps1." }
}
$hasTargetColumn = $columns -contains 'TargetVMName'

foreach ($group in ($rows | Group-Object -Property VMName)) {
    $vmName = $group.Name
    $label  = $vmName

    # Optional TargetVMName column: look up the AHV VM by its new name when the VM was renamed.
    $lookupName = $vmName
    if ($hasTargetColumn) {
        $targets = @($group.Group.TargetVMName | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        if ($targets.Count -gt 1) {
            Write-Warning "${vmName}: rows disagree on TargetVMName ($($targets -join ', ')), skipped"
            $stats.Skipped++
            continue
        }
        if ($targets.Count -eq 1) {
            $lookupName = $targets[0].Trim()
            $label      = "$vmName (AHV name $lookupName)"
        }
    }

    try {
        $vmFilter = [uri]::EscapeDataString("name eq '$($lookupName -replace "'", "''")'")
        $vms      = @((Invoke-Ntnx -Method Get -Uri "$base/vmm/v4.0/ahv/config/vms?`$filter=$vmFilter").Data | Where-Object { $_ })
        if ($vms.Count -ne 1) {
            Write-Warning "${label}: found $($vms.Count) AHV VMs with this name, skipped"
            $stats.Skipped++
            continue
        }

        # Resolve every tag to a category extId. Two tags can clean to the same key:value, so
        # keep only unique extIds and say which tags collided.
        $categoryIds = [System.Collections.Generic.List[string]]::new()
        $seen        = @{}
        foreach ($row in $group.Group) {
            $key   = ConvertTo-NtnxName -Name "$KeyPrefix$($row.TagCategory)"
            $value = ConvertTo-NtnxName -Name $row.Tag
            $id    = Get-NtnxCategoryId -Key $key -Value $value
            $tag   = "$($row.TagCategory)/$($row.Tag)"
            if ($seen.ContainsKey($id)) {
                Write-Warning "${label}: tags '$($seen[$id])' and '$tag' both map to category ${key}:${value}, associating it once"
                continue
            }
            $seen[$id] = $tag
            $categoryIds.Add($id)
        }

        if ($DryRun) {
            Write-Host "Would associate $($categoryIds.Count) categories with $label"
            $stats.Updated++
            continue
        }

        $vmUri = "$base/vmm/v4.0/ahv/config/vms/$($vms[0].extId)"
        $vm    = Invoke-Ntnx -Method Get -Uri $vmUri
        if (-not $vm.ETag) { throw "GET $vmUri returned no ETag header" }

        $body   = @{ categories = @($categoryIds | ForEach-Object { @{ extId = $_ } }) }
        $result = Invoke-Ntnx -Method Post -Uri "$vmUri/`$actions/associate-categories" -Body $body -ETag $vm.ETag
        $taskId = $result.Data.extId
        $status = Wait-NtnxTask -TaskId $taskId -TimeoutSeconds $TaskTimeoutSeconds
        if ($status -ne 'SUCCEEDED') { throw "associate-categories task $taskId ended with status $status" }

        Write-Host "${label}: $($categoryIds.Count) categories, task $status"
        $stats.Updated++
    }
    catch {
        $stats.Failed++
        Write-Warning "${label}: failed. $($_.Exception.Message)"
    }
}

Write-Host ''
if ($DryRun) {
    Write-Host 'Dry run summary'
    Write-Host "  VMs that would be updated:  $($stats.Updated)"
    Write-Host "  VMs skipped:                $($stats.Skipped)"
    Write-Host "  VMs failed:                 $($stats.Failed)"
    Write-Host "  Categories to be created:   $($wouldCreate.Count)"
    foreach ($category in $wouldCreate) { Write-Host "    $category" }
}
else {
    Write-Host 'Summary'
    Write-Host "  VMs updated:        $($stats.Updated)"
    Write-Host "  VMs skipped:        $($stats.Skipped)"
    Write-Host "  VMs failed:         $($stats.Failed)"
    Write-Host "  Categories created: $($stats.CategoriesCreated)"
}

if ($stats.Failed -gt 0) { exit 1 }
exit 0
