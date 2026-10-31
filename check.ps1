# Local checks, no VM, no ssh, no Docker. Run before a release build and (once the repo has a remote) in CI:
#   powershell -File check.ps1 [-AlnasLRepo ..\Alnasl] [-ArkabRepo ..\arkab] [-PolisRepo ..\polis] [-NunkiRepo ..\nunki] [-SkipSiblings]
# -SkipSiblings: skip the checks that need the sibling checkouts (CI has none until it clones them).
#
# What it covers: versions.json against the sibling tags and Alnasl's Arkab pin, shell syntax of every .sh,
# PowerShell syntax of every .ps1, JSON validity, build outputs not tracked, no private key material.
# What it cannot cover: scripts/verify.sh and test-kiosk-logic.sh it runs need the finished
# image (loop mount, chroot, arm64 Docker). Those run on the build VM as the "verify" stage of build.ps1.
param(
  [string]$AlnasLRepo = (Join-Path $PSScriptRoot "..\Alnasl"),
  [string]$ArkabRepo = (Join-Path $PSScriptRoot "..\arkab"),
  [string]$PolisRepo = (Join-Path $PSScriptRoot "..\polis"),
  [string]$NunkiRepo = (Join-Path $PSScriptRoot "..\nunki"),
  [switch]$SkipSiblings
)
$ErrorActionPreference = "Stop"
$here = $PSScriptRoot
$fail = 0
function Ok([string]$m) { Write-Host "  ok   $m" }
function Bad([string]$m) { Write-Host "  FAIL $m"; $script:fail++ }

Write-Host "== versions.json"
$m = Get-Content -Raw (Join-Path $here "versions.json") | ConvertFrom-Json
foreach ($n in "alnasl", "arkab", "polis", "nunki") { if ($m.$n.tag -match '^v[0-9]+\.[0-9]+\.[0-9]+$') { Ok "$n $($m.$n.tag)" } else { Bad "$n tag is not vX.Y.Z" } }
if (-not $SkipSiblings) {
  try {
    $null = & (Join-Path $here "check-versions.ps1") -Root $here -AlnasLRepo $AlnasLRepo -ArkabRepo $ArkabRepo -PolisRepo $PolisRepo -NunkiRepo $NunkiRepo
    Ok "all tags exist; Arkab $($m.arkab.tag) is what Alnasl $($m.alnasl.tag) pins (mix.exs and mix.lock)"
  } catch { Bad $_.Exception.Message }
}

Write-Host "== shell syntax"
$sh = Get-Command bash -ErrorAction SilentlyContinue
$shFiles = @(Get-ChildItem -Path (Join-Path $here "scripts"), (Join-Path $here "kiosk") -Filter *.sh -Recurse)
if ($sh) {
  foreach ($f in $shFiles) { & bash -n $f.FullName; if ($LASTEXITCODE -eq 0) { Ok $f.Name } else { Bad "$($f.Name): bash -n" } }
} else { Write-Host "  skip (no bash on PATH)" }

Write-Host "== PowerShell syntax"
foreach ($f in Get-ChildItem -Path $here -Filter *.ps1) {
  $errs = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs)
  if ($errs -and $errs.Count) { Bad "$($f.Name): $($errs[0].Message)" } else { Ok $f.Name }
}

Write-Host "== JSON"
$json = @(Join-Path $here "versions.json"; Join-Path $here "kiosk\policies.json"; Join-Path $here "kiosk\ext\manifest.json")
$json += @(Get-ChildItem (Join-Path $here "overlay") -Filter *.json -Recurse | ForEach-Object FullName)
foreach ($f in $json) { try { $null = Get-Content -Raw $f | ConvertFrom-Json; Ok (Split-Path $f -Leaf) } catch { Bad "$f is not valid JSON" } }

Write-Host "== repository hygiene"
if (Test-Path (Join-Path $here ".git")) {
  $tracked = @(& git -C $here ls-files)
  $tars = @($tracked | Where-Object { $_ -like "*-src.tar" })
  if ($tars.Count) { Bad "build outputs tracked: $($tars -join ', ')" } else { Ok "no *-src.tar tracked" }
  $keys = @($tracked | Where-Object { $_ -match '\.(key|pem)$' })
  if ($keys.Count) { Bad "key material tracked: $($keys -join ', ')" } else { Ok "no .key/.pem tracked" }
}

if ($fail) { Write-Host "`n$fail check(s) FAILED"; exit 1 }
Write-Host "`nall checks passed"
