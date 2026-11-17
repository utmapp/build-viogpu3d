# Helpers shared by build.ps1 and submit.ps1: console output, child processes,
# local configuration, git revisions and toolchain discovery.
#
# Windows PowerShell 5.1 is the baseline, so this file and its siblings stay
# ASCII-only (5.1 reads a BOM-less script as ANSI) and avoid newer syntax.

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$script:RepoRoot = Split-Path -Parent $PSScriptRoot

# ---------------------------------------------------------------------------
#  Console output
# ---------------------------------------------------------------------------
function Write-Step { param([string]$Message) Write-Host ''; Write-Host "=== $Message" -ForegroundColor Cyan }
function Write-Info { param([string]$Message) Write-Host "    $Message" }
function Write-Ok   { param([string]$Message) Write-Host "    $Message" -ForegroundColor Green }
function Write-Note { param([string]$Message) Write-Host "    $Message" -ForegroundColor Yellow }

# Runs the body of an entry script and turns a thrown error into one line and
# a non-zero exit code instead of a PowerShell stack dump.
function Invoke-Main {
    param([scriptblock]$Body)
    try {
        & $Body
    } catch {
        Write-Host ''
        Write-Host "error: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

# ---------------------------------------------------------------------------
#  Child processes
#
#  Every tool is started through System.Diagnostics.Process rather than the
#  call operator: it takes an explicit environment block, so a Visual Studio
#  environment for one architecture never leaks into the next step, and it
#  avoids the argument mangling 5.1 applies to empty strings and quotes.
# ---------------------------------------------------------------------------

# Quotes one argument the way CommandLineToArgvW (and the MSVC runtime) reads
# it back.
function ConvertTo-NativeArgument {
    param([string]$Argument)
    if ($Argument -eq '') { return '""' }
    if ($Argument -notmatch '[\s"]') { return $Argument }
    $escaped = $Argument -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Invoke-Tool {
    param(
        [Parameter(Mandatory)] [string]$FilePath,
        [string[]]$Arguments = @(),
        # The complete argument string, for cmd.exe, which has its own quoting.
        [string]$RawArguments,
        [hashtable]$Environment,
        [string]$WorkingDirectory,
        # Return standard output as a string instead of letting it reach the
        # console. Standard error is kept in $script:LastToolErrors.
        [switch]$Capture,
        # Do not throw on a non-zero exit code; the caller reads $script:LastToolExitCode.
        [switch]$AllowFailure
    )

    # A bare name is looked up on the PATH of the environment the tool will run
    # in. CreateProcess would search the PATH of this process, which is not
    # where a Visual Studio environment's compiler lives.
    if ($FilePath -notmatch '[\\/]') {
        $searchPath = $env:PATH
        if ($Environment) { $searchPath = $Environment[@($Environment.Keys | Where-Object { $_ -ieq 'PATH' })[0]] }
        $resolved = $null
        foreach ($dir in ($searchPath -split ';')) {
            if (-not $dir) { continue }
            $candidate = Join-Path $dir.Trim('"') $FilePath
            if (-not $resolved -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { $resolved = $candidate }
        }
        if (-not $resolved) { throw "$FilePath not found on PATH." }
        $FilePath = $resolved
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    if ($RawArguments) {
        $psi.Arguments = $RawArguments
    } else {
        $psi.Arguments = (@($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    }
    $psi.UseShellExecute = $false
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    if ($Environment) {
        $psi.EnvironmentVariables.Clear()
        foreach ($key in $Environment.Keys) { $psi.EnvironmentVariables[$key] = [string]$Environment[$key] }
    }
    if ($Capture) {
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
    }

    $process = [System.Diagnostics.Process]::Start($psi)
    $output = ''
    $errors = ''
    if ($Capture) {
        # Read both pipes concurrently; reading one to the end first deadlocks
        # as soon as the tool fills the other.
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $output = $outTask.Result
        $errors = $errTask.Result
    } else {
        $process.WaitForExit()
    }
    $script:LastToolExitCode = $process.ExitCode
    $script:LastToolErrors = $errors
    $process.Dispose()

    if ($script:LastToolExitCode -ne 0 -and -not $AllowFailure) {
        $name = Split-Path -Leaf $FilePath
        $detail = ''
        if ($Capture) { $detail = ("`n" + ($output + $errors).Trim()) }
        throw "$name failed with exit code $($script:LastToolExitCode).$detail"
    }
    if ($Capture) { return $output }
}

# Runs a batch file. "cmd /s /c" strips exactly the outer pair of quotes, which
# is the only form that survives a script path and arguments that both need
# quoting.
function Invoke-Batch {
    param(
        [Parameter(Mandatory)] [string]$Script,
        [string[]]$Arguments = @(),
        [string]$Trailer,
        [hashtable]$Environment,
        [string]$WorkingDirectory,
        [switch]$Capture,
        [switch]$AllowFailure
    )
    $line = '"' + $Script + '"'
    foreach ($argument in $Arguments) {
        # Only what needs it: a quoted "-arch=arm64" reaches a batch file with
        # its quotes on, and VsDevCmd.bat does not recognise it.
        if ($argument -match '[\s&()^]') { $line += ' "' + $argument + '"' } else { $line += ' ' + $argument }
    }
    if ($Trailer) { $line += ' ' + $Trailer }
    $forward = @{ FilePath = $env:ComSpec; RawArguments = ('/d /s /c "' + $line + '"') }
    if ($Environment)      { $forward.Environment = $Environment }
    if ($WorkingDirectory) { $forward.WorkingDirectory = $WorkingDirectory }
    if ($Capture)          { $forward.Capture = $true }
    if ($AllowFailure)     { $forward.AllowFailure = $true }
    Invoke-Tool @forward
}

function Get-ProcessEnvironment {
    $table = @{}
    foreach ($entry in [System.Environment]::GetEnvironmentVariables().GetEnumerator()) {
        $table[[string]$entry.Key] = [string]$entry.Value
    }
    return $table
}

# ---------------------------------------------------------------------------
#  Files
# ---------------------------------------------------------------------------
function Reset-Directory {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Confirm-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

function Write-TextFile {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return ([System.IO.File]::ReadAllText($Path) | ConvertFrom-Json)
}

function Write-JsonFile {
    param([string]$Path, $Value)
    Write-TextFile $Path (($Value | ConvertTo-Json -Depth 10) + "`r`n")
}

# The value of a property that may be absent, for objects read back from JSON.
function Get-JsonValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

# ---------------------------------------------------------------------------
#  Local configuration
#
#  config.psd1 in the repository root (never committed) supplies defaults for
#  parameters that describe this machine: where the sources are, which
#  certificate signs. See config.example.psd1.
# ---------------------------------------------------------------------------
$script:ConfigKeys = @(
    'KmdSource', 'UmdSource', 'CertFile', 'CertThumbprint', 'CertSubject',
    'TimestampUrl', 'CredentialFile', 'ProductName', 'Provider'
)
$script:ConfigPathKeys = @('KmdSource', 'UmdSource', 'CertFile', 'CredentialFile')

function Read-LocalConfig {
    $path = Join-Path $script:RepoRoot 'config.psd1'
    if (-not (Test-Path -LiteralPath $path)) { return @{} }
    $config = Import-PowerShellDataFile -LiteralPath $path
    foreach ($key in @($config.Keys)) {
        if ($script:ConfigKeys -notcontains $key) {
            throw "config.psd1: unknown setting `"$key`". Known settings: $($script:ConfigKeys -join ', ')."
        }
        # A relative path in the file is relative to the file.
        if ($script:ConfigPathKeys -contains $key -and $config[$key] -and
            -not [System.IO.Path]::IsPathRooted($config[$key])) {
            $config[$key] = Join-Path $script:RepoRoot $config[$key]
        }
    }
    return $config
}

# A path from the command line, relative to the current directory.
function Resolve-FullPath {
    param([string]$Path)
    if (-not [System.IO.Path]::IsPathRooted($Path)) { $Path = Join-Path (Get-Location).ProviderPath $Path }
    return [System.IO.Path]::GetFullPath($Path)
}

# ---------------------------------------------------------------------------
#  Git revisions
#
#  A revision token is ten characters: the first ten hex digits of the commit,
#  or the first nine and a "+" when tracked files had uncommitted changes. The
#  same token goes into the INF, into viogpu3d.sys and into the Mesa binaries
#  (whose own generator keeps ten characters).
# ---------------------------------------------------------------------------
function Get-GitRevision {
    param([string]$Directory)

    $unknown = [pscustomobject]@{ Token = 'unknown'; Commit = ''; Dirty = $false }
    if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) { return $unknown }

    $commit = (Invoke-Tool -FilePath git.exe -Arguments @('-C', $Directory, 'rev-parse', 'HEAD') -Capture -AllowFailure)
    if ($script:LastToolExitCode -ne 0 -or -not $commit) { return $unknown }
    $commit = $commit.Trim()

    $status = Invoke-Tool -FilePath git.exe -Capture -AllowFailure `
        -Arguments @('-C', $Directory, 'status', '--porcelain', '--untracked-files=no')
    $dirty = [bool]($status -and $status.Trim())

    $token = $commit.Substring(0, 10)
    if ($dirty) { $token = $commit.Substring(0, 9) + '+' }
    return [pscustomobject]@{ Token = $token; Commit = $commit; Dirty = $dirty }
}

# ---------------------------------------------------------------------------
#  Host and Visual Studio
# ---------------------------------------------------------------------------

# The machine architecture (x86, x64 or arm64). PROCESSOR_ARCHITECTURE describes
# the calling process instead: an x64 shell on an ARM64 machine reports AMD64.
function Get-HostArch {
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
    $value = (Get-ItemProperty -LiteralPath $key -Name PROCESSOR_ARCHITECTURE).PROCESSOR_ARCHITECTURE
    switch ($value) {
        'AMD64' { return 'x64' }
        'ARM64' { return 'arm64' }
        'x86'   { return 'x86' }
    }
    throw "Unsupported host architecture `"$value`"."
}

function Find-VsWhere {
    foreach ($root in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
        if (-not $root) { continue }
        $candidate = Join-Path $root 'Microsoft Visual Studio\Installer\vswhere.exe'
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    throw 'vswhere.exe not found. Install Visual Studio 2022 with the "Desktop development with C++" workload.'
}

$script:VsInstallPath = $null
function Get-VsInstallPath {
    if ($script:VsInstallPath) { return $script:VsInstallPath }
    $found = Invoke-Tool -FilePath (Find-VsWhere) -Capture -Arguments @(
        '-latest', '-products', '*', '-requires', 'Microsoft.Component.MSBuild', '-property', 'installationPath')
    $path = @($found -split "`r?`n" | Where-Object { $_ })
    if (-not $path) { throw 'No Visual Studio installation with MSBuild was found.' }
    $script:VsInstallPath = $path[0].Trim()
    return $script:VsInstallPath
}

function Find-MSBuild {
    $found = Invoke-Tool -FilePath (Find-VsWhere) -Capture -Arguments @(
        '-latest', '-products', '*', '-requires', 'Microsoft.Component.MSBuild', '-find', 'MSBuild\**\Bin\MSBuild.exe')
    $path = @($found -split "`r?`n" | Where-Object { $_ })
    if (-not $path) { throw 'No Visual Studio installation with MSBuild was found.' }
    return $path[0].Trim()
}

# The environment of a Visual Studio developer prompt that targets $Arch
# (x86, x64, arm64 or arm64ec), as a table to hand to Invoke-Tool.
$script:VsEnvironments = @{}
function Get-VsEnvironment {
    param([Parameter(Mandatory)] [string]$Arch)

    if ($script:VsEnvironments.ContainsKey($Arch)) { return $script:VsEnvironments[$Arch].Clone() }

    $names = @{ x86 = 'x86'; x64 = 'amd64'; arm64 = 'arm64'; arm64ec = 'arm64' }
    $devCmd = Join-Path (Get-VsInstallPath) 'Common7\Tools\VsDevCmd.bat'
    if (-not (Test-Path -LiteralPath $devCmd)) { throw "`"$devCmd`" not found." }

    $base = Get-ProcessEnvironment
    $base['VSCMD_SKIP_SENDTELEMETRY'] = '1'
    $dump = Invoke-Batch -Script $devCmd -Capture -Environment $base -Trailer '>nul && set' -Arguments @(
        "-arch=$($names[$Arch])", "-host_arch=$($names[(Get-HostArch)])", '-startdir=none', '-no_logo')

    $table = @{}
    foreach ($line in ($dump -split "`r?`n")) {
        $split = $line.IndexOf('=')
        if ($split -gt 0) { $table[$line.Substring(0, $split)] = $line.Substring($split + 1) }
    }
    if (-not $table.ContainsKey('VCToolsInstallDir')) {
        throw "The Visual Studio environment for $Arch has no C++ toolset. Install the MSVC build tools for that architecture."
    }

    if ($Arch -eq 'arm64ec') {
        # ARM64EC is the arm64 toolchain plus the /arm64EC switch (which the
        # Meson cross file supplies) and its own C runtime libraries. The
        # Windows SDK's arm64 import libraries serve both ABIs; an SDK that
        # does ship separate arm64ec directories gets them added too.
        $ecLibs = @(Join-Path $table['VCToolsInstallDir'] 'lib\arm64ec')
        if (-not (Test-Path -LiteralPath $ecLibs[0])) {
            throw "`"$($ecLibs[0])`" not found. Install the MSVC ARM64EC build tools."
        }
        $sdkLib = Join-Path $table['WindowsSdkDir'] ('Lib\' + $table['WindowsSDKVersion'].TrimEnd('\'))
        foreach ($dir in @((Join-Path $sdkLib 'um\arm64ec'), (Join-Path $sdkLib 'ucrt\arm64ec'))) {
            if (Test-Path -LiteralPath $dir) { $ecLibs += $dir }
        }
        $table['LIB'] = (($ecLibs -join ';') + ';' + $table['LIB'])
    }

    $script:VsEnvironments[$Arch] = $table
    return $table.Clone()
}

# Prepends directories to PATH in an environment table, whatever the case of
# its key.
function Add-EnvironmentPath {
    param([hashtable]$Environment, [string[]]$Directories)
    $key = @($Environment.Keys | Where-Object { $_ -ieq 'PATH' })[0]
    if (-not $key) { $key = 'Path'; $Environment[$key] = '' }
    $Environment[$key] = (($Directories -join ';') + ';' + $Environment[$key])
}

# ---------------------------------------------------------------------------
#  Windows kit tools (signtool, inf2cat)
# ---------------------------------------------------------------------------
$script:KitTools = @{}
function Find-KitTool {
    param([Parameter(Mandatory)] [string]$Name)

    if ($script:KitTools.ContainsKey($Name)) { return $script:KitTools[$Name] }

    $found = $null
    $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { $found = $command.Source }

    if (-not $found) {
        $roots = @()
        foreach ($key in @('HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots',
                           'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots')) {
            $entry = Get-ItemProperty -LiteralPath $key -Name KitsRoot10 -ErrorAction SilentlyContinue
            if ($entry) { $roots += $entry.KitsRoot10 }
        }
        if (${env:ProgramFiles(x86)}) { $roots += (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10') }

        # Newest kit first; within a kit prefer a native build of the tool.
        $arches = @((Get-HostArch), 'x64', 'x86') | Select-Object -Unique
        foreach ($root in ($roots | Select-Object -Unique)) {
            $bin = Join-Path $root 'bin'
            if ($found -or -not (Test-Path -LiteralPath $bin)) { continue }
            $kits = Get-ChildItem -LiteralPath $bin -Directory | Where-Object { $_.Name -match '^\d+(\.\d+)+$' } |
                    Sort-Object { [version]$_.Name } -Descending
            foreach ($kit in $kits) {
                foreach ($arch in $arches) {
                    $candidate = Join-Path $kit.FullName (Join-Path $arch $Name)
                    if (-not $found -and (Test-Path -LiteralPath $candidate)) { $found = $candidate }
                }
            }
        }
    }

    if (-not $found) { throw "$Name not found on PATH or in an installed Windows SDK / WDK." }
    $script:KitTools[$Name] = $found
    return $found
}
