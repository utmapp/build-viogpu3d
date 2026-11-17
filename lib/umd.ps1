# The user-mode half: the Neptune Direct3D driver (neptune_umd.dll) and the
# Venus Vulkan ICD (vulkan_virtio.dll), both built from the Mesa fork.
#
# Mesa is configured once per architecture, always the same way, into
# build\umd\<arch>. "Just Neptune" and "just Venus" are a choice of ninja
# targets inside that one configuration, so every kind of build shares objects.
#
# Nothing but the two drivers is enabled. Neither needs LLVM, a GLSL compiler
# or flex/bison, which is why this repository carries none of them.

# Meson target names, as "meson introspect --targets" reports them.
$script:UmdTargets = @{
    neptune = @{ Library = 'neptune_umd' }
    venus   = @{ Library = 'vulkan_virtio'; Manifest = 'virtio_icd' }
}

function Get-UmdBuildDir { param([string]$Arch) return (Join-Path $script:BuildRoot "umd\$Arch") }

# What a build left behind, per component: file paths and the Mesa revision
# they were built from. Packaging reads this instead of guessing paths, and it
# is what keeps a stale build from being stamped with today's commit.
function Get-UmdRecordPath { param([string]$Arch) return (Join-Path (Get-UmdBuildDir $Arch) 'viogpu3d-outputs.json') }

function Read-UmdRecord {
    param([string]$Arch)
    $record = Read-JsonFile (Get-UmdRecordPath $Arch)
    if ($null -eq $record) { return [pscustomobject]@{} }
    return $record
}

function Save-UmdRecord {
    param([string]$Arch, [string]$Component, $Value)
    $record = Read-UmdRecord $Arch
    if ($record.PSObject.Properties[$Component]) {
        $record.$Component = $Value
    } else {
        $record | Add-Member -NotePropertyName $Component -NotePropertyValue $Value
    }
    Write-JsonFile (Get-UmdRecordPath $Arch) $record
}

# ---------------------------------------------------------------------------
#  Tools: Meson and Ninja in a private virtual environment, so the build does
#  not depend on (or change) whatever Python packages the machine has.
# ---------------------------------------------------------------------------
function Find-Python {
    foreach ($candidate in @(@('python.exe'), @('py.exe', '-3'))) {
        $command = Get-Command $candidate[0] -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $command) { continue }
        $prefix = @($candidate | Select-Object -Skip 1)
        # The Microsoft Store placeholder is also called python.exe; make sure
        # this one runs.
        $probe = Invoke-Tool -FilePath $command.Source -Capture -AllowFailure `
            -Arguments ($prefix + @('-c', 'import sys; print(sys.version_info >= (3, 9))'))
        if ($script:LastToolExitCode -eq 0 -and $probe -match 'True') {
            return [pscustomobject]@{ FilePath = $command.Source; Prefix = $prefix }
        }
    }
    throw 'Python 3.9 or newer not found on PATH.'
}

$script:UmdTools = $null
function Initialize-UmdTools {
    if ($script:UmdTools) { return }

    $venv = Join-Path $script:BuildRoot 'tools\venv'
    $python = Join-Path $venv 'Scripts\python.exe'
    $requirements = Join-Path $script:RepoRoot 'meson\requirements.txt'
    $installed = Join-Path $venv 'requirements.txt'

    $current = (Test-Path -LiteralPath $python) -and (Test-Path -LiteralPath $installed) -and
               ([System.IO.File]::ReadAllText($installed) -eq [System.IO.File]::ReadAllText($requirements))
    if (-not $current) {
        Write-Step 'Preparing Meson and Ninja'
        $system = Find-Python
        Reset-Directory $venv
        Invoke-Tool -FilePath $system.FilePath -Arguments ($system.Prefix + @('-m', 'venv', $venv))
        Invoke-Tool -FilePath $python -Arguments @(
            '-m', 'pip', 'install', '--disable-pip-version-check', '--quiet', '-r', $requirements)
        Copy-Item -LiteralPath $requirements -Destination $installed
        Write-Ok "Installed into $venv"
    }

    $scripts = Join-Path $venv 'Scripts'

    # Mesa looks for "python3", and a Windows venv has only python.exe, so
    # Meson would find whatever python3.exe is on PATH (another install, or the
    # Microsoft Store placeholder), without mako. A copy of the venv launcher
    # under that name runs the venv's interpreter.
    $python3 = Join-Path $scripts 'python3.exe'
    if (-not (Test-Path -LiteralPath $python3) -or
        (Get-Item -LiteralPath $python3).Length -ne (Get-Item -LiteralPath $python).Length) {
        Copy-Item -LiteralPath $python -Destination $python3 -Force
    }

    $script:UmdTools = [pscustomobject]@{
        Scripts = $scripts
        Meson   = Join-Path $scripts 'meson.exe'
        Ninja   = Join-Path $scripts 'ninja.exe'
    }
    foreach ($tool in @($script:UmdTools.Meson, $script:UmdTools.Ninja)) {
        if (-not (Test-Path -LiteralPath $tool)) { throw "`"$tool`" is missing; delete `"$venv`" and run again." }
    }
}

