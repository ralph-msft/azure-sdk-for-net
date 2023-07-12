# For details see https://github.com/Azure/azure-sdk-tools/blob/main/doc/common/TypeSpec-Project-Scripts.md

[CmdletBinding()]
param (
    [Parameter(Position=0)]
    [ValidateNotNullOrEmpty()]
    [string] $ProjectDirectory,
    [string] $TypespecAdditionalOptions = $null, ## addtional typespec emitter options, separated by semicolon if more than one, e.g. option1=value1;option2=value2
    [switch] $SaveInputs = $false ## saves the temporary files during execution, default false
)

$ErrorActionPreference = "Stop"
. $PSScriptRoot/Helpers/PSModule-Helpers.ps1
. $PSScriptRoot/common.ps1
Install-ModuleIfNotInstalled "powershell-yaml" "0.4.1" | Import-Module

function NpmInstallForProject([string]$workingDirectory, [bool]$keepLocal) {
    Push-Location $workingDirectory
    try {
        $currentDur = Resolve-Path "."
        Write-Host "Generating from $currentDur"

        if (!$keepLocal) {
            if (Test-Path "package.json") {
                Remove-Item -Path "package.json" -Force
            }

            if (Test-Path ".npmrc") {
                Remove-Item -Path ".npmrc" -Force
            }

            if (Test-Path "node_modules") {
                Remove-Item -Path "node_modules" -Force -Recurse
            }

            if (Test-Path "package-lock.json") {
                Remove-Item -Path "package-lock.json" -Force
            }
        }

        #default to root/eng/emitter-package.json but you can override by writing
        #Get-${Language}-EmitterPackageJsonPath in your Language-Settings.ps1
        $replacementPackageJson = Join-Path $PSScriptRoot "../../emitter-package.json"
        if (Test-Path "Function:$GetEmitterPackageJsonPathFn") {
            $replacementPackageJson = &$GetEmitterPackageJsonPathFn
        }

        Write-Host("Copying package.json from $replacementPackageJson")
        Copy-Item -Path $replacementPackageJson -Destination "package.json" -Force

        $useAlphaNpmRegistry = (Get-Content $replacementPackageJson -Raw).Contains("-alpha.")

        if($useAlphaNpmRegistry) {
            Write-Host "Package.json contains '-alpha.' in the version, Creating .npmrc using public/azure-sdk-for-js-test-autorest feed."
            "registry=https://pkgs.dev.azure.com/azure-sdk/public/_packaging/azure-sdk-for-js-test-autorest/npm/registry/ `n`nalways-auth=true" | Out-File '.npmrc'
        }

        $npmCommand = "npm install"
        if (!$keepLocal) {
            $npmCommand += " --no-package-lock"
        }

        Invoke-Expression $npmCommand

        if ($LASTEXITCODE) { exit $LASTEXITCODE }
    }
    finally {
        Pop-Location
    }
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

$resolvedProjectDirectory = Resolve-Path $ProjectDirectory
$emitterName = &$GetEmitterNameFn
$typespecConfigurationFile = Join-Path $resolvedProjectDirectory "tsp-location.yaml"

Write-Host "Reading configuration from $typespecConfigurationFile"
$configuration = Get-Content -Path $typespecConfigurationFile -Raw | ConvertFrom-Yaml

$specSubDirectory = $configuration["directory"]
$innerFolder = Split-Path $specSubDirectory -Leaf
$updateFromTypeSpecRepo = $ENV:AZURE_DEV_UPDATEFROMTYPESPECCLONE -eq "1"

if ($updateFromTypeSpecRepo) {
  $cloneDir = $configuration["cloneDir"]
  if (!$cloneDir) {
    $cloneDir = GetSpecCloneDir $(Split-Path $resolvedProjectDirectory -Leaf)
    $cloneDir = Resolve-Path $cloneDir
  }
  else {
    # clone directory may be relative to tsp-location.yaml file so change to that directory
    Push-Location (Split-Path -Parent $typespecConfigurationFile)
    try {
      $cloneDir = Resolve-Path $cloneDir
    }
    finally {
      Pop-Location
    }
  }

  $tempFolder = Join-Path "$cloneDir" "$specSubDirectory"
  $npmWorkingDir = $tempFolder
}
else {
    $tempFolder = Resolve-Path (Join-Path $ProjectDirectory "TempTypeSpecFiles")
    $npmWorkingDir = Join-Path $tempFolder $innerFolder
}

$mainTypeSpecFile = If (Test-Path "$npmWorkingDir/client.*") { Resolve-Path "$npmWorkingDir/client.*" } Else { Resolve-Path "$npmWorkingDir/main.*"}

try {
    Push-Location $npmWorkingDir
    NpmInstallForProject $npmWorkingDir $updateFromTypeSpecRepo

    if ($LASTEXITCODE) { exit $LASTEXITCODE }

    if (Test-Path "Function:$GetEmitterAdditionalOptionsFn") {
        $emitterAdditionalOptions = &$GetEmitterAdditionalOptionsFn $resolvedProjectDirectory
        if ($emitterAdditionalOptions.Length -gt 0) {
            $emitterAdditionalOptions = " $emitterAdditionalOptions"
        }
    }
    $typespecCompileCommand = "npx tsp compile $mainTypeSpecFile --emit $emitterName$emitterAdditionalOptions"
    if ($TypespecAdditionalOptions) {
        $options = $TypespecAdditionalOptions.Split(";");
        foreach ($option in $options) {
            $typespecCompileCommand += " --option $emitterName.$option"
        }
    }

    if ($SaveInputs) {
        $typespecCompileCommand += " --option $emitterName.save-inputs=true"
    }

    Write-Host($typespecCompileCommand)
    Invoke-Expression $typespecCompileCommand

    if ($LASTEXITCODE) { exit $LASTEXITCODE }
}
finally {
    Pop-Location
}

$shouldCleanUp = !($SaveInputs -or $updateFromTypeSpecRepo)
if ($shouldCleanUp) {
    Remove-Item $tempFolder -Recurse -Force
}
exit 0
