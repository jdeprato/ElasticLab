# =============================================================================
# ElasticLab.psm1
# Root module loader. Imports all ElasticLab sub-modules in dependency order.
# Do not place functions here -- use the sub-modules.
# =============================================================================

$moduleRoot = $PSScriptRoot

$subModules = @(
    "ElasticLab.Core",
    "ElasticLab.Preflight",
    "ElasticLab.Docker",
    "ElasticLab.License",
    "ElasticLab.AI",
    "ElasticLab.Fleet",
    "ElasticLab.VMs",
    "ElasticLab.Cleanup",
    "ElasticLab.Invoke"
)

foreach ($module in $subModules) {
    $path = Join-Path $moduleRoot "$module.psm1"
    if (Test-Path $path) {
        Import-Module $path -Force -Global
    } else {
        Write-Warning "ElasticLab: sub-module not found: $path"
    }
}
