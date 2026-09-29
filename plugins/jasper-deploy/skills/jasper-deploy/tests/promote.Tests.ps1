# Pester 3.x/4.x (legacy `Should Be` syntax; CI pins Pester 4) tests for
# scripts\promote.ps1 manifest mode and scripts\ensure_controls.ps1. NO live
# server is contacted: the scripts are dot-sourced (their main blocks are
# guarded), and every Invoke-Jrs* / child-script call is mocked.

. "$PSScriptRoot/../scripts/promote.ps1"      # also dot-sources ensure_controls.ps1 + _jrs_common.ps1

$script:Fixture = "$PSScriptRoot/../fixtures/controls.example.json"

function New-TempDir {
    $d = Join-Path ([IO.Path]::GetTempPath()) ("promote_t_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $d | Out-Null
    return $d
}

function Write-TestManifests($dir) {
    # two dashboards sharing one tile; A carries a controls spec + filters and a
    # local jrxml for one tile, B has a per-tile controls list and no jrxml
    Set-Content -LiteralPath (Join-Path $dir "shared_tile.jrxml") -Value '<jasperReport name="shared"/>' -Encoding ASCII
    @'
{ "folder": "/reports/t", "name": "dash_a", "label": "A", "dataSourceUri": "/datasources/t",
  "filters": ["p_regions"],
  "controls": [ { "name": "p_regions", "label": "Regions", "type": 6, "values": ["All", "East"] } ],
  "dashlets": [
    { "resource": "/reports/t/shared_tile", "label": "Shared", "x": 0, "y": 0, "width": 20, "height": 10 },
    { "resource": "/reports/t/only_a",      "label": "Only A", "x": 20, "y": 0, "width": 20, "height": 10 } ] }
'@ | Set-Content -LiteralPath (Join-Path $dir "a_dashboard.json") -Encoding ASCII
    @'
{ "folder": "/reports/t", "name": "dash_b", "label": "B",
  "dashlets": [
    { "resource": "/reports/t/shared_tile", "label": "Shared", "x": 0, "y": 0, "width": 40, "height": 10 },
    { "resource": "/reports/t/only_b", "label": "Only B", "controls": ["p_regions", "/reports/x/p_other"], "x": 0, "y": 10, "width": 40, "height": 10 } ] }
'@ | Set-Content -LiteralPath (Join-Path $dir "b_dashboard.json") -Encoding ASCII
    '{ "not": "a manifest" }' | Set-Content -LiteralPath (Join-Path $dir "other.json") -Encoding ASCII
}

Describe "ensure_controls.ps1 spec parsing" {
    It "parses the example fixture into 7 typed controls under the spec folder" {
        $spec = Read-ControlSpecFile -Path $script:Fixture
        $spec.Folder          | Should Be "/reports/example/controls"
        $spec.DataSourceUri   | Should Be "/datasources/example_warehouse"
        $spec.Controls.Count  | Should Be 7
        ($spec.Controls | Where-Object { $_.Name -eq "p_yyyymm" }).Type      | Should Be 3
        ($spec.Controls | Where-Object { $_.Name -eq "p_version" }).Type     | Should Be 3
        ($spec.Controls | Where-Object { $_.Name -eq "p_regions" }).Type     | Should Be 6
        ($spec.Controls | Where-Object { $_.Name -eq "p_store" }).Type       | Should Be 4
        ($spec.Controls | Where-Object { $_.Name -eq "p_franchisee" }).Type  | Should Be 7
        ($spec.Controls | Where-Object { $_.Name -eq "p_asof" }).Type        | Should Be 2
        ($spec.Controls | Where-Object { $_.Name -eq "p_include_closed" }).Type | Should Be 1
        ($spec.Controls | Where-Object { $_.Name -eq "p_store" }).Uri        | Should Be "/reports/example/controls/p_store"
        ($spec.Controls | Where-Object { $_.Name -eq "p_franchisee" }).VisibleColumns[0] | Should Be "fl"
        ($spec.Controls | Where-Object { $_.Name -eq "p_regions" }).Values[0].value | Should Be "All"
    }

    It "builds valid JSON descriptors for LOV and query controls" {
        $spec = Read-ControlSpecFile -Path $script:Fixture
        $lov = Get-ControlDescriptors ($spec.Controls | Where-Object { $_.Name -eq "p_yyyymm" })
        $lov.SubUri | Should Be "/reports/example/controls/p_yyyymm_lov"
        ($lov.SubJson | ConvertFrom-Json).items.Count | Should Be 3
        ($lov.IcJson | ConvertFrom-Json).listOfValues.listOfValuesReference.uri | Should Be $lov.SubUri
        $q = Get-ControlDescriptors ($spec.Controls | Where-Object { $_.Name -eq "p_store" })
        ($q.SubJson | ConvertFrom-Json).dataSource.dataSourceReference.uri | Should Be "/datasources/example_warehouse"
        ($q.IcJson | ConvertFrom-Json).valueColumn | Should Be "storenumber"
        ($q.IcJson | ConvertFrom-Json).type | Should Be 4
    }

    It "reads a manifest 'controls' key and defaults the folder to <folder>/controls" {
        $raw = '{ "folder": "/reports/t", "name": "d", "dataSourceUri": "/ds/t", "dashlets": [], "controls": [ { "name": "p_x", "kind": "query", "query": "SELECT 1 AS a", "valueColumn": "a" } ] }' | ConvertFrom-Json
        $spec = ConvertTo-ControlSpec -Raw $raw
        $spec.Folder | Should Be "/reports/t/controls"
        $spec.Controls[0].Uri | Should Be "/reports/t/controls/p_x"
        $spec.Controls[0].DataSourceUri | Should Be "/ds/t"
    }

    It "rejects a query control without a valueColumn" {
        $raw = '[ { "name": "bad", "type": 4, "query": "SELECT 1" } ]' | ConvertFrom-Json
        { ConvertTo-ControlSpec -Raw $raw -DefaultFolder "/f" -DefaultDataSourceUri "/ds" } | Should Throw
    }

    It "-WhatIf only GETs: no PUT for absent controls" {
        Mock Invoke-JrsGet { [pscustomobject]@{ Code = "404"; Body = "" } }
        Mock Invoke-JrsPut { throw "PUT must not be called under -WhatIf" }
        $spec = Read-ControlSpecFile -Path $script:Fixture
        $jrs = [pscustomobject]@{ ServerUrl = "http://x"; User = "u"; Password = "p" }
        $res = @(Invoke-EnsureControls -Jrs $jrs -Spec $spec -WhatIf)
        $res.Count | Should Be 7
        ($res | Where-Object { $_.Action -ne "would-create" }).Count | Should Be 0
        Assert-MockCalled Invoke-JrsPut -Times 0
        Assert-MockCalled Invoke-JrsGet -Times 7
    }

    It "skips existing controls without -Update and never PUTs" {
        Mock Invoke-JrsGet { [pscustomobject]@{ Code = "200"; Body = "{}" } }
        Mock Invoke-JrsPut { throw "PUT must not be called" }
        $spec = Read-ControlSpecFile -Path $script:Fixture
        $jrs = [pscustomobject]@{ ServerUrl = "http://x"; User = "u"; Password = "p" }
        $res = @(Invoke-EnsureControls -Jrs $jrs -Spec $spec)
        ($res | Where-Object { $_.Action -ne "exists" }).Count | Should Be 0
        Assert-MockCalled Invoke-JrsPut -Times 0
    }
}

Describe "promote.ps1 manifest plan ordering" {
    $dir = New-TempDir
    Write-TestManifests $dir

    It "resolves only real dashboard manifests from a directory" {
        $paths = @(Resolve-ManifestPaths $dir)
        $paths.Count | Should Be 2
        (Split-Path -Leaf $paths[0]) | Should Be "a_dashboard.json"
    }

    It "reads tiles, local jrxml, controls spec and per-tile control lists" {
        $a = Read-DashboardManifest (Join-Path $dir "a_dashboard.json")
        $b = Read-DashboardManifest (Join-Path $dir "b_dashboard.json")
        $a.Uri | Should Be "/reports/t/dash_a"
        $a.Tiles.Count | Should Be 2
        ($a.Tiles | Where-Object { $_.Leaf -eq "shared_tile" }).Jrxml | Should Match 'shared_tile\.jrxml$'
        ($a.Tiles | Where-Object { $_.Leaf -eq "only_a" }).Jrxml | Should BeNullOrEmpty
        $a.ControlSpec.Controls[0].Uri | Should Be "/reports/t/controls/p_regions"
        $a.FilterControlUris[0] | Should Be "/reports/t/controls/p_regions"
        $bt = $b.Tiles | Where-Object { $_.Leaf -eq "only_b" }
        $bt.Controls.Count | Should Be 2
        $bt.Controls[0] | Should Be "/reports/t/controls/p_regions"
        $bt.Controls[1] | Should Be "/reports/x/p_other"
        ($b.Tiles | Where-Object { $_.Leaf -eq "shared_tile" }).Controls | Should BeNullOrEmpty
    }

    It "orders teardown -> folder -> controls -> tiles (distinct) -> attach -> compose" {
        $mfs = @(Resolve-ManifestPaths $dir | ForEach-Object { Read-DashboardManifest $_ })
        $steps = @(Get-PromotePlanOrder $mfs)
        # phases never go backwards
        $prev = 0
        foreach ($s in $steps) { ($s.Phase -ge $prev) | Should Be $true; $prev = $s.Phase }
        @($steps | Where-Object { $_.Kind -eq "teardown" }).Count | Should Be 2
        @($steps | Where-Object { $_.Kind -eq "folder" }).Count   | Should Be 1
        @($steps | Where-Object { $_.Kind -eq "control" }).Count  | Should Be 1     # p_regions once (spec + filter)
        @($steps | Where-Object { $_.Kind -eq "tile" }).Count     | Should Be 3     # shared_tile deduplicated
        @($steps | Where-Object { $_.Kind -eq "attach" }).Count   | Should Be 3
        @($steps | Where-Object { $_.Kind -eq "compose" }).Count  | Should Be 2
        $lastTeardown = ($steps | Where-Object { $_.Kind -eq "teardown" } | Measure-Object Order -Maximum).Maximum
        $firstTile    = ($steps | Where-Object { $_.Kind -eq "tile" }     | Measure-Object Order -Minimum).Minimum
        $firstCompose = ($steps | Where-Object { $_.Kind -eq "compose" }  | Measure-Object Order -Minimum).Minimum
        ($lastTeardown -lt $firstTile) | Should Be $true
        ($firstTile -lt $firstCompose) | Should Be $true
        $steps[-1].Kind | Should Be "compose"
    }

    It "-WhatIf issues GETs only: no PUT/POST/DELETE and no child script" {
        Mock Invoke-JrsGet   { [pscustomobject]@{ Code = "404"; Body = "" } }
        Mock Invoke-JrsPut   { throw "PUT under -WhatIf" }
        Mock Invoke-JrsDelete { throw "DELETE under -WhatIf" }
        Mock Invoke-JrsRest  { throw "REST write under -WhatIf" }
        Mock Invoke-ChildScript { throw "child script under -WhatIf" }
        $from = [pscustomobject]@{ ServerUrl = "http://stage"; User = "u"; Password = "p" }
        $to   = [pscustomobject]@{ ServerUrl = "http://prod";  User = "u"; Password = "p" }
        $plan = @(Invoke-PromoteManifest -Manifest $dir -From $from -To $to -WhatIf -EnsureControls 6>$null)
        $plan.Count | Should Be 12
        Assert-MockCalled Invoke-JrsPut    -Times 0
        Assert-MockCalled Invoke-JrsDelete -Times 0
        Assert-MockCalled Invoke-JrsRest   -Times 0
        Assert-MockCalled Invoke-ChildScript -Times 0
        ($plan | Where-Object { $_.Kind -eq "tile" -and $_.Uri -eq "/reports/t/shared_tile" }).Action | Should Match '^DEPLOY via deploy_report'
        ($plan | Where-Object { $_.Kind -eq "tile" -and $_.Uri -eq "/reports/t/only_a" }).Action     | Should Match 'export\+import'
        ($plan | Where-Object { $_.Kind -eq "teardown" })[0].Action | Should Match 'skip'
        ($plan | Where-Object { $_.Kind -eq "control" })[0].Action  | Should Match 'CREATE from manifest'
    }

    It "reports identical jrxml as keep and existing controls as keep" {
        # a global so the mock body sees it regardless of how Pester rebinds the scriptblock
        $global:__jd_test_jrxml = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $dir "shared_tile.jrxml")))
        Mock Invoke-JrsGet {
            if ($Uri -like "*expanded=true") { return [pscustomobject]@{ Code = "200"; Body = ('{"jrxml":{"jrxmlFile":{"content":"' + $global:__jd_test_jrxml + '"}}}') } }
            if ($Uri -eq "/reports/t/only_b") { return [pscustomobject]@{ Code = "200"; Body = '{"inputControls":[{"inputControlReference":{"uri":"/reports/t/controls/p_regions"}},{"inputControlReference":{"uri":"/reports/x/p_other"}}]}' } }
            return [pscustomobject]@{ Code = "200"; Body = "{}" }
        }
        Mock Invoke-JrsPut { throw "PUT under -WhatIf" }
        $from = [pscustomobject]@{ ServerUrl = "http://stage"; User = "u"; Password = "p" }
        $to   = [pscustomobject]@{ ServerUrl = "http://prod";  User = "u"; Password = "p" }
        $plan = @(Invoke-PromoteManifest -Manifest (Join-Path $dir "b_dashboard.json") -From $from -To $to -WhatIf 6>$null)
        ($plan | Where-Object { $_.Kind -eq "tile" -and $_.Uri -eq "/reports/t/shared_tile" }).Action | Should Match '^keep'
        ($plan | Where-Object { $_.Kind -eq "tile" -and $_.Uri -eq "/reports/t/shared_tile" }).Note   | Should Match '^identical'
        ($plan | Where-Object { $_.Kind -eq "attach" -and $_.Uri -eq "/reports/t/only_b" }).Action    | Should Match '^keep'
        ($plan | Where-Object { $_.Kind -eq "teardown" })[0].Action | Should Match '^DELETE'
        Assert-MockCalled Invoke-JrsPut -Times 0
    }

    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
}
