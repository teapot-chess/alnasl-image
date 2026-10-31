# Reads versions.json and checks it against the sibling checkouts. Returns @{ Tags; Shas }. Used by build.ps1 and check.ps1.
param([string]$Root = $PSScriptRoot, [string]$AlnasLRepo, [string]$ArkabRepo, [string]$PolisRepo, [string]$NunkiRepo)
$ErrorActionPreference = "Stop"
$here = $Root
# versions.json names the exact release tag of every bundled app. Nothing is built from a checkout's HEAD.
# git archive <tag> reads the tag's tree, so uncommitted changes in a sibling checkout cannot leak in;
# the failure that matters is a missing tag, and it stops here before anything is shipped.
$Manifest = Get-Content -Raw (Join-Path $here "versions.json") | ConvertFrom-Json
$Repos = @{ alnasl = $AlnasLRepo; arkab = $ArkabRepo; polis = $PolisRepo; nunki = $NunkiRepo }
$Tags = @{}; $Shas = @{}
foreach ($n in @("alnasl", "arkab", "polis", "nunki")) {
  $t = $Manifest.$n.tag
  if (-not $t) { throw "versions.json has no tag for $n" }
  if (-not (Test-Path $Repos[$n])) { throw "${n}: checkout not found at $($Repos[$n])" }
  $sha = & git -C $Repos[$n] rev-parse --verify --quiet "refs/tags/$t^{commit}"
  if ($LASTEXITCODE -ne 0 -or -not $sha) { throw "${n}: tag $t does not exist in $($Repos[$n]) (git fetch --tags there, or fix versions.json)" }
  $Tags[$n] = $t; $Shas[$n] = "$sha".Trim()
}
# Alnasl pins the Arkab it was released with (mix.exs and mix.lock). The image must bundle that one.
$arkabPin = @{}
foreach ($f in @("mix.exs", "mix.lock")) {
  $txt = (& git -C $AlnasLRepo show "$($Tags.alnasl):$f") -join "`n"
  if ($LASTEXITCODE -ne 0) { throw "alnasl $($Tags.alnasl): cannot read $f" }
  if ($txt -notmatch '(?i)arkab[^\n]*tag:\s*"(v[^"]+)"') { throw "alnasl $($Tags.alnasl): no Arkab tag pin found in $f" }
  $arkabPin[$f] = $Matches[1]
}
if ($arkabPin["mix.exs"] -ne $arkabPin["mix.lock"]) { throw "alnasl $($Tags.alnasl): mix.exs pins Arkab $($arkabPin['mix.exs']) but mix.lock $($arkabPin['mix.lock'])" }
if ($arkabPin["mix.exs"] -ne $Tags.arkab) { throw "versions.json bundles Arkab $($Tags.arkab) but Alnasl $($Tags.alnasl) pins Arkab $($arkabPin['mix.exs']). Fix versions.json." }
@{ Tags = $Tags; Shas = $Shas }
