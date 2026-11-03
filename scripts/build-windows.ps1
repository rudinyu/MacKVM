[CmdletBinding()]
param(
    [ValidateSet("x64", "arm64", "both")]
    [string]$Architecture = "x64",

    [ValidateSet("debug", "release")]
    [string]$Configuration = "release",

    [string]$Project = "WindowsKVM/src/WindowsKVM.Desktop/WindowsKVM.Desktop.csproj",

    [string]$OutputDirectory = "",

    # Use -Plan on macOS to print the Windows publish commands without
    # invoking a Windows toolchain or creating an executable.
    [switch]$Plan
)

$ErrorActionPreference = "Stop"

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([System.IO.Path]::IsPathRooted($Project)) {
    $projectPath = [System.IO.Path]::GetFullPath($Project)
} else {
    $projectPath = [System.IO.Path]::GetFullPath((Join-Path $projectRoot $Project))
}

if (-not (Test-Path -LiteralPath $projectPath -PathType Leaf)) {
    throw "Windows project was not found at $projectPath"
}

$outputDirectoryWasDefault = [string]::IsNullOrWhiteSpace($OutputDirectory)
if ($outputDirectoryWasDefault) {
    $OutputDirectory = Join-Path $projectRoot "dist/windows"
} elseif (-not [System.IO.Path]::IsPathRooted($OutputDirectory)) {
    $OutputDirectory = Join-Path $projectRoot $OutputDirectory
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)

# A custom output is allowed outside the checkout for local experiments, but
# a path inside the repository must stay below `dist`. This prevents a typo
# such as `-OutputDirectory .` from deleting source files when the clean step
# runs. The default path is always the repository's `dist` directory.
$pathSeparatorChars = [char[]]@(
    [System.IO.Path]::DirectorySeparatorChar
    [System.IO.Path]::AltDirectorySeparatorChar
)
$projectRootPath = [System.IO.Path]::GetFullPath($projectRoot).TrimEnd($pathSeparatorChars)
$distRootPath = [System.IO.Path]::GetFullPath((Join-Path $projectRoot "dist")).TrimEnd($pathSeparatorChars)
$normalizedOutputPath = $OutputDirectory.TrimEnd($pathSeparatorChars)
$repositoryPrefix = $projectRootPath + [System.IO.Path]::DirectorySeparatorChar
$distPrefix = $distRootPath + [System.IO.Path]::DirectorySeparatorChar
$outputIsRepositoryRoot = $normalizedOutputPath.Equals(
    $projectRootPath,
    [System.StringComparison]::OrdinalIgnoreCase
)
$outputIsInsideRepository = $normalizedOutputPath.StartsWith(
    $repositoryPrefix,
    [System.StringComparison]::OrdinalIgnoreCase
)
$outputIsDist = $normalizedOutputPath.Equals(
    $distRootPath,
    [System.StringComparison]::OrdinalIgnoreCase
) -or $normalizedOutputPath.StartsWith(
    $distPrefix,
    [System.StringComparison]::OrdinalIgnoreCase
)
if (($outputIsRepositoryRoot -or $outputIsInsideRepository) -and -not $outputIsDist) {
    throw "Custom -OutputDirectory must be outside the repository or inside dist: $OutputDirectory"
}

$configurationName = $Configuration.Substring(0, 1).ToUpperInvariant() +
    $Configuration.Substring(1).ToLowerInvariant()

$architectureTargets = @{
    x64 = @{
        Label = "x64"
        Rid = "win-x64"
        Machine = "x64"
    }
    arm64 = @{
        Label = "arm64"
        Rid = "win-arm64"
        Machine = "arm64"
    }
}

if ($Architecture -eq "both") {
    $buildTargets = @($architectureTargets.x64, $architectureTargets.arm64)
} else {
    $buildTargets = @($architectureTargets[$Architecture])
}

