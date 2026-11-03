# One command rebuild of the Alnasl hall-box SD image.
#
#   (from inside PowerShell: & .\build.ps1 -Skip alnasl,modules ; with -File the list is read as one word)
#   powershell -File build.ps1 [-Vm root@172.16.63.81] [-Key ~/.ssh/photon_openpair]
#                              [-AlnasLRepo "..\Alnasl"] [-ArkabRepo "..\arkab"] [-PolisRepo "..\polis"] [-NunkiRepo "..\nunki"]
#                              [-Skip alnasl,arkab,polis,nunki,setup,espeak,modules,iw,hostapd,kiosk]
#                              [-Version 7.0] [-Release] [-MinFrom 6.2] [-Notes "..."] [-DebugSsh]
#
# -Version: the image's version within its train (v7 -> 7.0, 7.1 ...); written into the image
# (/etc/alnasl/image-release) and read back from there by make-release.sh.
# -Release: also cut the system-image release files (scripts/make-release.sh) into .\out\release:
# alnasl-system-v<version>.img.zst, its .json entry, and index.json (.\out\release\index.json from the
# last release is merged in when it is there). They are NOT signed and NOT published: sign them with
# scripts/sign-release.sh on the machine that holds the private key, then upload them by hand.
# A release build refuses the placeholder update key (ALNASL_RELEASE=1 in assemble/verify).
# -DebugSsh: a DEBUG image with sshd on, root by key only (scripts/debug-ssh.pub; the private half stays on the
# PC) and port 22 open off the hotspot. For a box nobody can otherwise reach; never shipped: -Release refuses
# it, and so do assemble.sh and verify.sh. docs/debug-ssh.md.
#
# What it does: ships the Alnasl, Arkab, Polis and Nunki sources (git archive of the tag in versions.json; nothing is built from HEAD, and
# Arkab must equal the tag Alnasl's mix.exs and mix.lock pin) and the scripts to
# the build VM (/root/w-photon-img5 only), runs the stages there, then copies
# the compressed image + SHA256 back into .\out\. Needs ssh/scp (Windows 10+).
# The VM needs: docker (started), qemu-user binfmt for aarch64 (the script
# installs it with tonistiigi/binfmt), curl, xz, losetup, sfdisk, e2fsprogs.
param(
  [string]$Vm = "root@172.16.63.81",
  [string]$Key = "$HOME\.ssh\photon_openpair",
  [string]$AlnasLRepo = (Join-Path $PSScriptRoot "..\Alnasl"),
  [string]$ArkabRepo = (Join-Path $PSScriptRoot "..\arkab"),
  [string]$PolisRepo = (Join-Path $PSScriptRoot "..\polis"),
  [string]$NunkiRepo = (Join-Path $PSScriptRoot "..\nunki"),
  [string[]]$Skip = @(),
  [string]$Version = "7.0",
  [switch]$Release,
  [string]$MinFrom = "",
  [string]$Notes = "",
  [switch]$DebugSsh
)
if ($Version -notmatch '^[0-9]+\.[0-9]+(\.[0-9]+)?$') { throw "-Version must look like 6.1" }
if ($MinFrom -and $MinFrom -notmatch '^[0-9]+\.[0-9]+(\.[0-9]+)?$') { throw "-MinFrom must look like 6.1" }
if ($Notes -match "['`"\\]|\r|\n") { throw "-Notes: no quotes, backslashes or line breaks" }
$Train = "v" + $Version.Split(".")[0]
$Img = "photon-alnasl-$Train.img"
if ($Release -and $DebugSsh) { throw "-DebugSsh is for test images only: a -Release build never has ssh in it" }
$RelEnv = $(if ($Release) { "ALNASL_RELEASE=1" } else { "ALNASL_RELEASE=0" }) + $(if ($DebugSsh) { " ALNASL_DEBUG_SSH=1" } else { " ALNASL_DEBUG_SSH=0" })
$ErrorActionPreference = "Stop"
$here = $PSScriptRoot
$W = "/root/w-photon-img5"
$ssh = @("-i", $Key, "-o", "StrictHostKeyChecking=accept-new")

# "exec 2>&1": the remote shell merges stderr into stdout, otherwise Windows PowerShell 5.1 turns any stderr line into a terminating error.
function Vm-Run([string]$cmd) { & ssh @ssh $Vm "exec 2>&1; $cmd"; if ($LASTEXITCODE -ne 0) { throw "remote command failed: $cmd" } }

