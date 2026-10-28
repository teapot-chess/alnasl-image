# One command rebuild of the Alnasl hall-box SD image.
#
#   (from inside PowerShell: & .\build.ps1 -Skip alnasl,modules ; with -File the list is read as one word)
#   powershell -File build.ps1 [-Vm root@172.16.63.81] [-Key ~/.ssh/photon_openpair]
#                              [-AlnasLRepo "..\Alnasl"] [-ArkabRepo "..\arkab"] [-Skip alnasl,arkab,modules,iw,kiosk]
#                              [-Version 6.0] [-Release] [-MinFrom 6.0] [-Notes "..."]
#
# -Version: the image's version within its train (v6 -> 6.0, 6.1 ...); written into the image
# (/etc/alnasl/image-release) and read back from there by make-release.sh.
# -Release: also cut the system-image release files (scripts/make-release.sh) into .\out\release:
# alnasl-system-v<version>.img.zst, its .json entry, and index.json (.\out\release\index.json from the
# last release is merged in when it is there). They are NOT signed and NOT published: sign them with
# scripts/sign-release.sh on the machine that holds the private key, then upload them by hand.
# A release build refuses the placeholder update key (ALNASL_RELEASE=1 in assemble/verify).
#
# What it does: ships the Alnasl and Arkab sources (git archive HEAD of each; Arkab's HEAD must be the
# branch you want in the image, main) and the scripts to
# the build VM (/root/w-photon-img5 only), runs the stages there, then copies
# the compressed image + SHA256 back into .\out\. Needs ssh/scp (Windows 10+).
# The VM needs: docker (started), qemu-user binfmt for aarch64 (the script
# installs it with tonistiigi/binfmt), curl, xz, losetup, sfdisk, e2fsprogs.
param(
  [string]$Vm = "root@172.16.63.81",
  [string]$Key = "$HOME\.ssh\photon_openpair",
  [string]$AlnasLRepo = (Join-Path $PSScriptRoot "..\Alnasl"),
  [string]$ArkabRepo = (Join-Path $PSScriptRoot "..\arkab"),
  [string[]]$Skip = @(),
  [string]$Version = "6.0",
  [switch]$Release,
  [string]$MinFrom = "",
  [string]$Notes = ""
)
if ($Version -notmatch '^[0-9]+\.[0-9]+(\.[0-9]+)?$') { throw "-Version must look like 6.1" }
if ($MinFrom -and $MinFrom -notmatch '^[0-9]+\.[0-9]+(\.[0-9]+)?$') { throw "-MinFrom must look like 6.1" }
if ($Notes -match "['`"\\]|\r|\n") { throw "-Notes: no quotes, backslashes or line breaks" }
$Train = "v" + $Version.Split(".")[0]
$RelEnv = if ($Release) { "ALNASL_RELEASE=1" } else { "ALNASL_RELEASE=0" }
$ErrorActionPreference = "Stop"
$here = $PSScriptRoot
$W = "/root/w-photon-img5"
$ssh = @("-i", $Key, "-o", "StrictHostKeyChecking=accept-new")

# "exec 2>&1": the remote shell merges stderr into stdout, otherwise Windows PowerShell 5.1 turns any stderr line into a terminating error.
function Vm-Run([string]$cmd) { & ssh @ssh $Vm "exec 2>&1; $cmd"; if ($LASTEXITCODE -ne 0) { throw "remote command failed: $cmd" } }