function Get-PeMachine {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = [System.IO.File]::OpenRead($Path)
    $reader = [System.IO.BinaryReader]::new($stream)
    try {
        $stream.Seek(0x3C, [System.IO.SeekOrigin]::Begin) | Out-Null
        $peHeaderOffset = $reader.ReadInt32()
        $stream.Seek($peHeaderOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
        $signature = $reader.ReadBytes(4)
        if ($signature.Length -ne 4 -or
            $signature[0] -ne 0x50 -or
            $signature[1] -ne 0x45 -or
            $signature[2] -ne 0x00 -or
            $signature[3] -ne 0x00) {
            throw "The output is not a PE executable: $Path"
        }

        switch ($reader.ReadUInt16()) {
            0x014C { return "x86" }
            0x8664 { return "x64" }
            0xAA64 { return "arm64" }
            default { return "unknown" }
        }
    } finally {
        $reader.Dispose()
    }
}

function Clear-GeneratedDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $separatorChars = [char[]]@(
        [System.IO.Path]::DirectorySeparatorChar
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $trimmedPath = $fullPath.TrimEnd($separatorChars)
    $rootPath = [System.IO.Path]::GetPathRoot($fullPath).TrimEnd($separatorChars)

    if ([string]::IsNullOrWhiteSpace($trimmedPath) -or $trimmedPath -eq $rootPath) {
        throw "Refusing to clean a filesystem root: $fullPath"
    }

    if (Test-Path -LiteralPath $fullPath) {
        $existing = Get-Item -LiteralPath $fullPath -Force
        if (-not $existing.PSIsContainer) {
            throw "Build output path is a file, not a directory: $fullPath"
        }
        if (($existing.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing to clean a reparse point: $fullPath"
        }
        Remove-Item -LiteralPath $fullPath -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $fullPath | Out-Null
}

function Copy-ResolvedWindowsRuntimeNotices {
    param(
        [Parameter(Mandatory = $true)][string]$StateDirectory,
        [Parameter(Mandatory = $true)][string]$RuntimeIdentifier,
        [Parameter(Mandatory = $true)][string]$OutputDirectory,
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [Parameter(Mandatory = $true)][string]$NuGetPackageRoot
    )

    $runtimePackageId = "Microsoft.NETCore.App.Runtime.$RuntimeIdentifier"
    $runtimepackId = "runtimepack.$runtimePackageId"
    $sdkPackageId = "Microsoft.Windows.SDK.NET.Ref"
    $sdkRuntimepackId = "runtimepack.$sdkPackageId"

    function Get-ExactJsonProperties {
        param([object]$Object, [Parameter(Mandatory = $true)][string]$Name)
        if ($null -eq $Object) { return @() }
        return @($Object.PSObject.Properties | Where-Object {
            [System.String]::Equals($_.Name, $Name, [System.StringComparison]::OrdinalIgnoreCase)
        })
    }

    function Get-ValidatedPackageVersion {
        param([object]$Value, [Parameter(Mandatory = $true)][string]$Description)
        $version = [string]$Value
        if ($version -notmatch '^[A-Za-z0-9._+-]+$') {
            throw "The $Description version is invalid: $version"
        }
        return $version
    }

    function Get-ExactNuGetPackageDirectory {
        param(
            [Parameter(Mandatory = $true)][string]$PackageId,
            [Parameter(Mandatory = $true)][string]$Version
        )
        if (-not (Test-Path -LiteralPath $NuGetPackageRoot -PathType Container)) {
            throw "The NuGet global-packages directory is missing: $NuGetPackageRoot"
        }
        $rootItem = Get-Item -LiteralPath $NuGetPackageRoot -Force
        if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing a reparse-point NuGet global-packages directory: $NuGetPackageRoot"
        }
        $packageIdDirectory = Join-Path $NuGetPackageRoot $PackageId.ToLowerInvariant()
        $candidate = Join-Path $packageIdDirectory $Version.ToLowerInvariant()
        foreach ($path in @($packageIdDirectory, $candidate)) {
            if (-not (Test-Path -LiteralPath $path -PathType Container)) {
                throw "Could not find the exact $PackageId/$Version package in the NuGet global-packages directory $NuGetPackageRoot."
            }
            $item = Get-Item -LiteralPath $path -Force
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing a reparse-point NuGet package directory: $path"
            }
        }
        $separator = [System.IO.Path]::DirectorySeparatorChar
        $rootFullPath = [System.IO.Path]::GetFullPath($NuGetPackageRoot).TrimEnd([char[]]@($separator))
        $candidateFullPath = [System.IO.Path]::GetFullPath($candidate)
        if (-not $candidateFullPath.StartsWith(
                $rootFullPath + $separator,
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
            throw "The resolved $PackageId/$Version package escapes the NuGet global-packages directory: $candidate"
        }
        return $candidate
    }

    if (-not (Test-Path -LiteralPath $StateDirectory -PathType Container)) {
        throw "Generated build state was not found while resolving ${runtimePackageId}: $StateDirectory"
    }
    $stateItem = Get-Item -LiteralPath $StateDirectory -Force
    if (($stateItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing a reparse-point generated build-state directory: $StateDirectory"
    }
    $appProjectName = [System.IO.Path]::GetFileNameWithoutExtension($ProjectPath)
    $generatedBinRoot = Join-Path $StateDirectory "bin"
    if (-not (Test-Path -LiteralPath $generatedBinRoot -PathType Container)) {
        throw "Could not find the generated app bin directory: $generatedBinRoot"
    }
    $generatedBinItem = Get-Item -LiteralPath $generatedBinRoot -Force
    if (($generatedBinItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing a reparse-point generated app bin directory: $generatedBinRoot"
    }
    $appBinRoot = Join-Path $generatedBinRoot $appProjectName
    if (-not (Test-Path -LiteralPath $appBinRoot -PathType Container)) {
        throw "Could not find the app publish metadata directory for ${ProjectPath}: $appBinRoot"
    }
    $appBinItem = Get-Item -LiteralPath $appBinRoot -Force
    if (($appBinItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing a reparse-point app publish metadata directory: $appBinRoot"
    }

    $depsFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $directories = [System.Collections.Generic.Stack[string]]::new()
    $directories.Push($appBinRoot)
    while ($directories.Count -gt 0) {
        $directory = $directories.Pop()
        foreach ($entry in @(Get-ChildItem -LiteralPath $directory -Force)) {
            if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing a reparse point in the generated app metadata directory: $($entry.FullName)"
            }
            if ($entry.PSIsContainer) {
                $directories.Push($entry.FullName)
            } elseif ($entry.Name.EndsWith(".deps.json", [System.StringComparison]::OrdinalIgnoreCase)) {
                $depsFiles.Add($entry)
            }
        }
    }
    if ($depsFiles.Count -ne 1) {
        throw "Expected exactly one generated app .deps.json under $appBinRoot; found $($depsFiles.Count)."
    }

    $depsPath = $depsFiles[0].FullName
    $runtimeConfigPath = $depsPath.Substring(0, $depsPath.Length - ".deps.json".Length) + ".runtimeconfig.json"
    try {
        $deps = Get-Content -LiteralPath $depsPath -Raw | ConvertFrom-Json
    } catch {
        throw "Could not read generated app .deps.json at ${depsPath}: $($_.Exception.Message)"
    }
    if (-not (Test-Path -LiteralPath $runtimeConfigPath -PathType Leaf)) {
        throw "The generated app .runtimeconfig.json is missing: $runtimeConfigPath"
    }
    $runtimeConfigItem = Get-Item -LiteralPath $runtimeConfigPath -Force
    if (($runtimeConfigItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing a reparse-point app .runtimeconfig.json: $runtimeConfigPath"
    }
    try {
        $runtimeConfig = Get-Content -LiteralPath $runtimeConfigPath -Raw | ConvertFrom-Json
    } catch {
        throw "Could not read generated app .runtimeconfig.json at ${runtimeConfigPath}: $($_.Exception.Message)"
    }

    $runtimeTargetName = [string]$deps.runtimeTarget.name
    if (-not $runtimeTargetName.EndsWith("/$RuntimeIdentifier", [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "The app .deps.json does not select the requested runtime identifier ${RuntimeIdentifier}: $runtimeTargetName"
    }
    $targetProperties = @(Get-ExactJsonProperties -Object $deps.targets -Name $runtimeTargetName)
    if ($targetProperties.Count -ne 1) {
        throw "The selected publish target is missing or ambiguous in ${depsPath}: $runtimeTargetName"
    }
    $targetEntries = $targetProperties[0].Value
    $libraries = $deps.libraries
    if ($null -eq $libraries) {
        throw "The app .deps.json has no libraries map: $depsPath"
    }

    $frameworks = @($runtimeConfig.runtimeOptions.includedFrameworks)
    $coreFrameworks = @($frameworks | Where-Object {
        $null -ne $_ -and $_.name -is [string] -and
        [System.String]::Equals($_.name, "Microsoft.NETCore.App", [System.StringComparison]::OrdinalIgnoreCase)
    })
    if ($coreFrameworks.Count -ne 1) {
        throw "Expected exactly one Microsoft.NETCore.App entry in $runtimeConfigPath; found $($coreFrameworks.Count)."
    }
    $coreVersion = Get-ValidatedPackageVersion -Value $coreFrameworks[0].version -Description "Microsoft.NETCore.App framework"

    $appTargets = @()
    foreach ($targetProperty in $targetEntries.PSObject.Properties) {
        $matchingLibraries = @(Get-ExactJsonProperties -Object $libraries -Name $targetProperty.Name)
        $dependencies = $targetProperty.Value.dependencies
        $coreDependencies = @(Get-ExactJsonProperties -Object $dependencies -Name $runtimepackId)
        if ($matchingLibraries.Count -eq 1 -and
            [string]$matchingLibraries[0].Value.type -eq "project" -and
            $coreDependencies.Count -gt 0) {
            $appTargets += [pscustomobject]@{
                Key = $targetProperty.Name
                Dependencies = $dependencies
                CoreDependencies = $coreDependencies
            }
        }
    }
    if ($appTargets.Count -ne 1) {
        throw "Expected exactly one app target depending on $runtimepackId in ${depsPath}; found $($appTargets.Count)."
    }
    $appTarget = $appTargets[0]
    if ($appTarget.CoreDependencies.Count -ne 1) {
        throw "Expected exactly one $runtimepackId dependency in app target $($appTarget.Key); found $($appTarget.CoreDependencies.Count)."
    }
    $dependencyVersion = Get-ValidatedPackageVersion -Value $appTarget.CoreDependencies[0].Value -Description $runtimepackId
    if ($dependencyVersion -ne $coreVersion) {
        throw "The app .deps.json $runtimepackId version does not match the self-contained runtimeconfig version $coreVersion."
    }

    function Get-RequiredRuntimePackTarget {
        param(
            [Parameter(Mandatory = $true)][string]$PackageId,
            [Parameter(Mandatory = $true)][string]$Version
        )
        $key = "$PackageId/$Version"
        $targetMatches = @(Get-ExactJsonProperties -Object $targetEntries -Name $key)
        $libraryMatches = @(Get-ExactJsonProperties -Object $libraries -Name $key)
        if ($targetMatches.Count -ne 1 -or $libraryMatches.Count -ne 1) {
            throw "Expected exactly one $key runtimepack entry in the selected app target and libraries of ${depsPath}."
        }
        if ([string]$libraryMatches[0].Value.type -ne "runtimepack") {
            throw "The resolved $key entry in ${depsPath} is not a runtimepack."
        }
        return $targetMatches[0].Value
    }

    $runtimeTargetEntry = Get-RequiredRuntimePackTarget -PackageId $runtimepackId -Version $coreVersion
    if ($null -eq $runtimeTargetEntry.runtime) {
        throw "The resolved $runtimepackId/$coreVersion has no runtime assets in $depsPath."
    }
    $runtimePackageDirectory = Get-ExactNuGetPackageDirectory -PackageId $runtimePackageId -Version $coreVersion

    $assetsToStage = @(
        "LICENSE.TXT",
        "THIRD-PARTY-NOTICES.TXT"
    )
    $stagedAssets = @()
    foreach ($assetName in $assetsToStage) {
        $sourcePath = Join-Path $runtimePackageDirectory $assetName
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw "Required .NET runtime legal asset is missing: $sourcePath (resolved from $runtimePackageId/$coreVersion; app deps: $depsPath)."
        }
        $sourceItem = Get-Item -LiteralPath $sourcePath -Force
        if (($sourceItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing a reparse-point .NET runtime legal asset: $sourcePath"
        }
        $destinationName = "dotnet-$runtimePackageId-$coreVersion-$assetName"
        $stagedAssets += [pscustomobject]@{
            Source = $sourcePath
            Destination = Join-Path $OutputDirectory $destinationName
        }
    }

    $mackvmLicense = Join-Path $projectRoot "LICENSE"
    if (-not (Test-Path -LiteralPath $mackvmLicense -PathType Leaf)) {
        throw "MacKVM's root MIT license was not found at $mackvmLicense."
    }
    if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
        throw "Architecture output directory was not found while staging legal assets: $OutputDirectory"
    }
    $outputItem = Get-Item -LiteralPath $OutputDirectory -Force
    if (-not $outputItem.PSIsContainer -or
        ($outputItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to stage legal assets into an unsafe architecture output directory: $OutputDirectory"
    }

    $dotnetLibraryLicenseNotice = @(
        "Microsoft identifies CoreCLR and .NET runtimes included in Windows single-file applications as governed by the .NET Library License."
        "Full terms: https://dotnet.microsoft.com/en-us/dotnet_library_license.htm"
        "Windows .NET licensing information: https://github.com/dotnet/core/blob/main/license-information-windows.md"
        "This file is a reference pointer, not a copy or substitute for Microsoft's complete license terms."
    ) -join [Environment]::NewLine

    $sdkReferenceNotice = $null
    $sdkDependencies = @(Get-ExactJsonProperties -Object $appTarget.Dependencies -Name $sdkRuntimepackId)
    if ($sdkDependencies.Count -gt 1) {
        throw "Expected at most one $sdkRuntimepackId dependency in app target $($appTarget.Key); found $($sdkDependencies.Count)."
    }
    if ($sdkDependencies.Count -eq 1) {
        $sdkVersion = Get-ValidatedPackageVersion -Value $sdkDependencies[0].Value -Description $sdkRuntimepackId
        $sdkTargetEntry = Get-RequiredRuntimePackTarget -PackageId $sdkRuntimepackId -Version $sdkVersion
        if ($null -eq $sdkTargetEntry.runtime) {
            throw "The resolved $sdkRuntimepackId/$sdkVersion has no runtime assembly entries in $depsPath."
        }
        $sdkRuntimeProperties = @($sdkTargetEntry.runtime.PSObject.Properties)
        if ($sdkRuntimeProperties.Count -eq 0) {
            throw "The resolved $sdkRuntimepackId/$sdkVersion has no runtime assembly entries in $depsPath."
        }
        $sdkAssemblies = [System.Collections.Generic.List[string]]::new()
        foreach ($runtimeProperty in $sdkRuntimeProperties) {
            $assemblyName = [string]$runtimeProperty.Name
            if ($assemblyName -notmatch '^[A-Za-z0-9_.-]+\.dll$') {
                throw "Unsafe or unexpected Windows SDK runtime assembly entry in ${depsPath}: $assemblyName"
            }
            $sdkAssemblies.Add($assemblyName)
        }
        $sdkAssembliesArray = $sdkAssemblies.ToArray()
        [Array]::Sort($sdkAssembliesArray, [System.StringComparer]::OrdinalIgnoreCase)
        $sdkPackageDirectory = Get-ExactNuGetPackageDirectory -PackageId $sdkPackageId -Version $sdkVersion

        $sdkPackageMetadata = @()
        foreach ($nuspecFile in @(Get-ChildItem -LiteralPath $sdkPackageDirectory -Filter "*.nuspec" -File)) {
            if (($nuspecFile.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing a reparse-point Windows SDK package specification: $($nuspecFile.FullName)"
            }
            try {
                [xml]$nuspec = Get-Content -LiteralPath $nuspecFile.FullName -Raw
            } catch {
                throw "Could not read resolved Windows SDK package metadata at $($nuspecFile.FullName): $($_.Exception.Message)"
            }
            $idNode = $nuspec.SelectSingleNode("//*[local-name()='id']")
            if ($null -ne $idNode -and $idNode.InnerText -eq $sdkPackageId) {
                $licenseNode = $nuspec.SelectSingleNode("//*[local-name()='licenseUrl']")
                $licenseUrl = if ($null -ne $licenseNode) { $licenseNode.InnerText.Trim() } else { "" }
                if ($licenseUrl -notmatch '^https://') {
                    throw "The resolved $sdkPackageId/$sdkVersion package metadata has no HTTPS licenseUrl: $($nuspecFile.FullName)"
                }
                $sdkPackageMetadata += [pscustomobject]@{
                    Nuspec = $nuspecFile.FullName
                    LicenseUrl = $licenseUrl
                }
            }
        }
        if ($sdkPackageMetadata.Count -ne 1) {
            throw "Expected exactly one $sdkPackageId NuGet specification in $sdkPackageDirectory; found $($sdkPackageMetadata.Count)."
        }
        $sdkReferenceNotice = @(
            "Windows SDK .NET runtime assemblies included by this publish."
            "Resolved package: $sdkPackageId $sdkVersion"
            "Included assemblies: $($sdkAssembliesArray -join ', ')"
            "License and terms: $($sdkPackageMetadata[0].LicenseUrl)"
        ) -join [Environment]::NewLine
    }

    $plannedDestinations = @($stagedAssets | ForEach-Object { $_.Destination }) + @(
        (Join-Path $OutputDirectory "MacKVM-LICENSE.txt"),
        (Join-Path $OutputDirectory "DOTNET-LIBRARY-LICENSE.txt")
    )
    if ($null -ne $sdkReferenceNotice) {
        $plannedDestinations += Join-Path $OutputDirectory "WINDOWS-SDK-REFERENCE.txt"
    }
    foreach ($destination in $plannedDestinations) {
        if (Test-Path -LiteralPath $destination) {
            throw "Refusing to overwrite an existing legal notice destination: $destination"
        }
    }

    foreach ($asset in $stagedAssets) {
        Copy-Item -LiteralPath $asset.Source -Destination $asset.Destination -Force
    }
    Copy-Item -LiteralPath $mackvmLicense -Destination (Join-Path $OutputDirectory "MacKVM-LICENSE.txt") -Force
    [System.IO.File]::WriteAllText(
        (Join-Path $OutputDirectory "DOTNET-LIBRARY-LICENSE.txt"),
        $dotnetLibraryLicenseNotice + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )
    if ($null -ne $sdkReferenceNotice) {
        [System.IO.File]::WriteAllText(
            (Join-Path $OutputDirectory "WINDOWS-SDK-REFERENCE.txt"),
            $sdkReferenceNotice + [Environment]::NewLine,
            [System.Text.UTF8Encoding]::new($false)
        )
    }
    Write-Host "Staged exact runtime notices from $runtimePackageId/$coreVersion beside the executable."
}

Write-Host "MacKVM Windows .NET publish plan"
Write-Host "  project:       $projectPath"
Write-Host "  configuration: $configurationName"
Write-Host "  output:        $OutputDirectory"
Write-Host "  notices:       resolve runtime packs from the publish .deps.json and .runtimeconfig.json"

foreach ($target in $buildTargets) {
    $architectureDirectory = Join-Path $OutputDirectory $target.Label
    Write-Host "  $($target.Label): dotnet publish `"$projectPath`" -c $configurationName -r $($target.Rid) --self-contained true -p:PublishSingleFile=true -p:PublishTrimmed=false -o `"$architectureDirectory`""
}

if ($Plan) {
    Write-Host "Plan only: no .NET toolchain was invoked and no executable was created."
    exit 0
}

if ($env:OS -ne "Windows_NT") {
    throw "scripts/build-windows.ps1 must run on Windows. On macOS use -Plan, GitHub Actions, or a Windows VM."
}

$dotnetCommands = @(Get-Command dotnet -CommandType Application -All -ErrorAction SilentlyContinue)
if ($dotnetCommands.Count -eq 0) {
    throw "dotnet was not found. Install the .NET 8 SDK on the Windows build host first."
}
if ($dotnetCommands.Count -gt 1) {
    $dotnetPaths = ($dotnetCommands | ForEach-Object { $_.Source }) -join [Environment]::NewLine
    throw "Multiple dotnet executables were found on PATH. Keep one .NET SDK on PATH before building:`n$dotnetPaths"
}
$dotnetExecutable = [string]$dotnetCommands[0].Source

$nugetLocalsOutput = @(& $dotnetExecutable nuget locals global-packages --list 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "Could not determine the NuGet global-packages directory: $($nugetLocalsOutput -join [Environment]::NewLine)"
}
$nugetLocalsText = $nugetLocalsOutput -join [Environment]::NewLine
$nugetRootMatch = [regex]::Match($nugetLocalsText, '(?im)^global-packages:\s*(?<path>.+?)\s*$')
if (-not $nugetRootMatch.Success) {
    throw "The NuGet global-packages path was not present in dotnet nuget locals output: $nugetLocalsText"
}
$nugetPackageRoot = [System.IO.Path]::GetFullPath($nugetRootMatch.Groups["path"].Value.Trim())

$projectText = Get-Content -LiteralPath $projectPath -Raw
if ($projectText -notmatch "net8\.0-windows") {
    throw "The Windows project must target net8.0-windows before it can be published."
}

# A direct build starts from a clean output and intermediate state. For an
# all-architecture invocation this runs once before the loop, preserving the
# x64 output while the arm64 publish is added. Custom output paths are cleaned
# independently; the repository's dist root is only cleared for the default
# output location.
if ($outputDirectoryWasDefault) {
    Clear-GeneratedDirectory -Path (Join-Path $projectRoot "dist")
} else {
    Clear-GeneratedDirectory -Path $OutputDirectory
}

$buildStateRoot = Join-Path ([System.IO.Path]::GetTempPath()) "MacKVM-WindowsKVM"
Clear-GeneratedDirectory -Path $buildStateRoot

foreach ($target in $buildTargets) {
    $architectureDirectory = Join-Path $OutputDirectory $target.Label
    New-Item -ItemType Directory -Force -Path $architectureDirectory | Out-Null

    # Keep generated bin/obj state outside the repository. `--artifacts-path`
    # gives every project in the reference graph its own subdirectory, so the
    # net8.0 protocol project cannot overwrite the net8.0-windows restore state
    # of this app. The publish output remains in the requested architecture
    # directory, while a Windows build cannot leave intermediate files that
    # are easy to commit accidentally.
    $buildStateDirectory = Join-Path $buildStateRoot $target.Rid
    Clear-GeneratedDirectory -Path $buildStateDirectory

    $arguments = @(
        "publish",
        $projectPath,
        "--configuration", $configurationName,
        "--runtime", $target.Rid,
        "--self-contained", "true",
        "-p:PublishSingleFile=true",
        "-p:PublishTrimmed=false",
        "--artifacts-path", $buildStateDirectory,
        "--output", $architectureDirectory
    )

    Write-Host "Publishing WindowsKVM for $($target.Label) ($($target.Rid))..."
    & $dotnetExecutable @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet publish failed for $($target.Rid) with exit code $LASTEXITCODE"
    }

    $publishedExecutables = @(Get-ChildItem -LiteralPath $architectureDirectory -Filter "*.exe" -File)
    if ($publishedExecutables.Count -ne 1) {
        throw "Expected exactly one published executable in $architectureDirectory, found $($publishedExecutables.Count)"
    }
    $builtExecutable = $publishedExecutables[0].FullName

    $actualMachine = Get-PeMachine -Path $builtExecutable
    if ($actualMachine -ne $target.Machine) {
        throw "Expected a $($target.Machine) PE binary, but $builtExecutable is $actualMachine"
    }

    Copy-ResolvedWindowsRuntimeNotices `
        -StateDirectory $buildStateDirectory `
        -RuntimeIdentifier $target.Rid `
        -OutputDirectory $architectureDirectory `
        -ProjectPath $projectPath `
        -NuGetPackageRoot $nugetPackageRoot

    Write-Host "Published $builtExecutable ($actualMachine)"
}
