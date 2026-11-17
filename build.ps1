#Requires -Version 5.1

<#
.SYNOPSIS
Builds the viogpu3d driver: the Neptune and Venus user-mode drivers from the
Mesa fork, the kernel driver, and the signed package that holds both. It can
also package the display-only driver, viogpudo.

.DESCRIPTION
With no arguments this builds everything for the host architecture,
incrementally, and leaves a test-signed driver package in
out\Win10\viogpu3d-<arch>.

Development builds and signed releases compile the same way (optimised, with
symbols), so they share objects; a release is the same build with more
architectures and a different -Sign.

See README.md for the full picture.

.PARAMETER Target
What to build. One or more of:
  all      neptune + venus + kmd (the default)
  umd      neptune + venus
  neptune  the Direct3D user-mode driver, neptune_umd.dll
  venus    the Vulkan ICD, vulkan_virtio.dll
  kmd      the viogpu3d kernel driver, and the package around it
  viogpudo the display-only driver and its package; not part of all
A viogpu3d package is assembled whenever kmd is among the targets; it takes
the user-mode files from the most recent build of each.

.PARAMETER Arch
One or more of x86, x64, arm64, arm64ec, arm64x, or all. Defaults to the host.
  x64      package: x64 driver + x64 user-mode drivers
  arm64    package: ARM64 driver + native ARM64 user-mode drivers only
  arm64x   package: ARM64 driver + ARM64X user-mode drivers, which also serve
           x64 applications under emulation (builds arm64 and arm64ec)
  x86      user-mode only: the 32-bit Direct3D driver. Listed next to a
           package architecture, it is added to that package for WOW64.
  arm64ec  user-mode only: the emulation view on its own
  all      x64, arm64x and x86: everything a release ships
viogpudo has no user-mode half, so it comes as x64 and arm64 only: arm64x
builds the same package as arm64, and x86 and arm64ec build nothing.

.PARAMETER Os
Win10 (the default) or Win11: the driver project configuration to build.

.PARAMETER Configuration
Release (the default) or Debug. Debug selects the checked kernel driver; the
user-mode drivers are always optimised builds with symbols.

.PARAMETER Clean
Rebuild the selected targets from scratch instead of incrementally.

.PARAMETER KmdSource
The viogpu-wddm checkout. Defaults to config.psd1, then ..\viogpu-wddm.

.PARAMETER UmdSource
The Mesa fork checkout. Defaults to config.psd1, then ..\mesa.

.PARAMETER Sign
  test         (default) sign the driver and catalog for a test-signing guest,
               with -Cert* or, by default, the driver repository's test
               certificate
  attestation  sign every binary with your EV certificate and produce the
               signed .cab that submit.ps1 uploads to Partner Center
  none         leave the package unsigned

.PARAMETER CertFile
A .pfx to sign with. Its password, if any, is read from VIOGPU_SIGN_PASSWORD.

.PARAMETER CertThumbprint
The SHA-1 thumbprint of a certificate in the certificate store to sign with.

.PARAMETER CertSubject
The subject name of a certificate in the certificate store to sign with.

.PARAMETER TimestampUrl
An RFC 3161 timestamp server. Attestation signing always timestamps and
defaults to DigiCert's; test signing timestamps only when this is given.

.PARAMETER Cab
Also produce the submission cabinet out\<Os>\viogpu3d-<package>.cab, signed like
the package. -Sign attestation implies it; with another -Sign it is a
rehearsal of the release that Partner Center would not accept.

.PARAMETER AllowDirty
Let -Sign attestation proceed from sources with uncommitted changes or from
user-mode drivers built at different commits.

.EXAMPLE
.\build.ps1
Everything for the host architecture, test-signed.

.EXAMPLE
.\build.ps1 -Target neptune -Arch arm64x
Rebuild just the Direct3D driver, in both ARM64 views.

.EXAMPLE
.\build.ps1 -Target all,viogpudo -Arch all
Both drivers for every architecture: what a release ships, test-signed.

.EXAMPLE
.\build.ps1 -Arch all -Sign attestation -CertThumbprint 0123456789abcdef0123456789abcdef01234567
The release packages, EV-signed and ready for submit.ps1.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [string[]]$Target = @('all'),
    [string[]]$Arch = @(),
    [ValidateSet('Win10', 'Win11')] [string]$Os = 'Win10',
    [ValidateSet('Release', 'Debug')] [string]$Configuration = 'Release',
    [switch]$Clean,
    [string]$KmdSource,
    [string]$UmdSource,
    [ValidateSet('test', 'attestation', 'none')] [string]$Sign = 'test',
    [string]$CertFile,
    [string]$CertThumbprint,
    [string]$CertSubject,
    [string]$TimestampUrl,
    [switch]$Cab,
    [switch]$AllowDirty
)

