<#
.SYNOPSIS
  Declarative, idempotent input-control creation from a JSON spec.

.DESCRIPTION
  Generalises the hand-written per-suite control scripts (jrs_controls.ps1,
  churn_controls.ps1, ...) into one skill-owned script driven by a JSON spec.
  For every control in the spec it GETs the inputControl URI first and creates
  the control (sub-resource + inputControl) only when it is absent. With
  -Update an existing control is PUT in place (overwrite=true); when JRS
  answers 403 resource.in.use (the control is attached to a report unit, or
  its LOV/query is referenced by the control) the script warns with the fix
  instead of failing.

  The spec is either a standalone file
    { "folder": "/reports/x/controls", "dataSourceUri": "/datasources/x",
      "controls": [ {...}, {...} ] }
  a bare array of control objects, or a dashboard manifest that carries the
  same object under its "controls" key (manifest.schema.json). Per control:
    name, label, type (1 bool | 2 single value | 3 single-select LOV |
    4 single-select query | 5 multi value | 6 multi-select LOV |
    7 multi-select query), or kind (bool|single|lov|multilov|query|multiquery),
    values ["label=value", ...] or [{label,value}] for LOV kinds,
    query + valueColumn (+ visibleColumns) for query kinds,
    dataType text|number|date|datetime for single/multi value kinds,
    optional per-control folder / dataSourceUri overrides,
    optional mandatory / readOnly / visible flags.
  See fixtures/controls.example.json.

.PARAMETER Spec
  Path to the JSON spec (or a manifest with a "controls" key).

.PARAMETER Env
  Named profile under "environments" in jrs.config.json (stage, prod, ...).

.PARAMETER Update
  Also PUT controls that already exist (in place; never deletes).

.PARAMETER WhatIf
  Print the plan (exists / would create / would update) and write nothing.

.OUTPUTS
  One object per control: Name, Uri, Action (exists|created|updated|
  in-use|would-create|would-update), Type.

.EXAMPLE
  .\ensure_controls.ps1 -Spec fixtures\controls.example.json -Env stage -WhatIf
#>
[CmdletBinding()]
param(
    [string]$Spec,
    [string]$Env,
    [string]$Folder,           # default folder when the spec has none
    [string]$DataSourceUri,    # default datasource for query controls
    [switch]$Update,
    [switch]$WhatIf,
    [string]$ServerUrl,
    [string]$User,
    [string]$Password
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_controls_common.ps1")   # functions live there (no param block -> safe to dot-source)
if ($MyInvocation.InvocationName -ne ".") {
    if (-not $Spec) { throw "-Spec <json> is required" }
    # NOTE: not "$spec" -- PowerShell variables are case-insensitive, so that would
    # assign into the [string]$Spec parameter and coerce the object to a string.
    $specObj = Read-ControlSpecFile -Path $Spec -DefaultFolder $Folder -DefaultDataSourceUri $DataSourceUri
    $jrs = Resolve-JrsConfig -ServerUrl $ServerUrl -User $User -Password $Password -Env $Env
    Write-Host "ensure $($specObj.Controls.Count) input control(s) under $($specObj.Folder) on $($jrs.ServerUrl)$(if ($WhatIf) { ' [whatif]' })"
    $res = Invoke-EnsureControls -Jrs $jrs -Spec $specObj -Update:$Update -WhatIf:$WhatIf
    $res
}