# Meson has no ARM64EC machine: for an aarch64 cross build it passes
# /MACHINE:ARM64 to lib and link, which reject /arm64EC objects. The ARM64EC
# cross file points ar/c_ld/cpp_ld at two small wrappers that rewrite the
# switch; they are built here, once, with the host compiler.
function Initialize-Arm64EcShim {
    $dir = Join-Path $script:BuildRoot 'tools\arm64ec'
    $source = Join-Path $script:RepoRoot 'meson\arm64ec-shim.c'
    $outputs = @((Join-Path $dir 'arm64ec-lib.exe'), (Join-Path $dir 'arm64ec-link.exe'))

    $stale = $false
    foreach ($output in $outputs) {
        if (-not (Test-Path -LiteralPath $output) -or
            (Get-Item -LiteralPath $output).LastWriteTimeUtc -lt (Get-Item -LiteralPath $source).LastWriteTimeUtc) {
            $stale = $true
        }
    }
    if ($stale) {
        Write-Info 'Building the ARM64EC linker wrappers'
        Confirm-Directory $dir
        $environment = Get-VsEnvironment (Get-HostArch)
        foreach ($variant in @(@('SHIM_LIB', 'arm64ec-lib'), @('SHIM_LINK', 'arm64ec-link'))) {
            Invoke-Tool -FilePath cl.exe -Environment $environment -WorkingDirectory $dir -Capture -Arguments @(
                '/nologo', '/O2', "/D$($variant[0])", "/Fe:$($variant[1]).exe", "/Fo:$($variant[1]).obj", $source) | Out-Null
        }
    }
    return $dir
}

function Get-UmdEnvironment {
    param([string]$Arch, $Revision)

    $environment = Get-VsEnvironment $Arch
    $paths = @($script:UmdTools.Scripts)
    if ($Arch -eq 'arm64ec') { $paths += (Initialize-Arm64EcShim) }
    Add-EnvironmentPath $environment $paths

    # A developer prompt puts Visual Studio's own, older ninja on PATH. Meson
    # regenerates with whichever it finds first, and that one cannot read the
    # build log ours wrote, which forces a full rebuild. Pin it.
    $environment['NINJA'] = $script:UmdTools.Ninja

    # Mesa stamps the first ten characters of this (or of HEAD) into its
    # binaries; the override is how an uncommitted tree gets its "+" marker.
    $environment.Remove('MESA_GIT_SHA1_OVERRIDE')
    if ($Revision.Dirty) { $environment['MESA_GIT_SHA1_OVERRIDE'] = $Revision.Token }
    return $environment
}

