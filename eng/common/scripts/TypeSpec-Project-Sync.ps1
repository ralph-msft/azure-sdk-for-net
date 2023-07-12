# For details see https://github.com/Azure/azure-sdk-tools/blob/main/doc/common/TypeSpec-Project-Scripts.md

[CmdletBinding()]
param (
  [Parameter(Position = 0)]
  [ValidateNotNullOrEmpty()]
  [string] $ProjectDirectory,
  [Parameter(Position = 1)]
  [string] $LocalSpecRepoPath
)

$ErrorActionPreference = "Stop"
. $PSScriptRoot/Helpers/PSModule-Helpers.ps1
Install-ModuleIfNotInstalled "powershell-yaml" "0.4.1" | Import-Module
$sparseCheckoutFile = ".git/info/sparse-checkout"

function AddSparseCheckoutPath([string]$subDirectory) {
  if (!(Test-Path $sparseCheckoutFile) -or !((Get-Content $sparseCheckoutFile).Contains($subDirectory))) {
    Write-Output $subDirectory >> .git/info/sparse-checkout
  }
}

function CopySpecToProjectIfNeeded([string]$specCloneRoot, [string]$mainSpecDir, [string]$dest, [string[]]$specAdditionalSubDirectories) {
  $source = Join-Path $specCloneRoot $mainSpecDir "*"
  $dest = Join-Path $dest (Split-Path $mainSpecDir -Leaf)
  New-Item -Path $dest -ItemType Directory -Force | Out-Null
  Write-Host "Copying spec from $source to $dest"
  Copy-Item -Path $source -Destination $dest -Recurse -Force -Exclude @("node_modules", ".package_lock.json", "package_lock.json")

  foreach ($additionalDir in $specAdditionalSubDirectories) {
    $source = Join-Path $specCloneRoot $additionalDir
    Write-Host "Copying spec from $source to $dest"
    Copy-Item -Path $source -Destination $dest -Recurse -Force
  }
}

function UpdateSparseCheckoutFile([string]$mainSpecDir, [string[]]$specAdditionalSubDirectories) {
  AddSparseCheckoutPath $mainSpecDir
  foreach ($subDir in $specAdditionalSubDirectories) {
    Write-Host "Adding $subDir to sparse checkout"
    AddSparseCheckoutPath $subDir
  }
}

function GetGitRemoteValue([string]$repo) {
  Push-Location $ProjectDirectory
  $result = ""
  try {
    $gitRemotes = (git remote -v)
    foreach ($remote in $gitRemotes) {
      Write-Host "Checking remote $remote"
      if ($remote.StartsWith("origin") -or $remote.StartsWith("main")) {
        if ($remote -match 'https://(.*)?github.com/\S+') {
          $result = "https://github.com/$repo.git"
          break
        }
        elseif ($remote -match "(.*)?git@github.com:\S+") {
          $result = "git@github.com:$repo.git"
          break
        }
        else {
          throw "Unknown git remote format found: $remote"
        }
      }
    }
  }
  finally {
    Pop-Location
  }
  Write-Host "Found git remote $result"
  return $result
}

function GetGitInfo([string]$cloneDir) {
  $info = @{
    "dir" = resolve-path $cloneDir
    "url" = $null
    "repo" = $null
    "commit" = $null
  }

  Push-Location $info.dir
  try {
    [uri]$info.url = (git config --get remote.origin.url) ?? (git config --get remote.main.url)
    if (!$info.url) {
        throw "'$($info.dir)' does not appear to be a GitHub repo"
    }

    if ($info.url.IsAbsoluteUri) {
      if ($info.url.Scheme -ne "https" -or $info.url.Host -notlike "*github.com") {
        throw "'$($info.dir)' is not a GitHub repo ($($info.url))"
      }

      $info.repo = $info.url.LocalPath.TrimStart("/").TrimEnd(".git")
    }
    elseif ($info.url.OriginalString -match "^git@github.com:(?<subPath>.*)\.git") {
      $info.repo = $Matches.subPath
    }
    else {
      throw "'$($info.dir)' has an unknown git remote format ($($info.url))"
    }

    $info.commit = $(git log --format="%H" -n 1)
  }
  finally {
    Pop-Location
  }

  return $info
}

function InitializeSparseGitClone([string]$repo) {
  git clone --no-checkout --filter=tree:0 $repo .
  if ($LASTEXITCODE) { exit $LASTEXITCODE }
  git sparse-checkout init
  if ($LASTEXITCODE) { exit $LASTEXITCODE }
  Remove-Item $sparseCheckoutFile -Force
}

function GetSpecCloneDir([string]$projectName) {
  Push-Location $ProjectDirectory
  try {
    $root = git rev-parse --show-toplevel
  }
  finally {
    Pop-Location
  }

  return "$root/../sparse-spec/$projectName"
}