$V = & (Join-Path $here "check-versions.ps1") -Root $here -AlnasLRepo $AlnasLRepo -ArkabRepo $ArkabRepo -PolisRepo $PolisRepo -NunkiRepo $NunkiRepo
$Tags = $V.Tags; $Shas = $V.Shas
foreach ($n in @("alnasl", "arkab", "polis", "nunki")) { Write-Host ("== bundle {0,-6} {1}  {2}" -f $n, $Tags[$n], $Shas[$n]) }

Write-Host "== ship"
Vm-Run "mkdir -p $W/alnasl $W/arkab $W/polis $W/nunki $W/setup $W/espeak $W/kiosk"
if ($Skip -notcontains "alnasl") {
  $tar = Join-Path $here "alnasl\alnasl-src.tar"
  git -C $AlnasLRepo archive -o $tar $Tags.alnasl
  & scp @ssh $tar "$Vm`:$W/alnasl/"
}
& scp @ssh (Join-Path $here "alnasl\Dockerfile") "$Vm`:$W/alnasl/"
if ($Skip -notcontains "arkab") {
  # Arkab (the slave mode's program, docs/v6-plan.md section 1): its manifest tag, built like Alnasl's.
  $atar = Join-Path $here "arkab\arkab-src.tar"
  git -C $ArkabRepo archive -o $atar $Tags.arkab
  & scp @ssh $atar "$Vm`:$W/arkab/"
}
& scp @ssh (Join-Path $here "arkab\Dockerfile") "$Vm`:$W/arkab/"
# v7: Polis (the print station) and Nunki (the announcer), each from its manifest tag, built like Arkab.
foreach ($app in @(@{ n = "polis"; repo = $PolisRepo }, @{ n = "nunki"; repo = $NunkiRepo })) {
  if ($Skip -notcontains $app.n) {
    $ptar = Join-Path $here ("{0}\{0}-src.tar" -f $app.n)
    git -C $app.repo archive -o $ptar $Tags[$app.n]
    & scp @ssh $ptar ("{0}:{1}/{2}/" -f $Vm, $W, $app.n)
  }
  & scp @ssh (Join-Path $here ("{0}\Dockerfile" -f $app.n)) ("{0}:{1}/{2}/" -f $Vm, $W, $app.n)
}
# The box's own programs (setup-app: setup server, hotspot + portal, boot screen, system updater): this repository's
# own source at HEAD, so a build is a commit. Uncommitted changes in setup-app are NOT in the image.
if ($Skip -notcontains "setup") {
  if (& git -C $here status --porcelain -- setup-app) { Write-Warning "setup-app has uncommitted changes; the image gets HEAD's setup-app" }
  $star = Join-Path $here "setup-app\setup-src.tar"
  git -C $here archive -o $star HEAD:setup-app
  & scp @ssh $star "$Vm`:$W/setup/"
}
& scp @ssh (Join-Path $here "espeak\Dockerfile") "$Vm`:$W/espeak/"
& scp @ssh (Join-Path $here "kiosk\Dockerfile") (Join-Path $here "kiosk\kiosk.sh") (Join-Path $here "kiosk\kiosk-res.sh") (Join-Path $here "kiosk\policies.json") "$Vm`:$W/kiosk/"
Vm-Run "rm -rf $W/kiosk/ext"
& scp -r @ssh (Join-Path $here "kiosk\ext") "$Vm`:$W/kiosk/"
$scripts = @("build-alnasl.sh", "build-arkab.sh", "build-polis.sh", "build-nunki.sh", "build-setup.sh", "build-espeak.sh", "build-modules.sh", "build-kiosk.sh", "build-iw.sh", "build-hostapd.sh",
  "test-kiosk-logic.sh", "test-scripts.sh", "test-compact-css.sh", "verify.sh", "qemu-smoke.sh", "assemble.sh", "lib-chroot.sh", "prepare-base.sh", "bootscreen.sh", "uboot-env.exs",
  "grub-ab.cfg", "make-release.sh", "release-index.exs", "debug-ssh.pub")
