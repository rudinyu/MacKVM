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

Write-Host "MacKVM Windows .NET publish plan"
Write-Host "  project:       $projectPath"
Write-Host "  configuration: $configurationName"
Write-Host "  output:        $OutputDirectory"

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

    Write-Host "Published $builtExecutable ($actualMachine)"
}
