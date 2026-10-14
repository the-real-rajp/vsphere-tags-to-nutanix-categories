#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Tests for Import-NutanixCategories.ps1.

    Invoke-RestMethod is mocked with a small in-memory model of Prism Central: a list of AHV VMs,
    a list of categories, and a task status. No test talks to a real Prism Central.

    The real Invoke-RestMethod writes the response headers into the variable named by
    -ResponseHeadersVariable in the caller's scope. The mock cannot reach that scope, so it sets
    a global variable with the same name instead. The script reads the variable with
    Get-Variable, which finds the global one when no local one exists.
#>

BeforeAll {
    $script:importScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'Import-NutanixCategories.ps1'
    $script:pc           = 'pc01.lab.local'
    $script:apiBase      = "https://${script:pc}:9440/api"
    $script:savedApiKey  = $env:NTNX_API_KEY
    $env:NTNX_API_KEY    = 'test-api-key'

    # Writes CSV rows to a file under TestDrive and returns its path.
    function Write-TagCsv {
        param([Parameter(Mandatory)][object[]]$Rows, [string]$Name = 'tags.csv')
        $csvPath = Join-Path $TestDrive $Name
        $Rows | Export-Csv -Path $csvPath -NoTypeInformation
        $csvPath
    }

    # Runs the import script with the standard arguments and returns the exit code.
    function Invoke-Import {
        param([Parameter(Mandatory)][string]$CsvPath, [hashtable]$Extra = @{})
        $null = & $script:importScript -PrismCentral $script:pc -Path $CsvPath @Extra
        $LASTEXITCODE
    }

    # Decodes the $filter value of a request URI.
    function Get-FilterValue {
        param([Parameter(Mandatory)][string]$Uri)
        [uri]::UnescapeDataString(($Uri -split '\$filter=', 2)[1])
    }

    # Builds the error record Invoke-RestMethod produces for an HTTP error response.
    function Get-HttpErrorRecord {
        param([int]$StatusCode, [string]$ResponseBody, [string]$Uri)
        $response  = [System.Net.Http.HttpResponseMessage]::new($StatusCode)
        $exception = [Microsoft.PowerShell.Commands.HttpResponseException]::new(
            "Response status code does not indicate success: $StatusCode ($($response.ReasonPhrase)).", $response)
        $record = [System.Management.Automation.ErrorRecord]::new($exception, 'WebCmdletWebResponseException', 'InvalidOperation', $Uri)
        $record.ErrorDetails = [System.Management.Automation.ErrorDetails]::new($ResponseBody)
        $record
    }
}

AfterAll {
    $env:NTNX_API_KEY = $script:savedApiKey
    Remove-Variable -Name responseHeaders -Scope Global -ErrorAction Ignore
}

