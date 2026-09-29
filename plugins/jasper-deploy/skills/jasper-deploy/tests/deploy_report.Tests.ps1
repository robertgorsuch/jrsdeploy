# Pester 3.x/4.x (legacy `Should Be` syntax) offline tests for
# scripts\deploy_report.ps1. The script needs a live server for a real deploy,
# so these tests cover what is testable without one: the script parses, its
# parameter surface, the documented pipeline result object (via the
# New-JrsDeployResult helper it uses), the resource.in.use branch and the
# pre-server guards (missing jrxml, SQL lint).

$script:Script = "$PSScriptRoot/../scripts/deploy_report.ps1"
. "$PSScriptRoot/../scripts/_jrs_common.ps1"

function Get-ScriptAst {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $script:Script).Path, [ref]$tokens, [ref]$errors)
    [pscustomobject]@{ Ast = $ast; Errors = @($errors) }
}

Describe "deploy_report.ps1 (offline)" {

    It "parses without syntax errors" {
        (Get-ScriptAst).Errors.Count | Should Be 0
    }

    It "exposes -Env alongside -ServerUrl/-User/-Password and keeps -Overwrite/-Backup" {
        $params = (Get-ScriptAst).Ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }
        foreach ($p in @('Jrxml', 'TargetUri', 'Overwrite', 'Backup', 'Control', 'QueryControl', 'ServerUrl', 'User', 'Password', 'Env')) {
            ($params -contains $p) | Should Be $true
        }
    }

    It "emits the result object with Write-Output (not only Write-Host) and explains resource.in.use" {
        $text = Get-Content $script:Script -Raw
        $text | Should Match 'Write-Output \(New-JrsDeployResult'
        $text | Should Match 'resource\\\.in\\\.use'
        $text | Should Match 'Get-JrsDashboardsReferencing'
        $text | Should Match 'compose_dashboard\.ps1 .*-Backup'
    }

    It "result object shape: Uri, Code, Status, ControlsAttached, Message" {
        $r = New-JrsDeployResult -Uri '/reports/x' -Code '201' -Status OK -ControlsAttached 2 -Message 'deployed'
        ($r.PSObject.Properties.Name -join ',') | Should Be 'Uri,Code,Status,ControlsAttached,Message'
        $r.ControlsAttached | Should Be 2
        $r.Status | Should Be 'OK'
    }

    It "throws before touching any server when the jrxml does not exist" {
        { & $script:Script -Jrxml (Join-Path ([IO.Path]::GetTempPath()) 'definitely_missing_report.jrxml') -TargetUri /reports/x -ServerUrl http://127.0.0.1:9 -User u -Password p *>$null } | Should Throw
    }

    It "SQL lint rejects a leading WITH (CTE) before any server call" {
        $f = Join-Path ([IO.Path]::GetTempPath()) ("dr_cte_{0}.jrxml" -f ([guid]::NewGuid().ToString('N')))
        @'
<?xml version="1.0" encoding="UTF-8"?>
<jasperReport xmlns="http://jasperreports.sourceforge.net/jasperreports" name="cte" pageWidth="595" pageHeight="842" columnWidth="555" leftMargin="20" rightMargin="20" topMargin="20" bottomMargin="20">
  <query language="SQL"><![CDATA[WITH t AS (SELECT 1 AS a) SELECT a FROM t]]></query>
  <field name="a" class="java.lang.Integer"/>
</jasperReport>
'@ | Set-Content $f -Encoding utf8
        try {
            $err = $null
            try { & $script:Script -Jrxml $f -TargetUri /reports/x -SkipLint -ServerUrl http://127.0.0.1:9 -User u -Password p *>$null } catch { $err = $_.Exception.Message }
            $err | Should Match 'SQL lint'
        } finally { Remove-Item $f -ErrorAction SilentlyContinue }
    }
}