& scp @ssh @($scripts | ForEach-Object { Join-Path $here "scripts\$_" }) "$Vm`:$W/"
& scp @ssh (Join-Path $here "module\Makefile") "$Vm`:$W/module-Makefile"
# v7.3: the small screens' device-tree overlays (build-modules.sh compiles them, *.dts.in once per rotation).
Vm-Run "rm -rf $W/module-dts && mkdir -p $W/module-dts"
& scp @ssh @(Get-ChildItem (Join-Path $here "module") | Where-Object { $_.Name -like "*.dts" -or $_.Name -like "*.dts.in" } | ForEach-Object { $_.FullName }) "$Vm`:$W/module-dts/"
Vm-Run "rm -rf $W/overlay"
& scp -r @ssh (Join-Path $here "overlay") "$Vm`:$W/"
Vm-Run "cd $W && sed -i 's/\r$//' *.sh *.exs grub-ab.cfg kiosk/kiosk.sh kiosk/kiosk-res.sh module-Makefile module-dts/* && find overlay -type f ! -name '*.png' ! -name '*.pgm' ! -name '*.ttf' ! -name alnasl-arkab-pin.txt -exec sed -i 's/\r$//' {} +"

Write-Host "== base image + binfmt"
Vm-Run "bash $W/prepare-base.sh"

if ($Skip -notcontains "alnasl")  { Write-Host "== Alnasl release (arm64, qemu)"; Vm-Run "bash $W/build-alnasl.sh" }
if ($Skip -notcontains "arkab")   { Write-Host "== Arkab release (arm64, qemu)";   Vm-Run "bash $W/build-arkab.sh" }
if ($Skip -notcontains "polis")   { Write-Host "== Polis release (arm64, qemu)";   Vm-Run "bash $W/build-polis.sh" }
if ($Skip -notcontains "nunki")   { Write-Host "== Nunki release (arm64, qemu)";   Vm-Run "bash $W/build-nunki.sh" }
if ($Skip -notcontains "setup")   { Write-Host "== setup-app release (arm64, qemu, tests included)"; Vm-Run "bash $W/build-setup.sh" }
if ($Skip -notcontains "espeak")  { Write-Host "== espeak-ng for Nunki (arm64, qemu)"; Vm-Run "bash $W/build-espeak.sh" }
if ($Skip -notcontains "modules") { Write-Host "== out-of-tree modules";          Vm-Run "bash $W/build-modules.sh" }
if ($Skip -notcontains "iw")      { Write-Host "== iw (userspace tool)";        Vm-Run "bash $W/build-iw.sh" }
if ($Skip -notcontains "hostapd") { Write-Host "== hostapd (setup hotspot)";    Vm-Run "bash $W/build-hostapd.sh" }
if ($Skip -notcontains "kiosk")   { Write-Host "== kiosk container image";        Vm-Run "bash $W/build-kiosk.sh" }

Write-Host "== assemble the image"
Vm-Run "ALNASL_TRAIN=$Train ALNASL_VERSION=$Version $RelEnv bash $W/assemble.sh"

Write-Host "== verify (no hardware)"
Vm-Run "$RelEnv bash $W/verify.sh > $W/verify.log 2>&1; grep -E 'FAIL|WARN' $W/verify.log; tail -n 1 $W/verify.log; true"   # the full log stays in verify.log on the VM

Write-Host "== compress + checksum"
Vm-Run "cd $W && rm -f $Img.xz && xz -T8 -6 -k $Img && sha256sum $Img.xz > $Img.xz.sha256 && ls -la $Img.xz"

Write-Host "== fetch"
$out = Join-Path $here "out"
New-Item -ItemType Directory -Force $out | Out-Null
& scp @ssh "$Vm`:$W/$Img.xz" "$Vm`:$W/$Img.xz.sha256" $out

if ($Release) {
  # The system image of slot A, for boxes that already run v6 or later (updates without reflashing).
  Write-Host "== release files (unsigned, unpublished)"
  $rel = Join-Path $out "release"
  New-Item -ItemType Directory -Force $rel | Out-Null
  Vm-Run "rm -rf $W/release-in && mkdir -p $W/release-in"
  $oldIndex = Join-Path $rel "index.json"
  $idxArg = ""
  if (Test-Path $oldIndex) { & scp @ssh $oldIndex "$Vm`:$W/release-in/index.json"; $idxArg = "--index $W/release-in/index.json" }
  $mf = if ($MinFrom) { "--min-from $MinFrom" } else { "" }
  $nt = if ($Notes) { "--notes '$Notes'" } else { "" }
  Vm-Run "rm -rf $W/release && bash $W/make-release.sh $W/$Img $W/release $mf $idxArg $nt"
  & scp @ssh "$Vm`:$W/release/*" $rel
  Write-Host "release files in $rel. Next, on the machine with the private key:"
  Write-Host "  scripts/sign-release.sh <private key> out/release/index.json out/release/alnasl-system-v$Version.img.zst"
}
Write-Host "done: $out"