Describe 'Import-NutanixCategories.ps1' {
    BeforeEach {
        # Fresh model of Prism Central for every test. Plain (not $script:) because mock bodies
        # resolve $script: against the script under test when it is the caller.
        $mockNtnx = @{
            Vms              = [System.Collections.Generic.List[object]]::new()   # @{ Name; ExtId; ETag }
            Categories       = [System.Collections.Generic.List[object]]::new()   # @{ Key; Value; ExtId }
            TaskStatus       = 'SUCCEEDED'
            FailAssociateFor = @()                                                # VM extIds whose associate call returns HTTP 409
            Calls            = [System.Collections.Generic.List[object]]::new()   # every request, in order
        }

        Mock Write-Host {}
        Mock Write-Warning {}
        Mock Start-Sleep {}

        Mock Invoke-RestMethod {
            $mockNtnx.Calls.Add([pscustomobject]@{
                    Method  = "$Method"
                    Uri     = $Uri.OriginalString      # the exact string the script sent, still percent-encoded
                    Headers = $Headers.Clone()
                    Body    = $Body
                })
            if ($ResponseHeadersVariable) { Set-Variable -Scope Global -Name $ResponseHeadersVariable -Value @{} }
            $decoded = [uri]::UnescapeDataString($Uri.OriginalString)

            switch -Regex ($decoded) {
                '/vmm/v4\.0/ahv/config/vms\?\$filter=name eq ''(.*)''$' {
                    $name = $Matches[1] -replace "''", "'"
                    $hits = @($mockNtnx.Vms | Where-Object { $_.Name -eq $name })
                    if ($hits.Count -eq 0) { return @{ data = $null } }
                    return @{ data = @($hits | ForEach-Object { @{ extId = $_.ExtId; name = $_.Name } }) }
                }
                '/vmm/v4\.0/ahv/config/vms/([^/?]+)$' {
                    $vm = $mockNtnx.Vms | Where-Object { $_.ExtId -eq $Matches[1] } | Select-Object -First 1
                    if ($ResponseHeadersVariable) { Set-Variable -Scope Global -Name $ResponseHeadersVariable -Value @{ ETag = @($vm.ETag) } }
                    return @{ data = @{ extId = $vm.ExtId; name = $vm.Name } }
                }
                '/vmm/v4\.0/ahv/config/vms/([^/]+)/\$actions/associate-categories$' {
                    $vmId = $Matches[1]
                    if ($mockNtnx.FailAssociateFor -contains $vmId) {
                        throw (Get-HttpErrorRecord -StatusCode 409 -Uri $Uri -ResponseBody '{"data":{"error":"category already associated"}}')
                    }
                    return @{ data = @{ extId = "task-$vmId" } }
                }
                '/prism/v4\.0/config/categories\?\$filter=key eq ''(.*)'' and value eq ''(.*)''$' {
                    $key, $value = $Matches[1], $Matches[2]
                    $hits = @($mockNtnx.Categories | Where-Object { $_.Key -eq $key -and $_.Value -eq $value })
                    if ($hits.Count -eq 0) { return @{ data = $null } }
                    return @{ data = @($hits | ForEach-Object { @{ extId = $_.ExtId; key = $_.Key; value = $_.Value } }) }
                }
                '/prism/v4\.0/config/categories$' {
                    $requested = $Body | ConvertFrom-Json
                    $new = @{ Key = $requested.key; Value = $requested.value; ExtId = "cat-$($mockNtnx.Categories.Count + 1)" }
                    $mockNtnx.Categories.Add($new)
                    return @{ data = @{ extId = $new.ExtId; key = $new.Key; value = $new.Value } }
                }
                '/prism/v4\.0/config/tasks/(.+)$' {
                    return @{ data = @{ extId = $Matches[1]; status = $mockNtnx.TaskStatus } }
                }
            }
            throw "Unexpected request: $Method $Uri"
        }
    }

    Context 'Name cleanup' {
        It 'replaces forbidden characters with a single space and strips a leading $' {
            $mockNtnx.Vms.Add(@{ Name = 'web01'; ExtId = 'vm-1'; ETag = '"etag-1"' })
            $csv = Write-TagCsv -Rows @(
                [pscustomobject]@{ VMName = 'web01'; TagCategory = 'App/Tier'; Tag = 'Web (prod)' }
                [pscustomobject]@{ VMName = 'web01'; TagCategory = '$Owner'; Tag = 'Finance: EMEA, APAC' }
            )

            Invoke-Import -CsvPath $csv | Should -Be 0

            $created = $mockNtnx.Categories | ForEach-Object { "$($_.Key):$($_.Value)" }
            $created | Should -Be @('App Tier:Web prod', 'Owner:Finance EMEA APAC')
        }

        It 'truncates to 64 characters and never leaves a trailing space' {
            $mockNtnx.Vms.Add(@{ Name = 'web01'; ExtId = 'vm-1'; ETag = '"etag-1"' })
            $longTag = ('x' * 63) + ' ' + ('y' * 10)       # character 64 is a space
            $csv = Write-TagCsv -Rows @([pscustomobject]@{ VMName = 'web01'; TagCategory = 'App'; Tag = $longTag })

            Invoke-Import -CsvPath $csv | Should -Be 0

            $mockNtnx.Categories[0].Value | Should -Be ('x' * 63)
            $mockNtnx.Categories[0].Value.Length | Should -BeLessOrEqual 64
            $mockNtnx.Categories[0].Value | Should -Not -Match '\s$'
        }

        It 'warns once when a name is changed' {
            $mockNtnx.Vms.Add(@{ Name = 'web01'; ExtId = 'vm-1'; ETag = '"etag-1"' })
            $mockNtnx.Vms.Add(@{ Name = 'web02'; ExtId = 'vm-2'; ETag = '"etag-2"' })
            $csv = Write-TagCsv -Rows @(
                [pscustomobject]@{ VMName = 'web01'; TagCategory = 'App/Tier'; Tag = 'Web' }
                [pscustomobject]@{ VMName = 'web02'; TagCategory = 'App/Tier'; Tag = 'Web' }
            )

            Invoke-Import -CsvPath $csv | Should -Be 0

            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -eq "Renamed 'App/Tier' to 'App Tier'" }
            Should -Invoke Write-Warning -Times 0 -Exactly -ParameterFilter { $Message -like "Renamed 'Web'*" }
        }

        It 'fails the VM when a name is empty after cleanup' {
            $mockNtnx.Vms.Add(@{ Name = 'web01'; ExtId = 'vm-1'; ETag = '"etag-1"' })
            $csv = Write-TagCsv -Rows @([pscustomobject]@{ VMName = 'web01'; TagCategory = 'App'; Tag = '///' })

            Invoke-Import -CsvPath $csv | Should -Be 1

            Should -Invoke Write-Warning -Times 1 -ParameterFilter { $Message -like "web01: failed.*'///' is empty*" }
            $mockNtnx.Calls | Where-Object { $_.Method -eq 'Post' } | Should -BeNullOrEmpty
        }
    }

    Context 'Key prefix' {
        It 'applies -KeyPrefix to keys only' {
            $mockNtnx.Vms.Add(@{ Name = 'web01'; ExtId = 'vm-1'; ETag = '"etag-1"' })
            $csv = Write-TagCsv -Rows @([pscustomobject]@{ VMName = 'web01'; TagCategory = 'App'; Tag = 'App' })

            Invoke-Import -CsvPath $csv -Extra @{ KeyPrefix = 'vmw_' } | Should -Be 0

            $mockNtnx.Categories.Count | Should -Be 1
            $mockNtnx.Categories[0].Key | Should -Be 'vmw_App'
            $mockNtnx.Categories[0].Value | Should -Be 'App'

            $lookup = $mockNtnx.Calls | Where-Object { $_.Uri -match '/prism/v4\.0/config/categories\?' }
            Get-FilterValue -Uri $lookup.Uri | Should -Be "key eq 'vmw_App' and value eq 'App'"
        }
    }

    Context 'VM lookup' {
        It 'escapes an apostrophe in the VM name inside $filter' {
            $mockNtnx.Vms.Add(@{ Name = "O'Brien-01"; ExtId = 'vm-1'; ETag = '"etag-1"' })
            $csv = Write-TagCsv -Rows @([pscustomobject]@{ VMName = "O'Brien-01"; TagCategory = 'App'; Tag = 'Web' })

            Invoke-Import -CsvPath $csv | Should -Be 0

            $lookup = $mockNtnx.Calls | Where-Object { $_.Uri -match '/vmm/v4\.0/ahv/config/vms\?' }
            Get-FilterValue -Uri $lookup.Uri | Should -Be "name eq 'O''Brien-01'"
            $lookup.Uri | Should -Not -Match " |'"
            $mockNtnx.Calls | Where-Object { $_.Uri -like '*associate-categories' } | Should -HaveCount 1
        }

        It 'skips a name that matches zero or several VMs instead of guessing' {
            $mockNtnx.Vms.Add(@{ Name = 'dup01'; ExtId = 'vm-1'; ETag = '"etag-1"' })
            $mockNtnx.Vms.Add(@{ Name = 'dup01'; ExtId = 'vm-2'; ETag = '"etag-2"' })
            $csv = Write-TagCsv -Rows @(
                [pscustomobject]@{ VMName = 'missing01'; TagCategory = 'App'; Tag = 'Web' }
                [pscustomobject]@{ VMName = 'dup01'; TagCategory = 'App'; Tag = 'Web' }
            )

            Invoke-Import -CsvPath $csv | Should -Be 0

            Should -Invoke Write-Warning -Times 1 -ParameterFilter { $Message -eq 'missing01: found 0 AHV VMs with this name, skipped' }
            Should -Invoke Write-Warning -Times 1 -ParameterFilter { $Message -eq 'dup01: found 2 AHV VMs with this name, skipped' }
            Should -Invoke Write-Host -Times 1 -ParameterFilter { $Object -match '^\s*VMs skipped:\s+2$' }
            Should -Invoke Write-Host -Times 1 -ParameterFilter { $Object -match '^\s*VMs updated:\s+0$' }
            $mockNtnx.Calls | Where-Object { $_.Method -eq 'Post' } | Should -BeNullOrEmpty
            $mockNtnx.Calls | Where-Object { $_.Uri -like '*/prism/*' } | Should -BeNullOrEmpty
        }

        It 'looks up the VM by TargetVMName when the column is filled in' {
            $mockNtnx.Vms.Add(@{ Name = 'web01-ahv'; ExtId = 'vm-1'; ETag = '"etag-1"' })
            $mockNtnx.Vms.Add(@{ Name = 'db01'; ExtId = 'vm-2'; ETag = '"etag-2"' })
            $csv = Write-TagCsv -Rows @(
                [pscustomobject]@{ VMName = 'web01'; TagCategory = 'App'; Tag = 'Web'; TargetVMName = 'web01-ahv' }
                [pscustomobject]@{ VMName = 'web01'; TagCategory = 'Env'; Tag = 'Prod'; TargetVMName = 'web01-ahv' }
                [pscustomobject]@{ VMName = 'db01'; TagCategory = 'App'; Tag = 'DB'; TargetVMName = '' }
            )

            Invoke-Import -CsvPath $csv | Should -Be 0

            $lookups = @($mockNtnx.Calls | Where-Object { $_.Uri -match '/vmm/v4\.0/ahv/config/vms\?' } | ForEach-Object { Get-FilterValue -Uri $_.Uri })
            $lookups | Should -HaveCount 2
            $lookups | Should -Contain "name eq 'web01-ahv'"
            $lookups | Should -Contain "name eq 'db01'"
            $lookups | Should -Not -Contain "name eq 'web01'"
            Should -Invoke Write-Host -Times 1 -ParameterFilter { $Object -eq 'web01 (AHV name web01-ahv): 2 categories, task SUCCEEDED' }
            Should -Invoke Write-Host -Times 1 -ParameterFilter { $Object -match '^\s*VMs updated:\s+2$' }
        }
    }

    Context 'Categories' {
        It 'reuses an existing category and creates a missing one once, cached across VMs' {
            $mockNtnx.Vms.Add(@{ Name = 'web01'; ExtId = 'vm-1'; ETag = '"etag-1"' })
            $mockNtnx.Vms.Add(@{ Name = 'web02'; ExtId = 'vm-2'; ETag = '"etag-2"' })
            $mockNtnx.Categories.Add(@{ Key = 'Env'; Value = 'Prod'; ExtId = 'cat-existing' })
            $csv = Write-TagCsv -Rows @(
                [pscustomobject]@{ VMName = 'web01'; TagCategory = 'Env'; Tag = 'Prod' }
                [pscustomobject]@{ VMName = 'web01'; TagCategory = 'App'; Tag = 'Web' }
                [pscustomobject]@{ VMName = 'web02'; TagCategory = 'Env'; Tag = 'Prod' }
                [pscustomobject]@{ VMName = 'web02'; TagCategory = 'App'; Tag = 'Web' }
            )

            Invoke-Import -CsvPath $csv | Should -Be 0

            $creates = @($mockNtnx.Calls | Where-Object { $_.Method -eq 'Post' -and $_.Uri -eq "$script:apiBase/prism/v4.0/config/categories" })
            $creates | Should -HaveCount 1
            ($creates[0].Body | ConvertFrom-Json).key | Should -Be 'App'
            ($creates[0].Body | ConvertFrom-Json).value | Should -Be 'Web'
            ($creates[0].Body | ConvertFrom-Json).description | Should -Not -BeNullOrEmpty

            # Each category is looked up exactly once for the whole run.
            $lookups = @($mockNtnx.Calls | Where-Object { $_.Uri -match '/prism/v4\.0/config/categories\?' } | ForEach-Object { Get-FilterValue -Uri $_.Uri })
            $lookups | Should -HaveCount 2
            $lookups | Should -Contain "key eq 'Env' and value eq 'Prod'"
            $lookups | Should -Contain "key eq 'App' and value eq 'Web'"

            $associates = @($mockNtnx.Calls | Where-Object { $_.Uri -like '*associate-categories' })
            $associates | Should -HaveCount 2
            foreach ($call in $associates) {
                $ids = @(($call.Body | ConvertFrom-Json).categories.extId)
                $ids | Should -Be @('cat-existing', 'cat-2')
            }
            Should -Invoke Write-Host -Times 1 -ParameterFilter { $Object -match '^\s*Categories created:\s+1$' }
        }
    }

    Context 'Dry run' {
        It 'sends no POST and reports each would-be category exactly once' {
            $mockNtnx.Vms.Add(@{ Name = 'web01'; ExtId = 'vm-1'; ETag = '"etag-1"' })
            $mockNtnx.Vms.Add(@{ Name = 'web02'; ExtId = 'vm-2'; ETag = '"etag-2"' })
            $mockNtnx.Categories.Add(@{ Key = 'Env'; Value = 'Prod'; ExtId = 'cat-existing' })
            $csv = Write-TagCsv -Rows @(
                [pscustomobject]@{ VMName = 'web01'; TagCategory = 'App'; Tag = 'Web' }
                [pscustomobject]@{ VMName = 'web01'; TagCategory = 'Env'; Tag = 'Prod' }
                [pscustomobject]@{ VMName = 'web02'; TagCategory = 'App'; Tag = 'Web' }
                [pscustomobject]@{ VMName = 'web02'; TagCategory = 'Owner'; Tag = 'Finance' }
            )

            Invoke-Import -CsvPath $csv -Extra @{ DryRun = $true } | Should -Be 0

            $mockNtnx.Calls | Where-Object { $_.Method -ne 'Get' } | Should -BeNullOrEmpty
            $mockNtnx.Calls | Where-Object { $_.Uri -like '*associate-categories' } | Should -BeNullOrEmpty
            $mockNtnx.Categories | Should -HaveCount 1

            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $Object -eq 'Would create category App:Web' }
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $Object -eq 'Would create category Owner:Finance' }
            Should -Invoke Write-Host -Times 0 -Exactly -ParameterFilter { $Object -like 'Would create category Env:Prod' }
            Should -Invoke Write-Host -Times 1 -ParameterFilter { $Object -eq 'Would associate 2 categories with web01' }
            Should -Invoke Write-Host -Times 1 -ParameterFilter { $Object -eq 'Would associate 2 categories with web02' }

            # The summary lists each would-be category once.
            Should -Invoke Write-Host -Times 1 -ParameterFilter { $Object -match '^\s*Categories to be created:\s+2$' }
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $Object -match '^\s+App:Web$' }
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $Object -match '^\s+Owner:Finance$' }
        }
    }

    Context 'Associate call' {
        It 'carries If-Match with the ETag, an NTNX-Request-Id, and a body of unique extIds' {
            $mockNtnx.Vms.Add(@{ Name = 'web01'; ExtId = 'vm-1'; ETag = '"etag-vm-1"' })
            $csv = Write-TagCsv -Rows @(
                [pscustomobject]@{ VMName = 'web01'; TagCategory = 'App/Web'; Tag = 'Tier 1' }
                [pscustomobject]@{ VMName = 'web01'; TagCategory = 'App Web'; Tag = 'Tier 1' }
                [pscustomobject]@{ VMName = 'web01'; TagCategory = 'Env'; Tag = 'Prod' }
            )

            Invoke-Import -CsvPath $csv | Should -Be 0

            $associate = $mockNtnx.Calls | Where-Object { $_.Uri -like '*associate-categories' }
            $associate | Should -HaveCount 1
            $associate.Method | Should -Be 'Post'
            $associate.Uri | Should -Be "$script:apiBase/vmm/v4.0/ahv/config/vms/vm-1/`$actions/associate-categories"
            $associate.Headers['If-Match'] | Should -Be '"etag-vm-1"'
            $associate.Headers['X-ntnx-api-key'] | Should -Be 'test-api-key'
            [guid]::TryParse($associate.Headers['NTNX-Request-Id'], [ref]([guid]::Empty)) | Should -BeTrue

            $ids = @(($associate.Body | ConvertFrom-Json).categories.extId)
            $ids | Should -HaveCount 2
            $ids | Should -Be ($ids | Select-Object -Unique)
            Should -Invoke Write-Warning -Times 1 -ParameterFilter { $Message -like "web01: tags 'App/Web/Tier 1' and 'App Web/Tier 1' both map to category App Web:Tier 1*" }
            Should -Invoke Write-Host -Times 1 -ParameterFilter { $Object -eq 'web01: 2 categories, task SUCCEEDED' }
        }

        It 'sends the API key on every request and a new NTNX-Request-Id only on non-GET requests' {
            $mockNtnx.Vms.Add(@{ Name = 'web01'; ExtId = 'vm-1'; ETag = '"etag-1"' })
            $csv = Write-TagCsv -Rows @([pscustomobject]@{ VMName = 'web01'; TagCategory = 'App'; Tag = 'Web' })

            Invoke-Import -CsvPath $csv | Should -Be 0

            $mockNtnx.Calls | ForEach-Object { $_.Headers['X-ntnx-api-key'] | Should -Be 'test-api-key' }
            $gets  = @($mockNtnx.Calls | Where-Object { $_.Method -eq 'Get' })
            $posts = @($mockNtnx.Calls | Where-Object { $_.Method -eq 'Post' })
            $gets.Count | Should -BeGreaterThan 0
            $posts | Should -HaveCount 2
            $gets | ForEach-Object { $_.Headers.ContainsKey('NTNX-Request-Id') | Should -BeFalse }
            $posts | ForEach-Object { $_.Headers.ContainsKey('NTNX-Request-Id') | Should -BeTrue }
            $posts[0].Headers['NTNX-Request-Id'] | Should -Not -Be $posts[1].Headers['NTNX-Request-Id']
        }
    }

    Context 'Error handling' {
        It 'continues with the next VM after a failure and exits with code 1' {
            $mockNtnx.Vms.Add(@{ Name = 'web01'; ExtId = 'vm-1'; ETag = '"etag-1"' })
            $mockNtnx.Vms.Add(@{ Name = 'web02'; ExtId = 'vm-2'; ETag = '"etag-2"' })
            $mockNtnx.FailAssociateFor = @('vm-1')
            $csv = Write-TagCsv -Rows @(
                [pscustomobject]@{ VMName = 'web01'; TagCategory = 'App'; Tag = 'Web' }
                [pscustomobject]@{ VMName = 'web02'; TagCategory = 'App'; Tag = 'Web' }
            )

            Invoke-Import -CsvPath $csv | Should -Be 1

            Should -Invoke Write-Warning -Times 1 -ParameterFilter {
                $Message -like 'web01: failed.*' -and
                $Message -like '*HTTP 409 (Conflict)*' -and
                $Message -like '*category already associated*' -and
                $Message -notlike '*test-api-key*'
            }
            $associates = @($mockNtnx.Calls | Where-Object { $_.Uri -like '*associate-categories' })
            $associates | Should -HaveCount 2
            $associates[1].Uri | Should -BeLike '*/vms/vm-2/*'
            Should -Invoke Write-Host -Times 1 -ParameterFilter { $Object -eq 'web02: 1 categories, task SUCCEEDED' }
            Should -Invoke Write-Host -Times 1 -ParameterFilter { $Object -match '^\s*VMs updated:\s+1$' }
            Should -Invoke Write-Host -Times 1 -ParameterFilter { $Object -match '^\s*VMs failed:\s+1$' }
        }

        It 'treats a task that ends in any status other than SUCCEEDED as a failure' {
            $mockNtnx.Vms.Add(@{ Name = 'web01'; ExtId = 'vm-1'; ETag = '"etag-1"' })
            $mockNtnx.TaskStatus = 'FAILED'
            $csv = Write-TagCsv -Rows @([pscustomobject]@{ VMName = 'web01'; TagCategory = 'App'; Tag = 'Web' })

            Invoke-Import -CsvPath $csv | Should -Be 1

            Should -Invoke Write-Warning -Times 1 -ParameterFilter { $Message -like 'web01: failed.*task task-vm-1 ended with status FAILED*' }
            Should -Invoke Write-Host -Times 1 -ParameterFilter { $Object -match '^\s*VMs failed:\s+1$' }
        }

        It 'gives up on a task that is still running after -TaskTimeoutSeconds' {
            $mockNtnx.Vms.Add(@{ Name = 'web01'; ExtId = 'vm-1'; ETag = '"etag-1"' })
            $mockNtnx.Vms.Add(@{ Name = 'web02'; ExtId = 'vm-2'; ETag = '"etag-2"' })
            $mockNtnx.TaskStatus = 'RUNNING'
            $csv = Write-TagCsv -Rows @(
                [pscustomobject]@{ VMName = 'web01'; TagCategory = 'App'; Tag = 'Web' }
                [pscustomobject]@{ VMName = 'web02'; TagCategory = 'App'; Tag = 'Web' }
            )

            Invoke-Import -CsvPath $csv -Extra @{ TaskTimeoutSeconds = 1 } | Should -Be 1

            Should -Invoke Start-Sleep -ParameterFilter { $Seconds -eq 2 }
            $polls = @($mockNtnx.Calls | Where-Object { $_.Uri -like '*/prism/v4.0/config/tasks/*' })
            $polls.Count | Should -BeGreaterThan 0
            Should -Invoke Write-Warning -Times 1 -ParameterFilter { $Message -like 'web01: failed.*Task task-vm-1 is still RUNNING after 1 seconds*' }
            Should -Invoke Write-Warning -Times 1 -ParameterFilter { $Message -like 'web02: failed.*Task task-vm-2 is still RUNNING after 1 seconds*' }
            Should -Invoke Write-Host -Times 1 -ParameterFilter { $Object -match '^\s*VMs failed:\s+2$' }
        }

        It 'refuses to run without NTNX_API_KEY' {
            $csv = Write-TagCsv -Rows @([pscustomobject]@{ VMName = 'web01'; TagCategory = 'App'; Tag = 'Web' })
            $env:NTNX_API_KEY = ''
            try {
                { & $script:importScript -PrismCentral $script:pc -Path $csv } | Should -Throw '*NTNX_API_KEY*'
            }
            finally {
                $env:NTNX_API_KEY = 'test-api-key'
            }
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly
        }

        It 'rejects a CSV without the expected columns' {
            $csv = Write-TagCsv -Rows @([pscustomobject]@{ Name = 'web01'; Category = 'App' })
            { & $script:importScript -PrismCentral $script:pc -Path $csv } | Should -Throw "*no 'VMName' column*"
        }
    }

    Context 'Help and parameters' {
        It 'has comment-based help' {
            $help = Get-Help $script:importScript
            $help.Synopsis | Should -Match 'Prism Central categories'
            $help.Description | Should -Not -BeNullOrEmpty
            $help.Examples.Example.Count | Should -BeGreaterOrEqual 2
            foreach ($name in 'PrismCentral', 'Path', 'KeyPrefix', 'DryRun', 'SkipCertificateCheck', 'TaskTimeoutSeconds') {
                (Get-Help $script:importScript -Parameter $name).description.Text | Should -Not -BeNullOrEmpty
            }
        }

        It 'keeps the documented parameter names and defaults' {
            $command = Get-Command $script:importScript
            $command.Parameters.Keys | Should -Contain 'PrismCentral'
            $command.Parameters.Keys | Should -Contain 'Path'
            $command.Parameters.Keys | Should -Contain 'KeyPrefix'
            $command.Parameters.Keys | Should -Contain 'DryRun'
            $command.Parameters.Keys | Should -Contain 'SkipCertificateCheck'
            $command.Parameters.Keys | Should -Contain 'TaskTimeoutSeconds'
            $command.Parameters.Keys | Should -Not -Contain 'ApiKey'
            $command.ScriptBlock.Ast.ParamBlock.Parameters |
                Where-Object { $_.Name.VariablePath.UserPath -eq 'TaskTimeoutSeconds' } |
                ForEach-Object { $_.DefaultValue.Value } | Should -Be 300
        }
    }
}