function Get-MesonOptions {
    param([string]$Arch, [string]$Version)
    return @(
        '--cross-file', (Join-Path $script:RepoRoot "meson\cross-$Arch.txt"),
        # Statically linked, with the static CRT: the drivers ship without any
        # runtime DLL next to them.
        '--default-library=static',
        '-Db_vscrt=mt',
        # An optimised build that still writes PDBs. Development builds and
        # signed releases are the same binaries.
        '-Dbuildtype=release',
        '-Ddebug=true',
        '-Db_ndebug=true',
        # Only Neptune and Venus.
        '-Dplatforms=windows',
        '-Dllvm=disabled',
        '-Dgallium-drivers=',
        '-Dvulkan-drivers=virtio',
        '-Dvideo-codecs=',
        '-Dopengl=false',
        '-Degl=disabled',
        '-Dgles1=disabled',
        '-Dgles2=disabled',
        '-Dglx=disabled',
        '-Dneptune=true',
        '-Dnpt_wine=false',
        '-Dnpt_umd=ddi',
        # Windows requires the UMD file version to equal the INF DriverVer.
        "-Dnpt_umd_version=$Version"
    )
}

# ---------------------------------------------------------------------------
#  Build one architecture (x86, x64, arm64 or arm64ec)
# ---------------------------------------------------------------------------
function Build-UmdArch {
    param(
        [string]$Arch,
        [string[]]$Components,
        [string]$Version,
        $Revision,
        [switch]$Clean
    )

    Write-Step "Mesa $Arch`: $($Components -join ' + ')"
    Initialize-UmdTools

    $dir = Get-UmdBuildDir $Arch
    $environment = Get-UmdEnvironment $Arch $Revision
    $options = Get-MesonOptions $Arch $Version

    # Reconfigure only when the configuration changed. The first line is the
    # source directory: Meson cannot repoint a build directory, so a different
    # checkout starts over.
    $stampPath = Join-Path $dir 'viogpu3d-configuration.txt'
    $stamp = (@($script:UmdSource) + $options) -join "`n"
    $previous = $null
    if (Test-Path -LiteralPath $stampPath) { $previous = [System.IO.File]::ReadAllText($stampPath) }

    $sameSource = ($null -ne $previous) -and (($previous -split "`n")[0] -eq $script:UmdSource)
    if ((Test-Path -LiteralPath $dir) -and ($Clean -or -not $sameSource)) {
        Write-Info "Removing $dir"
        Remove-Item -LiteralPath $dir -Recurse -Force
        $previous = $null
    }

    if ($previous -ne $stamp -or -not (Test-Path -LiteralPath (Join-Path $dir 'build.ninja'))) {
        $arguments = @('setup')
        if (Test-Path -LiteralPath (Join-Path $dir 'meson-private\coredata.dat')) { $arguments += '--reconfigure' }
        $arguments += @($dir, $script:UmdSource) + $options
        Invoke-Tool -FilePath $script:UmdTools.Meson -Arguments $arguments -Environment $environment
        Write-TextFile $stampPath $stamp
    }

    # Map each component to its ninja targets and output files.
    $targets = Read-JsonFile (Join-Path $dir 'meson-info\intro-targets.json')
    $outputs = @{}
    $ninjaTargets = @()
    foreach ($component in $Components) {
        $entry = @{ revision = $Revision.Token }
        foreach ($kind in $script:UmdTargets[$component].Keys) {
            $name = $script:UmdTargets[$component][$kind]
            $target = @($targets | Where-Object { $_.name -eq $name })
            if ($target.Count -ne 1) { throw "The Mesa source has no single `"$name`" build target; is this the fork with Neptune?" }
            $file = [System.IO.Path]::GetFullPath($target[0].filename[0])
            $entry[$kind.ToLowerInvariant()] = $file
            $ninjaTargets += $file.Substring($dir.Length + 1).Replace('\', '/')
        }
        $outputs[$component] = $entry
    }

    Invoke-Tool -FilePath $script:UmdTools.Ninja -Arguments (@('-C', $dir) + $ninjaTargets) -Environment $environment

    $symbols = Join-Path $script:OutRoot "symbols\$Arch"
    Confirm-Directory $symbols
    foreach ($component in $Components) {
        $library = $outputs[$component]['library']
        if (-not (Test-Path -LiteralPath $library)) { throw "`"$library`" was not built." }
        $pdb = [System.IO.Path]::ChangeExtension($library, '.pdb')
        if (Test-Path -LiteralPath $pdb) { Copy-Item -LiteralPath $pdb -Destination $symbols -Force }
        Save-UmdRecord $Arch $component ([pscustomobject]$outputs[$component])
        Write-Ok $library
    }
}

# ---------------------------------------------------------------------------
#  ARM64X
#
#  Windows on ARM runs native ARM64 processes and, under emulation, x64 ones
#  (ARM64EC is the ABI those use). No single DLL serves both, so each driver is
#  built twice, for arm64 and for arm64ec, and the two builds ship behind one
#  ARM64X front DLL that the loader resolves per process:
#
#    neptune_umd.dll     code-less forwarder to neptune_umd_arm64 / _ec
#    vulkan_virtio.dll   loader stub for vulkan_virtio_arm64 / _ec (the Vulkan
#                        loader uses GetProcAddress, which does not follow a
#                        forwarder into the DriverStore)
#
#  The tools that build the front DLLs live in the Mesa fork next to the
#  sources they are generated from.
# ---------------------------------------------------------------------------
$script:Arm64xTools = @{
    neptune = @{ Tool = 'src\virtio\neptune\triton\tools\make-arm64x.bat'; Name = 'neptune_umd' }
    venus   = @{ Tool = 'src\virtio\vulkan\tools\make-arm64x-vk.bat';      Name = 'vulkan_virtio' }
}

function Join-UmdArm64x {
    param([string[]]$Components)

    Write-Step "Mesa arm64x: $($Components -join ' + ')"
    $dir = Get-UmdBuildDir 'arm64x'
    Confirm-Directory $dir
    $native = Read-UmdRecord 'arm64'
    $ec = Read-UmdRecord 'arm64ec'

    foreach ($component in $Components) {
        $tool = Join-Path $script:UmdSource $script:Arm64xTools[$component].Tool
        if (-not (Test-Path -LiteralPath $tool)) { throw "`"$tool`" not found; the Mesa source cannot build the ARM64X $component." }

        $name = $script:Arm64xTools[$component].Name
        $files = @("$name.dll", "${name}_arm64.dll", "${name}_ec.dll")
        foreach ($file in $files) { Remove-Item -LiteralPath (Join-Path $dir $file) -Force -ErrorAction SilentlyContinue }

        $nativeLibrary = Get-JsonValue (Get-JsonValue $native $component) 'library'
        $ecLibrary = Get-JsonValue (Get-JsonValue $ec $component) 'library'
        if (-not $nativeLibrary -or -not $ecLibrary) { throw "ARM64X $component needs both the arm64 and the arm64ec build." }

        # Each tool enters its own arm64 developer environment.
        Invoke-Batch -Script $tool -Arguments @($nativeLibrary, $ecLibrary, $dir)
        foreach ($file in $files) {
            if (-not (Test-Path -LiteralPath (Join-Path $dir $file))) { throw "`"$file`" was not produced in `"$dir`"." }
        }

        $revisions = @($native.$component.revision, $ec.$component.revision) | Select-Object -Unique
        Save-UmdRecord 'arm64x' $component ([pscustomobject]@{
            revision = ($revisions -join ',')
            library  = (Join-Path $dir "$name.dll")
            manifest = (Get-JsonValue $native.$component 'manifest')
        })
        Write-Ok (Join-Path $dir "$name.dll")
    }
}

# ---------------------------------------------------------------------------
#  Staging
#
#  The kernel driver project packages whatever it finds, under fixed names, in
#  the one flat directory VIOGPU_UMD_DIR names. This assembles that directory
#  for a package and returns what went in.
# ---------------------------------------------------------------------------

# Returns the planned contents of the staged directory for $Package (x64,
# arm64 or arm64x): a list of Name/Source pairs, the Vulkan manifest to derive
# virtio_icd.json from, and the revisions involved. Missing is non-empty when
# something has not been built yet.
function Get-UmdStagePlan {
    param([string]$Package, [bool]$IncludeWow)

    $files = @()
    $missing = @()
    $revisions = @()
    $manifest = $null
    $record = Read-UmdRecord $Package

    foreach ($component in @('neptune', 'venus')) {
        $entry = Get-JsonValue $record $component
        $library = Get-JsonValue $entry 'library'
        if (-not $library -or -not (Test-Path -LiteralPath $library)) { $missing += "$component ($Package)"; continue }
        $revisions += $entry.revision
        $name = [System.IO.Path]::GetFileNameWithoutExtension($library)
        $files += [pscustomobject]@{ Name = "$name.dll"; Source = $library }
        if ($Package -eq 'arm64x') {
            foreach ($view in @('arm64', 'ec')) {
                $files += [pscustomobject]@{ Name = "${name}_$view.dll"; Source = (Join-Path (Split-Path -Parent $library) "${name}_$view.dll") }
            }
        }
        if ($component -eq 'venus') { $manifest = Get-JsonValue $entry 'manifest' }
    }

    # 32-bit applications run as WOW64 processes on both x64 and ARM64 Windows
    # and need a 32-bit driver; ARM64X has no 32-bit view. It gets its own file
    # name because it shares the DriverStore directory with the 64-bit one.
    if ($IncludeWow) {
        $entry = Get-JsonValue (Read-UmdRecord 'x86') 'neptune'
        $library = Get-JsonValue $entry 'library'
        if (-not $library -or -not (Test-Path -LiteralPath $library)) {
            $missing += 'neptune (x86)'
        } else {
            $revisions += $entry.revision
            $files += [pscustomobject]@{ Name = 'neptune_umd_x86.dll'; Source = $library }
        }
    }

    foreach ($file in $files) {
        if (-not (Test-Path -LiteralPath $file.Source)) { $missing += $file.Name }
    }
    if ($manifest -and -not (Test-Path -LiteralPath $manifest)) { $missing += 'virtio_icd.json' }

    $distinct = @(($revisions -join ',') -split ',' | Where-Object { $_ } | Select-Object -Unique)
    return [pscustomobject]@{
        Package   = $Package
        Files     = $files
        Manifest  = $manifest
        Missing   = $missing
        Revisions = $distinct
    }
}

function Publish-UmdStage {
    param($Plan)

    $dir = Join-Path $script:OutRoot "umd\$($Plan.Package)"
    # Start empty: the kernel driver decides what to package, and what its INF
    # says, from which files exist here.
    Reset-Directory $dir
    foreach ($file in $Plan.Files) {
        Copy-Item -LiteralPath $file.Source -Destination (Join-Path $dir $file.Name)
    }

    # Mesa writes the manifest for its own install layout. In the DriverStore
    # the DLL sits next to it, and the path has to be explicitly relative: the
    # Vulkan loader resolves a bare file name through the system search path,
    # which does not include the DriverStore.
    $icd = Read-JsonFile $Plan.Manifest
    if (-not (Get-JsonValue $icd 'ICD')) { throw "`"$($Plan.Manifest)`" is not a Vulkan ICD manifest." }
    $icd.ICD.library_path = '.\vulkan_virtio.dll'
    Write-JsonFile (Join-Path $dir 'virtio_icd.json') $icd

    return [pscustomobject]@{
        Directory = $dir
        Files     = @($Plan.Files | ForEach-Object { $_.Name }) + @('virtio_icd.json')
        Revisions = $Plan.Revisions
    }
}