Write-Host "== ship"
Vm-Run "mkdir -p $W/alnasl $W/arkab $W/kiosk"
if ($Skip -notcontains "alnasl") {
  $tar = Join-Path $here "alnasl\alnasl-src.tar"
  git -C $AlnasLRepo archive -o $tar HEAD
  & scp @ssh $tar "$Vm`:$W/alnasl/"
}
& scp @ssh (Join-Path $here "alnasl\Dockerfile") "$Vm`:$W/alnasl/"
if ($Skip -notcontains "arkab") {
  # Arkab (the slave mode's program, docs/v6-plan.md section 1): its own repo's HEAD, built like Alnasl's.
  $atar = Join-Path $here "arkab\arkab-src.tar"
  git -C $ArkabRepo archive -o $atar HEAD
  & scp @ssh $atar "$Vm`:$W/arkab/"
}
& scp @ssh (Join-Path $here "arkab\Dockerfile") "$Vm`:$W/arkab/"
& scp @ssh (Join-Path $here "kiosk\Dockerfile") (Join-Path $here "kiosk\kiosk.sh") (Join-Path $here "kiosk\kiosk-res.sh") (Join-Path $here "kiosk\policies.json") "$Vm`:$W/kiosk/"
Vm-Run "rm -rf $W/kiosk/ext"
& scp -r @ssh (Join-Path $here "kiosk\ext") "$Vm`:$W/kiosk/"
& scp @ssh (Join-Path $here "scripts\build-alnasl.sh") (Join-Path $here "scripts\build-arkab.sh") (Join-Path $here "scripts\build-modules.sh") (Join-Path $here "scripts\build-kiosk.sh") (Join-Path $here "scripts\build-iw.sh") (Join-Path $here "scripts\test-diag.py") (Join-Path $here "scripts\test-res.py") (Join-Path $here "scripts\test-kiosk-logic.sh")(Join-Path $here "scripts\verify.sh") (Join-Path $here "scripts\qemu-smoke.sh") (Join-Path $here "scripts\assemble.sh") (Join-Path $here "scripts\lib-chroot.sh") (Join-Path $here "scripts\prepare-base.sh") (Join-Path $here "scripts\bootscreen.py") (Join-Path $here "scripts\test-splash.py") (Join-Path $here "scripts\grub-ab.cfg") (Join-Path $here "scripts\make-release.sh") (Join-Path $here "scripts\test-update.py") "$Vm`:$W/"
& scp @ssh (Join-Path $here "module\Makefile") "$Vm`:$W/module-Makefile"
Vm-Run "rm -rf $W/overlay"
& scp -r @ssh (Join-Path $here "overlay") "$Vm`:$W/"
Vm-Run "cd $W && sed -i 's/\r$//' *.sh test-diag.py test-res.py bootscreen.py test-splash.py test-update.py grub-ab.cfg kiosk/kiosk.sh kiosk/kiosk-res.sh module-Makefile && find overlay -type f ! -name '*.png' ! -name '*.pgm' -exec sed -i 's/\r$//' {} +"

Write-Host "== base image + binfmt"
Vm-Run "bash $W/prepare-base.sh"

if ($Skip -notcontains "alnasl")  { Write-Host "== Alnasl release (arm64, qemu)"; Vm-Run "bash $W/build-alnasl.sh" }
if ($Skip -notcontains "arkab")   { Write-Host "== Arkab release (arm64, qemu)";   Vm-Run "bash $W/build-arkab.sh" }
if ($Skip -notcontains "modules") { Write-Host "== out-of-tree modules";          Vm-Run "bash $W/build-modules.sh" }
if ($Skip -notcontains "iw")      { Write-Host "== iw (userspace tool)";        Vm-Run "bash $W/build-iw.sh" }
if ($Skip -notcontains "kiosk")   { Write-Host "== kiosk container image";        Vm-Run "bash $W/build-kiosk.sh" }

Write-Host "== assemble the image"
Vm-Run "ALNASL_TRAIN=$Train ALNASL_VERSION=$Version $RelEnv bash $W/assemble.sh"

Write-Host "== verify (no hardware)"
Vm-Run "$RelEnv bash $W/verify.sh > $W/verify.log 2>&1; grep -E 'FAIL|WARN' $W/verify.log; tail -n 1 $W/verify.log; true"   # the full log stays in verify.log on the VM

Write-Host "== compress + checksum"
Vm-Run "cd $W && rm -f photon-alnasl-v6.img.xz && xz -T8 -6 -k photon-alnasl-v6.img && sha256sum photon-alnasl-v6.img.xz > photon-alnasl-v6.img.xz.sha256 && ls -la photon-alnasl-v6.img.xz"

Write-Host "== fetch"
$out = Join-Path $here "out"
New-Item -ItemType Directory -Force $out | Out-Null
& scp @ssh "$Vm`:$W/photon-alnasl-v6.img.xz" "$Vm`:$W/photon-alnasl-v6.img.xz.sha256" $out

if ($Release) {
  # The system image of slot A, for boxes that already run v6 (updates without reflashing).
  Write-Host "== release files (unsigned, unpublished)"
  $rel = Join-Path $out "release"
  New-Item -ItemType Directory -Force $rel | Out-Null
  Vm-Run "rm -rf $W/release-in && mkdir -p $W/release-in"
  $oldIndex = Join-Path $rel "index.json"
  $idxArg = ""
  if (Test-Path $oldIndex) { & scp @ssh $oldIndex "$Vm`:$W/release-in/index.json"; $idxArg = "--index $W/release-in/index.json" }
  $mf = if ($MinFrom) { "--min-from $MinFrom" } else { "" }
  $nt = if ($Notes) { "--notes '$Notes'" } else { "" }
  Vm-Run "rm -rf $W/release && bash $W/make-release.sh $W/photon-alnasl-v6.img $W/release $mf $idxArg $nt"
  & scp @ssh "$Vm`:$W/release/*" $rel
  Write-Host "release files in $rel. Next, on the machine with the private key:"
  Write-Host "  scripts/sign-release.sh <private key> out/release/index.json out/release/alnasl-system-v$Version.img.zst"
}
Write-Host "done: $out"