. (Join-Path $PSScriptRoot 'lib\common.ps1')
. (Join-Path $PSScriptRoot 'lib\umd.ps1')
. (Join-Path $PSScriptRoot 'lib\kmd.ps1')
. (Join-Path $PSScriptRoot 'lib\package.ps1')

# "-Arch x64,arm64x" arrives as one string when the script is started with
# powershell -File (which is what build.cmd does), so split lists here. This
# also gives every value its canonical spelling.
function Expand-List {
    param([string[]]$Values, [string[]]$Allowed, [string]$What)
    $result = @()
    foreach ($value in @($Values | ForEach-Object { $_ -split '[,;\s]+' } | Where-Object { $_ })) {
        $match = @($Allowed | Where-Object { $_ -ieq $value })
        if (-not $match) { throw "Unknown $What `"$value`". Expected: $($Allowed -join ', ')." }
        if ($result -notcontains $match[0]) { $result += $match[0] }
    }
    return $result
}

# A source checkout: the parameter, else config.psd1, else a sibling directory.
function Resolve-Source {
    param([string]$Given, [string]$Configured, [string]$Sibling, [string]$Marker, [string]$Parameter, [bool]$Required)

    $path = Join-Path (Split-Path -Parent $script:RepoRoot) $Sibling
    if ($Given) { $path = Resolve-FullPath $Given } elseif ($Configured) { $path = $Configured }
    $path = [System.IO.Path]::GetFullPath($path)
    if (Test-Path -LiteralPath (Join-Path $path $Marker)) { return $path.TrimEnd('\') }
    if (-not $Required) { return $null }
    throw "`"$path`" is not a checkout with $Marker. Pass -$Parameter, or set $Parameter in config.psd1 (see config.example.psd1)."
}

# Signs a freshly assembled package the way -Sign asks, writes the manifest
# that describes it, and builds its submission cabinet when one is wanted.
# Returns the lines for the closing summary.
function Complete-Package {
    param($Info, $Revisions, $Certificate, [string]$OutDirectory)

    $signer = $null
    if ($Certificate) { $signer = Protect-DriverPackage $Info $Sign $Certificate }

    # A record of the package next to it: what it is, what it was built from,
    # what is in it. resign.ps1 and submit.ps1 work from this.
    $manifest = [ordered]@{
        driver        = $Info.Driver
        package       = $Info.Package
        os            = $Os
        configuration = $Configuration
        version       = $Info.Version
        revisions     = $Revisions
        files         = $Info.Files
        signing       = [ordered]@{ mode = $Sign; signer = $signer }
    }
    $lines = @("$($Info.Name): $($Info.Directory)")

    # A cabinet from an earlier build no longer matches this package.
    $cabPath = Join-Path $OutDirectory "$($Info.Name).cab"
    Remove-Item -LiteralPath $cabPath -Force -ErrorAction SilentlyContinue
    if ($Cab -or $Sign -eq 'attestation') {
        Write-Step "Submission cabinet: $($Info.Name)"
        $manifest.cab = New-SignedCabinet $Info $cabPath $Certificate -Verify:($Sign -eq 'attestation')
        $lines += "$($Info.Name) cabinet: $cabPath"
    }
    Write-JsonFile (Join-Path $OutDirectory "$($Info.Name).json") $manifest
    return $lines
}

# Inside the block below, $PSBoundParameters is the block's own.
$boundParameters = $PSBoundParameters

Invoke-Main {
    # --- what was asked for ------------------------------------------------
    $targets = Expand-List $Target @('all', 'umd', 'kmd', 'neptune', 'venus', 'viogpudo') 'target'
    $components = @()
    if (@($targets | Where-Object { $_ -in 'all', 'umd', 'neptune' })) { $components += 'neptune' }
    if (@($targets | Where-Object { $_ -in 'all', 'umd', 'venus' }))   { $components += 'venus' }
    $buildKmd = [bool]@($targets | Where-Object { $_ -in 'all', 'kmd' })
    $buildDisplayOnly = $targets -contains 'viogpudo'

    $hostArch = Get-HostArch
    if (-not $Arch) { $Arch = @($hostArch) }
    $arches = Expand-List $Arch @('x86', 'x64', 'arm64', 'arm64ec', 'arm64x', 'all') 'architecture'
    if ($arches -contains 'all') { $arches = @($arches | Where-Object { $_ -ne 'all' }) + @('x64', 'arm64x', 'x86') | Select-Object -Unique }

    # Mesa is built per machine architecture; arm64x is two of them.
    $mesaArches = @()
    if ($arches -contains 'x86') { $mesaArches += 'x86' }
    if ($arches -contains 'x64') { $mesaArches += 'x64' }
    if ($arches -contains 'arm64' -or $arches -contains 'arm64x') { $mesaArches += 'arm64' }
    if ($arches -contains 'arm64ec' -or $arches -contains 'arm64x') { $mesaArches += 'arm64ec' }
    $packages = @('x64', 'arm64', 'arm64x' | Where-Object { $arches -contains $_ })
    $includeWow = $arches -contains 'x86'

    # The display-only driver has no user-mode half: one package per kernel
    # architecture.
    $displayOnlyPackages = @()
    if ($buildDisplayOnly) {
        if ($arches -contains 'x64') { $displayOnlyPackages += 'x64' }
        if ($arches -contains 'arm64' -or $arches -contains 'arm64x') { $displayOnlyPackages += 'arm64' }
    }

    # --- where things are --------------------------------------------------
    $config = Read-LocalConfig
    foreach ($name in 'CertFile', 'CertThumbprint', 'CertSubject', 'TimestampUrl') {
        if (-not (Get-Variable -Name $name -ValueOnly) -and $config.ContainsKey($name)) {
            Set-Variable -Name $name -Value $config[$name]
        }
    }
    # Certificate settings in config.psd1 describe the release certificate;
    # plain test signing keeps using the driver repository's test certificate
    # unless a certificate is named on the command line.
    if ($Sign -eq 'test') {
        foreach ($name in 'CertFile', 'CertThumbprint', 'CertSubject', 'TimestampUrl') {
            if (-not $boundParameters.ContainsKey($name)) { Set-Variable -Name $name -Value '' }
        }
    }

    $script:BuildRoot = Join-Path $script:RepoRoot 'build'
    $script:OutRoot = Join-Path $script:RepoRoot 'out'
    $script:UmdSource = Resolve-Source $UmdSource $config['UmdSource'] 'mesa' 'src\virtio\neptune\meson.build' 'UmdSource' ([bool]$components)
    $script:KmdSource = Resolve-Source $KmdSource $config['KmdSource'] 'viogpu-wddm' 'viogpu3d\viogpu3d.vcxproj' 'KmdSource' ($buildKmd -or $buildDisplayOnly)

    $outDirectory = Join-Path $script:OutRoot $Os
    if ($Configuration -eq 'Debug') { $outDirectory += '-Debug' }

    # --- revisions and version ---------------------------------------------
    $buildRevision = Get-GitRevision $script:RepoRoot
    $kmdRevision = $null
    $umdRevision = $null
    if ($script:KmdSource) { $kmdRevision = Get-GitRevision $script:KmdSource }
    if ($script:UmdSource) { $umdRevision = Get-GitRevision $script:UmdSource }

    if ($Sign -eq 'attestation' -and -not $AllowDirty) {
        $dirty = @()
        if ($buildRevision.Dirty) { $dirty += 'this repository' }
        if ($kmdRevision -and $kmdRevision.Dirty) { $dirty += $script:KmdSource }
        if ($components -and $umdRevision.Dirty) { $dirty += $script:UmdSource }
        if ($dirty) { throw "Uncommitted changes in $($dirty -join ' and '). Commit them, or pass -AllowDirty to sign a release that no commit describes." }
    }

    $version = '0.0.0.0'
    if ($script:KmdSource) {
        $version = Get-KmdDriverVersion $Os
    } elseif ($components) {
        Write-Note 'No kernel driver checkout: the user-mode drivers are stamped 0.0.0.0 and cannot be packaged.'
    }

    $certificate = $null
    if (($buildKmd -or $buildDisplayOnly) -and $Sign -ne 'none') {
        $certificate = Resolve-Certificate -Mode $Sign -CertFile $CertFile -CertThumbprint $CertThumbprint `
                                           -CertSubject $CertSubject -TimestampUrl $TimestampUrl
    }

    # --- say what is about to happen ----------------------------------------
    Write-Step "Driver version $version, $Os $Configuration"
    $what = @($components)
    if ($buildKmd) { $what += 'kernel driver' }
    if ($buildDisplayOnly) { $what += 'viogpudo' }
    Write-Info "build          $($what -join ', ')$(if ($Clean) { ' (clean)' })"
    if ($components) { Write-Info "mesa           $($script:UmdSource) @ $($umdRevision.Token) [$($mesaArches -join ', ')]" }
    if ($buildKmd -or $buildDisplayOnly) { Write-Info "viogpu-wddm    $($script:KmdSource) @ $($kmdRevision.Token)" }
    $planned = @()
    if ($buildKmd) { $planned += @($packages | ForEach-Object { "viogpu3d-$_" }) }
    $planned += @($displayOnlyPackages | ForEach-Object { "viogpudo-$_" })
    if ($planned) {
        $wow = ''
        if ($buildKmd -and $packages -and $includeWow) { $wow = ' (viogpu3d with the x86 WOW64 driver)' }
        Write-Info "packages       $($planned -join ', ')$wow"
        $signing = 'none'
        if ($certificate) { $signing = "$Sign, $($certificate.Name)" }
        Write-Info "signing        $signing"
    }
    if ($buildDisplayOnly -and -not $displayOnlyPackages) {
        Write-Note 'viogpudo is built for x64 and arm64; none of the requested architectures has a kernel driver.'
    }
    if ($includeWow -and -not $packages -and ($components -or $buildKmd)) {
        Write-Note 'x86 is a user-mode architecture only. It is packaged as the WOW64 driver of x64, arm64 or arm64x.'
    }
    if ($arches -contains 'arm64ec' -and $arches -notcontains 'arm64x' -and ($components -or $buildKmd)) {
        Write-Note 'arm64ec builds the emulation view on its own. -Arch arm64x builds and packages both views.'
    }

    # --- user-mode drivers ---------------------------------------------------
    if ($components) {
        foreach ($mesaArch in $mesaArches) {
            # No 32-bit Vulkan ICD is registered, so x86 is Neptune only.
            $wanted = $components
            if ($mesaArch -eq 'x86') { $wanted = @($components | Where-Object { $_ -eq 'neptune' }) }
            if (-not $wanted) { continue }
            Build-UmdArch -Arch $mesaArch -Components $wanted -Version $version -Revision $umdRevision -Clean:$Clean
        }
        if ($arches -contains 'arm64x') { Join-UmdArm64x $components }
    }

    # --- packages ------------------------------------------------------------
    $results = @()
    $viogpu3dPackages = @()
    if ($components -or $buildKmd) { $viogpu3dPackages = $packages }
    foreach ($package in $viogpu3dPackages) {
        $plan = Get-UmdStagePlan $package $includeWow
        if ($plan.Missing) {
            $hint = "not built yet: $($plan.Missing -join ', ')"
            if ($buildKmd) { throw "The $package package needs user-mode files that are $hint. Build them first (-Target umd or all, same -Arch)." }
            Write-Note "out\umd\$package not staged, $hint"
            continue
        }
        $stage = Publish-UmdStage $plan
        if (-not $buildKmd) {
            $results += "user-mode files for $package`: $($stage.Directory)"
            continue
        }

        if ($stage.Revisions.Count -gt 1) {
            Write-Note "The $package user-mode files were built at different Mesa commits: $($stage.Revisions -join ', ')."
        }
        if ($Sign -eq 'attestation' -and -not $AllowDirty -and
            ($stage.Revisions.Count -ne 1 -or $stage.Revisions[0] -match '\+|unknown')) {
            throw "The $package user-mode files do not come from one clean Mesa commit ($($stage.Revisions -join ', ')). Rebuild them, or pass -AllowDirty."
        }

        $revisions = [ordered]@{ kmd = $kmdRevision.Token; umd = ($stage.Revisions -join ','); build = $buildRevision.Token }
        $installed = Build-Kmd -Driver viogpu3d -Package $package -Os $Os -Configuration $Configuration `
                               -UmdDirectory $stage.Directory -Revisions $revisions -Clean:$Clean
        $info = New-DriverPackage -Driver viogpu3d -Package $package -InstallDirectory $installed -Stage $stage `
                                  -Destination (Join-Path $outDirectory "viogpu3d-$package")
        $results += Complete-Package $info $revisions $certificate $outDirectory
    }

    foreach ($package in $displayOnlyPackages) {
        $revisions = [ordered]@{ kmd = $kmdRevision.Token; build = $buildRevision.Token }
        $installed = Build-Kmd -Driver viogpudo -Package $package -Os $Os -Configuration $Configuration `
                               -Revisions $revisions -Clean:$Clean
        $info = New-DriverPackage -Driver viogpudo -Package $package -InstallDirectory $installed `
                                  -Destination (Join-Path $outDirectory "viogpudo-$package")
        $results += Complete-Package $info $revisions $certificate $outDirectory
    }

    # --- done ----------------------------------------------------------------
    Write-Step 'Done'
    if (-not $viogpu3dPackages -and $components) {
        foreach ($mesaArch in $mesaArches) {
            $record = Read-UmdRecord $mesaArch
            foreach ($component in $components) {
                $library = Get-JsonValue (Get-JsonValue $record $component) 'library'
                if ($library) { $results += "$component ($mesaArch): $library" }
            }
        }
    }
    foreach ($line in $results) { Write-Ok $line }
    if ($components) { Write-Info "symbols: $(Join-Path $script:OutRoot 'symbols')" }
    if ($Sign -eq 'attestation' -and $planned) {
        Write-Info "Next: .\submit.ps1 -Os $Os$(if ($Configuration -eq 'Debug') { ' -Configuration Debug' })"
    }
}
