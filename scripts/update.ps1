# Cutpurse Ledger updater for Windows, for players who don't use an addon manager.
# Downloads the latest release (addon + fresh prices) and installs it into your
# WoW: Forever AddOns folder. Nothing else is needed: no git, no account.
#
#   powershell -ExecutionPolicy Bypass -File update.ps1
#   powershell -ExecutionPolicy Bypass -File update.ps1 -AddOns "E:\Games\World of Warcraft\_forever_\Interface\AddOns"

param(
  [string]$AddOns = "",
  [string]$Repo = "villelejonet-source/CutpurseLedger"
)
$ErrorActionPreference = "Stop"

# Find the AddOns folder if it wasn't given
if (-not $AddOns) {
  $candidates = @()
  foreach ($key in "HKLM:\SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft", "HKLM:\SOFTWARE\Blizzard Entertainment\World of Warcraft") {
    try { $p = (Get-ItemProperty $key -ErrorAction Stop).InstallPath; if ($p) { $candidates += (Split-Path $p -Parent) } } catch {}
  }
  foreach ($d in Get-PSDrive -PSProvider FileSystem) {
    foreach ($sub in "World of Warcraft", "Games\World of Warcraft", "Program Files (x86)\World of Warcraft", "Program Files\World of Warcraft", "wow\World of Warcraft") {
      $candidates += Join-Path $d.Root $sub
    }
  }
  foreach ($c in $candidates) {
    $try = Join-Path $c "_forever_\Interface\AddOns"
    if (Test-Path (Join-Path $c "_forever_")) { New-Item -ItemType Directory -Force $try | Out-Null; $AddOns = $try; break }
  }
  if (-not $AddOns) { throw "Couldn't find WoW: Forever. Run again with -AddOns ""<your _forever_\Interface\AddOns folder>""" }
}

$release = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ "User-Agent" = "CutpurseLedger-updater" }
$asset = $release.assets | Where-Object { $_.name -like "*.zip" } | Select-Object -First 1
if (-not $asset) { throw "The latest release has no zip file." }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("CutpurseLedger-" + [guid]::NewGuid())
New-Item -ItemType Directory $tmp | Out-Null
try {
  $zip = Join-Path $tmp $asset.name
  Invoke-WebRequest $asset.browser_download_url -OutFile $zip -UseBasicParsing
  Expand-Archive $zip -DestinationPath (Join-Path $tmp "x")
  # Check the download has both folders before removing anything, so a bad
  # release can't leave you without the addon.
  foreach ($folder in "LootLedger", "LootLedger_Prices") {
    if (-not (Test-Path (Join-Path $tmp "x\$folder\$folder.toc"))) {
      throw "The release $($release.name) has no $folder folder; nothing was changed."
    }
  }
  foreach ($folder in "LootLedger", "LootLedger_Prices") {
    $dest = Join-Path $AddOns $folder
    if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
    Copy-Item -Recurse (Join-Path $tmp "x\$folder") $dest
  }
} finally {
  Remove-Item -Recurse -Force $tmp
}
"Installed $($release.name)"
"into $AddOns"
"Restart WoW or type /reload to load it."