function ConvertToOrderedDictionary() {
  [CmdletBinding()]
  param (
    [Parameter(Mandatory,ValueFromPipeline)]
    [ValidateNotNullOrEmpty()]
    [hashtable] $hash
  )
  $ordered = [ordered]@{}
  foreach ($key in ($hash.Keys | Sort-Object)) {
    $ordered.Add($key, $hash[$key])
  }
  return $ordered
}

$typespecConfigurationFile = Resolve-Path "$ProjectDirectory/tsp-location.yaml"
Write-Host "Reading configuration from $typespecConfigurationFile"
$configuration = Get-Content -Path $typespecConfigurationFile -Raw | ConvertFrom-Yaml | ConvertToOrderedDictionary

$pieces = $typespecConfigurationFile.Path.Replace("\", "/").Split("/")
$projectName = $pieces[$pieces.Count - 2]

$specSubDirectory = $configuration["directory"]
$gitCloneNeeded = $false;
$updateFromTypeSpecRepo = $ENV:AZURE_DEV_UPDATEFROMTYPESPECCLONE -eq "1"

if ($updateFromTypeSpecRepo) {
  $specCloneDir = $configuration["cloneDir"]
  if (!$specCloneDir) {
    $specCloneDir = GetSpecCloneDir $projectName
    if (Test-Path $specCloneDir) {
      $specCloneDir = Resolve-Path $specCloneDir
    }
    else {
      $gitCloneNeeded = $true
    }
  }
  else {
    # clone directory may be relative to tsp-location.yaml file so change to that directory
    Push-Location (Split-Path -Parent $typespecConfigurationFile)
    try {
      if (!(Test-Path $specCloneDir)) {
        $gitCloneNeeded = $true
        New-Item "$specCloneDir" -ItemType Directory -Force | Out-Null
      }

      $specCloneDir = Resolve-Path $specCloneDir
    }
    finally {
      Pop-Location
    }
  }

  Write-Warning "Auto updating from TypeSpec local clone: '$specCloneDir'"
}
# use local spec repo if provided
elseif ($LocalSpecRepoPath) {
  $specCloneDir = $LocalSpecRepoPath
}
else {
  $specCloneDir = GetSpecCloneDir $projectName
  $gitCloneNeeded = $true
}

# use sparse clone if repo and commit are provided
if ($gitCloneNeeded) {
  if (!($configuration["repo"] -and $configuration["commit"])) {
     # write error if neither local spec repo nor repo and commit are provided
    Write-Error "Must contain both 'repo' and 'commit' in tsp-location.yaml or input 'localSpecRepoPath' parameter."
    exit 1
  }

  $gitRemoteValue = GetGitRemoteValue $configuration["repo"]

  Write-Host "from tsplocation.yaml 'repo' is:"$configuration["repo"]
  Write-Host "Setting up sparse clone for $projectName at $specCloneDir"

  if (!(Test-Path $specCloneDir)) {
    New-Item "$specCloneDir" -ItemType Directory -Force | Out-Null
  }
  $specCloneDir = Resolve-Path $specCloneDir

  Push-Location $specCloneDir.Path
  try {
    if (!(Test-Path ".git")) {
      Write-Host "Initializing sparse clone for repo: $gitRemoteValue"
      InitializeSparseGitClone $gitRemoteValue
    }
    Write-Host "Updating sparse checkout file with directory:$specSubDirectory"
    UpdateSparseCheckoutFile $specSubDirectory $configuration["additionalDirectories"]
    $commit = $configuration["commit"]
    Write-Host "git checkout commit: $commit"
    git checkout $configuration["commit"]
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
  }
  finally {
    Pop-Location
  }
}

if ($updateFromTypeSpecRepo) {
  $gitInfo = GetGitInfo $specCloneDir

  # update rempote url and commit as needed
  if (($gitInfo.repo -ne $configuration["repo"]) -or ($gitInfo.commit -ne $configuration["commit"])) {
    Write-Warning "Updating tsp-location.yaml with new repo and/or commit"
    $configuration["repo"] = $gitInfo.repo
    $configuration["commit"] = $gitInfo.commit

    $configuration | ConvertTo-Yaml | Out-File $typespecConfigurationFile -Encoding utf8NoBOM
  }
}
else {
  $tempTypeSpecDir = "$ProjectDirectory/TempTypeSpecFiles"
  New-Item $tempTypeSpecDir -Type Directory -Force | Out-Null
  CopySpecToProjectIfNeeded `
    -specCloneRoot $specCloneDir `
    -mainSpecDir $specSubDirectory `
    -dest $tempTypeSpecDir `
    -specAdditionalSubDirectories $configuration["additionalDirectories"]
}

exit 0
