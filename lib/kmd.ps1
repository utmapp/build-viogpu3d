# The kernel-mode half, built by the driver repository's own build.bat:
# viogpu3d.sys or the display-only viogpudo.sys, and the two user-mode helpers
# both of them install.

# A package's kernel driver. The WDK ships kernel libraries for x64 and ARM64
# only, so there is no 32-bit kernel driver and no x86 package; the arm64 and
# arm64x packages differ in their user-mode files, not in the driver.
$script:KmdTargets = @{
    x64    = @{ Platform = 'x64';   InstallArch = 'amd64' }
    arm64  = @{ Platform = 'ARM64'; InstallArch = 'ARM64' }
    arm64x = @{ Platform = 'ARM64'; InstallArch = 'ARM64' }
}

# The version the driver stamps into the INF as DriverVer. It is defined in the
# driver repository (build\Driver.RHEL.props), so ask MSBuild rather than keep
# a copy here; the Mesa build stamps the same number into the UMD.
function Get-KmdDriverVersion {
    param([string]$Os)
    $project = Join-Path $script:KmdSource 'viogpu3d\viogpu3d.vcxproj'
    $version = Invoke-Tool -FilePath (Find-MSBuild) -Capture -Arguments @(
        $project, '-nologo', '-getProperty:STAMPINF_VERSION', "-p:Configuration=$Os Release", '-p:Platform=x64')
    $version = $version.Trim()
    if ($version -notmatch '^\d+\.\d+\.\d+\.\d+$') {
        throw "Could not read the driver version from `"$project`" (got `"$version`")."
    }
    return $version
}

# Builds one driver for one package and returns the directory the driver
# repository assembled it in.
function Build-Kmd {
    param(
        [string]$Driver,
        [string]$Package,
        [string]$Os,
        [string]$Configuration,
        # The staged user-mode files of a viogpu3d package.
        [string]$UmdDirectory,
        $Revisions,
        [switch]$Clean
    )

    $target = $script:KmdTargets[$Package]
    Write-Step "$Driver`: $Os $Configuration | $($target.Platform)"

    $buildScript = Join-Path $script:KmdSource 'build.bat'
    if (-not (Test-Path -LiteralPath $buildScript)) { throw "`"$buildScript`" not found; is -KmdSource the viogpu-wddm repository?" }

    # The driver project reads these as MSBuild properties.
    $environment = Get-ProcessEnvironment
    foreach ($name in 'VIOGPU_UMD_DIR', 'VIOGPU_UMD_REVISION') { $environment.Remove($name) }
    $environment['VIOGPU_KMD_REVISION'] = $Revisions.Kmd
    if ($UmdDirectory) {
        $environment['VIOGPU_UMD_DIR'] = $UmdDirectory
        $environment['VIOGPU_UMD_REVISION'] = $Revisions.Umd
    }

    $arguments = @($Driver, $target.Platform, $Os, $Configuration)
    if ($Clean) { $arguments += '/Rebuild' }
    Invoke-Batch -Script $buildScript -Arguments $arguments -Environment $environment

    $root = 'Install'
    if ($Configuration -eq 'Debug') { $root = 'Install_Debug' }
    $installed = Join-Path $script:KmdSource "$root\$Os\$($target.InstallArch)"
    if (-not (Test-Path -LiteralPath (Join-Path $installed "$Driver.sys"))) {
        throw "The driver build succeeded but left no $Driver.sys in `"$installed`"."
    }
    return $installed
}
