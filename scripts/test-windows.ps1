param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",
    [switch]$Plan
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$testSuites = @("Protocol", "Desktop")

$runningOnWindows = $env:OS -eq "Windows_NT"
$platform = if ($runningOnWindows) {
    "Windows"
} elseif (Get-Command uname -ErrorAction SilentlyContinue) {
    (& uname -s).Trim()
} else {
    "Unknown"
}

function Get-HostArchitecture {
    if ($runningOnWindows) {
        $architectureText = $env:PROCESSOR_ARCHITEW6432
        if ([string]::IsNullOrWhiteSpace($architectureText)) {
            $architectureText = $env:PROCESSOR_ARCHITECTURE
        }
        if ($architectureText -match "ARM64|AARCH64") {
            return "arm64"
        }
        if ($architectureText -match "AMD64|X86_64|X64") {
            return "x64"
        }
        throw "Unsupported Windows processor architecture: $architectureText"
    }

    $machine = if (Get-Command uname -ErrorAction SilentlyContinue) {
        (& uname -m).Trim().ToLowerInvariant()
    } else {
        ""
    }
    if ($machine -match "arm64|aarch64") {
        return "arm64"
    }
    if ($machine -match "x86_64|amd64") {
        return "x64"
    }
    throw "Unsupported host processor architecture: $machine"
}

$hostArchitecture = Get-HostArchitecture
$runtime = if ($platform -eq "Windows") {
    if ($hostArchitecture -eq "arm64") { "win-arm64" } else { "win-x64" }
} elseif ($platform -eq "Darwin") {
    if ($hostArchitecture -eq "arm64") { "osx-arm64" } else { "osx-x64" }
} elseif ($platform -eq "Linux") {
    if ($hostArchitecture -eq "arm64") { "linux-arm64" } else { "linux-x64" }
} else {
    throw "The current operating system is not supported by the Windows self-tests."
}

$publishDirectory = Join-Path ([System.IO.Path]::GetTempPath()) (
    "MacKVM-WindowsKVM-SelfTest-" + [Guid]::NewGuid().ToString("N")
)
if ($Plan) {
    foreach ($testSuite in $testSuites) {
        $testName = "WindowsKVM.$testSuite.SelfTest"
        $project = Join-Path $repoRoot "WindowsKVM/tests/$testName/$testName.csproj"
        $testOutput = Join-Path $publishDirectory $testSuite
        $binaryName = if ($runningOnWindows) { "$testName.exe" } else { $testName }
        $executable = Join-Path $testOutput $binaryName
        Write-Output "dotnet publish `"$project`" --configuration $Configuration --runtime $runtime --self-contained true --output `"$testOutput`""
        Write-Output "Run `"$executable`""
    }
    exit 0
}

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw "dotnet was not found. Install the .NET 8 SDK first."
}

New-Item -ItemType Directory -Force -Path $publishDirectory | Out-Null
try {
    foreach ($testSuite in $testSuites) {
        $testName = "WindowsKVM.$testSuite.SelfTest"
        $project = Join-Path $repoRoot "WindowsKVM/tests/$testName/$testName.csproj"
        $testOutput = Join-Path $publishDirectory $testSuite
        $binaryName = if ($runningOnWindows) { "$testName.exe" } else { $testName }
        & dotnet publish $project `
            --configuration $Configuration `
            --runtime $runtime `
            --self-contained true `
            --output $testOutput
        if ($LASTEXITCODE -ne 0) {
            throw "$testName publish failed with exit code $LASTEXITCODE."
        }

        $executable = Join-Path $testOutput $binaryName
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
            throw "The self-contained $testName was not published at $executable."
        }

        & $executable
        if ($LASTEXITCODE -ne 0) {
            throw "$testName failed with exit code $LASTEXITCODE."
        }
    }
} finally {
    if (Test-Path -LiteralPath $publishDirectory) {
        Remove-Item -LiteralPath $publishDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}
