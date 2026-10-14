#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Tests for Export-VSphereTags.ps1.

    PowerCLI is not installed on the test machine. A stub module named VMware.VimAutomation.Core
    is written to TestDrive and imported so the script's #Requires statement is satisfied and
    Pester has commands to mock. Every stub throws, so a test fails if a mock is not hit.
#>

BeforeAll {
    $script:exportScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'Export-VSphereTags.ps1'
    $script:vcenter      = 'vcenter01.lab.local'

    $stubRoot = Join-Path $TestDrive 'Modules/VMware.VimAutomation.Core'
    New-Item -ItemType Directory -Path $stubRoot -Force | Out-Null
    Set-Content -Path (Join-Path $stubRoot 'VMware.VimAutomation.Core.psm1') -Value @'
function Connect-VIServer {
    [CmdletBinding()]
    param([string]$Server, [pscredential]$Credential)
    throw 'stub Connect-VIServer was called without a mock'
}
function Disconnect-VIServer {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Server, [switch]$Force)
    throw 'stub Disconnect-VIServer was called without a mock'
}
function Get-VM {
    [CmdletBinding()]
    param([string[]]$Name)
    throw 'stub Get-VM was called without a mock'
}
function Get-TagAssignment {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)][object[]]$Entity, [string]$Category)
    throw 'stub Get-TagAssignment was called without a mock'
}
'@
    New-ModuleManifest -Path (Join-Path $stubRoot 'VMware.VimAutomation.Core.psd1') `
        -RootModule 'VMware.VimAutomation.Core.psm1' -ModuleVersion '99.0.0' `
        -FunctionsToExport 'Connect-VIServer', 'Disconnect-VIServer', 'Get-VM', 'Get-TagAssignment'
    Import-Module (Join-Path $stubRoot 'VMware.VimAutomation.Core.psd1') -Force

    function Get-FakeAssignment {
        param([string]$VM, [string]$Category, [string]$Tag)
        [pscustomobject]@{
            Entity = [pscustomobject]@{ Name = $VM }
            Tag    = [pscustomobject]@{ Name = $Tag; Category = [pscustomobject]@{ Name = $Category } }
        }
    }
}

AfterAll {
    Remove-Module VMware.VimAutomation.Core -Force -ErrorAction Ignore
}

Describe 'Export-VSphereTags.ps1' {
    BeforeEach {
        $mockVms = @([pscustomobject]@{ Name = 'web01' }, [pscustomobject]@{ Name = 'db01' })
        Mock Write-Host {}
        Mock Connect-VIServer { [pscustomobject]@{ Name = $Server; IsConnected = $true } }
        Mock Disconnect-VIServer {}
        Mock Get-VM { $mockVms }
        Mock Get-TagAssignment {
            # Deliberately unsorted so the test proves the script sorts.
            Get-FakeAssignment -VM 'web01' -Category 'Owner' -Tag 'Finance'
            Get-FakeAssignment -VM 'db01' -Category 'App' -Tag 'Database'
            Get-FakeAssignment -VM 'web01' -Category 'App' -Tag 'Web'
            Get-FakeAssignment -VM 'web01' -Category 'App' -Tag 'Frontend'
        }
    }

    It 'connects, exports every VM tag assignment sorted, and disconnects' {
        $out = Join-Path $TestDrive 'tags.csv'

        & $script:exportScript -VCenter $script:vcenter -Path $out

        Should -Invoke Connect-VIServer -Times 1 -Exactly -ParameterFilter { $Server -eq 'vcenter01.lab.local' }
        Should -Invoke Get-VM -Times 1 -Exactly
        Should -Invoke Get-TagAssignment -Times 1 -Exactly -ParameterFilter { @($Entity).Count -eq 2 }
        Should -Invoke Disconnect-VIServer -Times 1 -Exactly -ParameterFilter { $Server -eq 'vcenter01.lab.local' }
        Should -Invoke Write-Host -Times 1 -ParameterFilter { $Object -eq "Exported tag assignments to $out" }

        (Get-Content $out -First 1) | Should -Be '"VMName","TagCategory","Tag"'
        $rows = @(Import-Csv $out)
        $rows | Should -HaveCount 4
        $rows | ForEach-Object { "$($_.VMName)|$($_.TagCategory)|$($_.Tag)" } |
            Should -Be @('db01|App|Database', 'web01|App|Frontend', 'web01|App|Web', 'web01|Owner|Finance')
    }

    It 'writes to ./vsphere-tags.csv by default' {
        Push-Location $TestDrive
        try {
            & $script:exportScript -VCenter $script:vcenter
            Test-Path (Join-Path $TestDrive 'vsphere-tags.csv') | Should -BeTrue
        }
        finally {
            Pop-Location
        }
    }

    It 'does not disconnect from a server it did not connect to' {
        & $script:exportScript -VCenter 'vcenter02.lab.local' -Path (Join-Path $TestDrive 'other.csv')
        Should -Invoke Disconnect-VIServer -Times 1 -Exactly -ParameterFilter { $Server -eq 'vcenter02.lab.local' }
    }

    Context 'Help and parameters' {
        It 'has comment-based help' {
            $help = Get-Help $script:exportScript
            $help.Synopsis | Should -Match 'vCenter'
            $help.Description | Should -Not -BeNullOrEmpty
            $help.Examples.Example.Count | Should -BeGreaterOrEqual 1
            foreach ($name in 'VCenter', 'Path') {
                (Get-Help $script:exportScript -Parameter $name).description.Text | Should -Not -BeNullOrEmpty
            }
        }

        It 'keeps the documented parameter names' {
            $command = Get-Command $script:exportScript
            $command.Parameters.Keys | Should -Contain 'VCenter'
            $command.Parameters.Keys | Should -Contain 'Path'
            $command.Parameters['VCenter'].Attributes.Mandatory | Should -Contain $true
        }
    }
}
