# Driver packages: assembly, catalog, signing and submission cabinets.

# What the driver repository's build contributes to a package of each driver:
# viogpu3d, the 3D driver that the user-mode drivers are added to, and
# viogpudo, the display-only driver, which is complete as it is. The .pdb
# files are deliberate: nothing in the INF references them and Microsoft does
# not sign or return them, but the attestation documentation asks for symbols
# in the submission for automated crash analysis.
$script:DriverFiles = @{
    viogpu3d = @('viogpu3d.sys', 'viogpu3d.inf', 'viogpu3d.pdb',
                 'vgpusrv.exe', 'vgpusrv.pdb', 'viogpuap.exe', 'viogpuap.pdb')
    viogpudo = @('viogpudo.sys', 'viogpudo.inf', 'viogpudo.pdb',
                 'vgpusrv.exe', 'vgpusrv.pdb', 'viogpuap.exe', 'viogpuap.pdb')
}

# The systems a package's catalog is made for, in inf2cat's words: the same
# ones the driver repository names when it packages.
$script:CatalogOs = @{
    x64    = '10_X64,Server10_X64'
    arm64  = 'Server10_ARM64'
    arm64x = 'Server10_ARM64'
}

# The name the driver repository's INFs give as the provider and manufacturer
# of the driver. resign.ps1 can put another in its place.
$script:UpstreamProvider = 'Red Hat, Inc.'

# ---------------------------------------------------------------------------
#  INF reading
# ---------------------------------------------------------------------------
function Get-InfSection {
    param([string[]]$Lines, [string]$Section)
    $inside = $false
    $result = @()
    foreach ($line in $Lines) {
        $text = ($line -replace ';.*$', '').Trim()
        if ($text -match '^\[(.+)\]$') { $inside = ($Matches[1].Trim() -ieq $Section); continue }
        if ($inside -and $text) { $result += $text }
    }
    return $result
}

function Get-InfDriverVersion {
    param([string]$InfPath)
    foreach ($line in (Get-InfSection ([System.IO.File]::ReadAllLines($InfPath)) 'Version')) {
        if ($line -match '^DriverVer\s*=\s*[^,]+,\s*([0-9.]+)') { return $Matches[1] }
    }
    throw "`"$InfPath`" has no DriverVer."
}

# An INF as text, with the encoding to write it back in: UTF-16 or UTF-8 when
# it starts with that byte order mark, the system's ANSI code page otherwise,
# which is how stampinf leaves it.
function Read-Inf {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $encoding = [System.Text.Encoding]::Default
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $encoding = [System.Text.Encoding]::Unicode
    } elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $encoding = New-Object System.Text.UTF8Encoding($true)
    }
    $preamble = $encoding.GetPreamble().Length
    return [pscustomobject]@{
        Text     = $encoding.GetString($bytes, $preamble, $bytes.Length - $preamble)
        Encoding = $encoding
    }
}

# What putting $Provider in a package's INF would take: 'replace' when the INF
# still carries the upstream name, 'done' when it already carries the new one.
function Test-InfProvider {
    param($PackageInfo, [string]$Provider)
    $inf = Read-Inf (Join-Path $PackageInfo.Directory "$($PackageInfo.Driver).inf")
    if ($inf.Text.Contains($script:UpstreamProvider)) { return 'replace' }
    if ($inf.Text.Contains($Provider)) { return 'done' }
    throw "$($PackageInfo.Driver).inf of $($PackageInfo.Name) names neither `"$($script:UpstreamProvider)`" nor `"$Provider`"."
}

# Replaces the upstream provider name in a package's INF. The catalog records
# a hash of the INF, so the caller has to rebuild it.
function Set-InfProvider {
    param($PackageInfo, [string]$Provider)
    $path = Join-Path $PackageInfo.Directory "$($PackageInfo.Driver).inf"
    $inf = Read-Inf $path
    [System.IO.File]::WriteAllText($path, $inf.Text.Replace($script:UpstreamProvider, $Provider), $inf.Encoding)
}

# ---------------------------------------------------------------------------
#  Package directories
#
#  A built package has a name, <driver>-<package>, such as viogpu3d-arm64x or
#  viogpudo-x64. It is a directory of that name next to a manifest,
#  <name>.json, that records what it is and what is in it, and, once there is
#  one, its submission cabinet <name>.cab. They sit in out\<Os> in this
#  repository, or wherever a copy of that was put.
# ---------------------------------------------------------------------------

# The manifests of a directory, by package name.
function Get-PackageManifests {
    param([string]$Directory)
    $manifests = @{}
    foreach ($file in (Get-ChildItem -LiteralPath $Directory -Filter '*.json' -File)) {
        $manifest = Read-JsonFile $file.FullName
        $driver = Get-JsonValue $manifest 'driver'
        $package = Get-JsonValue $manifest 'package'
        if ($driver -and $package -and (Get-JsonValue $manifest 'files') -and $file.BaseName -eq "$driver-$package") {
            $manifests[$file.BaseName] = $manifest
        }
    }
    return $manifests
}

# A package as the functions below take it, from its manifest.
function Get-PackageInfo {
    param([string]$Root, $Manifest)
    $name = "$($Manifest.driver)-$($Manifest.package)"
    return [pscustomobject]@{
        Name      = $name
        Driver    = $Manifest.driver
        Package   = $Manifest.package
        Directory = Join-Path $Root $name
        Files     = @($Manifest.files)
        Version   = $Manifest.version
        Manifest  = $Manifest
    }
}

# The package root for a path given on the command line: the directory itself,
# or the one directory directly below it that holds manifests. The second is
# what a downloaded workflow artifact looks like, with out\<Os> inside it.
function Resolve-PackageRoot {
    param([string]$Path)

    $root = Resolve-FullPath $Path
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "`"$root`" is not a directory." }
    if ((Get-PackageManifests $root).Count) { return $root }

    $below = @(Get-ChildItem -LiteralPath $root -Directory | Where-Object { (Get-PackageManifests $_.FullName).Count })
    if ($below.Count -eq 1) { return $below[0].FullName }
    if ($below.Count -gt 1) {
        throw "`"$root`" holds more than one set of packages ($(@($below | ForEach-Object { $_.Name }) -join ', ')). Name one of them."
    }
    throw "No package manifests (<driver>-<package>.json) in `"$root`"."
}

# Checks a package directory against its file list and its own INF, and
# returns the driver version.
function Test-DriverPackage {
    param([string]$Driver, [string]$Directory, [string[]]$Files)

    $missing = @($Files | Where-Object { -not (Test-Path -LiteralPath (Join-Path $Directory $_) -PathType Leaf) })
    if ($missing) { throw "`"$Directory`" lacks $($missing -join ', ')." }

    # The INF is generated by the driver build from the same staged directory
    # the package was assembled from, so the two should always agree. Check
    # anyway: a file the INF does not list comes back from Microsoft unsigned,
    # and one it lists but the package lacks fails the install.
    $inf = Join-Path $Directory "$Driver.inf"
    $listed = @(Get-InfSection ([System.IO.File]::ReadAllLines($inf)) 'SourceDisksFiles' |
                ForEach-Object { ($_ -split '=')[0].Trim() })
    $payload = @($Files | Where-Object { [System.IO.Path]::GetExtension($_) -notin '.inf', '.pdb', '.cat' })
    $unlisted = @($payload | Where-Object { $listed -notcontains $_ })
    $absent = @($listed | Where-Object { $payload -notcontains $_ })
    if ($unlisted) { throw "$Driver.inf does not list: $($unlisted -join ', ')." }
    if ($absent)   { throw "$Driver.inf lists files the package does not have: $($absent -join ', ')." }

    # Windows requires the Direct3D UMD's file version to equal DriverVer.
    $version = Get-InfDriverVersion $inf
    foreach ($file in ($Files | Where-Object { $_ -like 'neptune_umd*.dll' })) {
        $fileVersion = (Get-Item -LiteralPath (Join-Path $Directory $file)).VersionInfo.FileVersion
        if ($fileVersion -ne $version) {
            throw "$file is version $fileVersion but the INF DriverVer is $version. Rebuild the user-mode drivers (-Target umd)."
        }
    }
    return $version
}

# Takes every embedded signature off the executables among $Paths. signtool
# can only do this for executables; see Protect-DriverPackage for catalogs.
function Remove-Signature {
    param([string[]]$Paths)

    $signtool = Find-KitTool 'signtool.exe'
    foreach ($path in $Paths) {
        if ([System.IO.Path]::GetExtension($path) -notin '.sys', '.dll', '.exe') { continue }
        if (-not (Get-AuthenticodeSignature -LiteralPath $path).SignerCertificate) { continue }
        $log = Invoke-Tool -FilePath $signtool -Arguments @('remove', '/s', $path) -Capture -AllowFailure
        if ($script:LastToolExitCode -ne 0 -or (Get-AuthenticodeSignature -LiteralPath $path).SignerCertificate) {
            throw "Could not remove the signature from `"$path`":`n$(($log + $script:LastToolErrors).Trim())"
        }
    }
}

# ---------------------------------------------------------------------------
#  Assembly
#
#  The package is put together here, in an empty directory, from one explicit
#  list: the kernel files out of the driver repository's Install directory
#  and, for viogpu3d, the user-mode files out of the staged directory the
#  driver was built against. The Install directory is not used as the package
#  because both drivers share it and it accumulates files.
# ---------------------------------------------------------------------------
function New-DriverPackage {
    param(
        [string]$Driver,
        [string]$Package,
        [string]$InstallDirectory,
        # The staged user-mode files; none for the display-only driver.
        $Stage,
        [string]$Destination
    )

    Write-Step "Package: $Driver-$Package"
    Reset-Directory $Destination

    $files = @($script:DriverFiles[$Driver])
    foreach ($file in $files) {
        $source = Join-Path $InstallDirectory $file
        if (-not (Test-Path -LiteralPath $source)) { throw "The driver build did not produce `"$source`"." }
        Copy-Item -LiteralPath $source -Destination $Destination
    }
    if ($Stage) {
        foreach ($file in $Stage.Files) {
            Copy-Item -LiteralPath (Join-Path $Stage.Directory $file) -Destination $Destination
        }
        $files += @($Stage.Files)
    }

    # The WDK test-signs the driver it builds with a certificate it generates
    # for the local user. Drop that, so the package carries the signatures
    # this script was asked for and no others.
    Remove-Signature @($files | ForEach-Object { Join-Path $Destination $_ })

    $version = Test-DriverPackage -Driver $Driver -Directory $Destination -Files $files

    New-Catalog -Driver $Driver -Package $Package -Directory $Destination
    $files += "$Driver.cat"

    Write-Ok "$Destination ($($files.Count) files, version $version)"
    return [pscustomobject]@{
        Name = "$Driver-$Package"; Driver = $Driver; Package = $Package
        Directory = $Destination; Files = $files; Version = $version
    }
}

# Builds a package's catalog, unsigned, replacing the one that is there.
function New-Catalog {
    param([string]$Driver, [string]$Package, [string]$Directory)

    $catalog = Join-Path $Directory "$Driver.cat"
    Remove-Item -LiteralPath $catalog -Force -ErrorAction SilentlyContinue
    # Local time, because stampinf dates the INF in local time and inf2cat
    # rejects a DriverVer date that is in the future in UTC.
    $log = Invoke-Tool -FilePath (Find-KitTool 'inf2cat.exe') -Capture -AllowFailure -Arguments @(
        "/driver:$Directory", "/os:$($script:CatalogOs[$Package])", '/uselocaltime')
    if ($script:LastToolExitCode -ne 0 -or -not (Test-Path -LiteralPath $catalog)) {
        throw "inf2cat failed for `"$Directory`":`n$(($log + $script:LastToolErrors).Trim())"
    }
}

# ---------------------------------------------------------------------------
#  Signing
# ---------------------------------------------------------------------------

# Works out which certificate signs, from the parameters and the signing mode.
function Resolve-Certificate {
    param(
        [string]$Mode,
        [string]$CertFile,
        [string]$CertThumbprint,
        [string]$CertSubject,
        [string]$TimestampUrl
    )

    $given = @(@($CertFile, $CertThumbprint, $CertSubject) | Where-Object { $_ })
    if ($given.Count -gt 1) { throw 'Name the certificate one way: -CertFile, -CertThumbprint or -CertSubject.' }

    $certificate = [pscustomobject]@{
        File = $CertFile; Thumbprint = $CertThumbprint; Subject = $CertSubject
        TimestampUrl = $TimestampUrl; Name = ''
        # VIOGPU_SIGN_PASSWORD belongs to a .pfx that was asked for by name.
        UsePassword = [bool]$CertFile
    }
    if ($given.Count -eq 0) {
        if ($Mode -ne 'test') {
            throw 'Attestation signing needs your EV certificate: pass -CertThumbprint or -CertSubject, or set one in config.psd1.'
        }
        # The test certificate the driver repository carries. It has no
        # password.
        $certificate.File = Join-Path $script:KmdSource 'build\VirtIOTestCert.pfx'
    }
    if ($certificate.File) {
        if (-not (Test-Path -LiteralPath $certificate.File)) { throw "Certificate `"$($certificate.File)`" not found." }
        $certificate.File = (Resolve-Path -LiteralPath $certificate.File).ProviderPath
        $certificate.Name = Split-Path -Leaf $certificate.File
    } elseif ($certificate.Thumbprint) {
        $certificate.Thumbprint = ($certificate.Thumbprint -replace '\s', '')
        $certificate.Name = "certificate $($certificate.Thumbprint)"
    } else {
        $certificate.Name = "`"$($certificate.Subject)`""
    }

    # A production signature has to outlive its certificate, so it is always
    # timestamped; a test signature is only timestamped on request.
    if (-not $certificate.TimestampUrl -and $Mode -ne 'test') { $certificate.TimestampUrl = 'http://timestamp.digicert.com' }
    return $certificate
}

function Get-SignArguments {
    param($Certificate, [switch]$Append)

    $arguments = @('sign', '/fd', 'sha256')
    if ($Append) { $arguments += '/as' }
    if ($Certificate.File) {
        $arguments += @('/f', $Certificate.File)
        # The password of a .pfx only ever comes from the environment.
        if ($Certificate.UsePassword -and $env:VIOGPU_SIGN_PASSWORD) { $arguments += @('/p', $env:VIOGPU_SIGN_PASSWORD) }
    } elseif ($Certificate.Thumbprint) {
        $arguments += @('/sha1', $Certificate.Thumbprint)
    } else {
        $arguments += @('/n', $Certificate.Subject)
    }
    if ($Certificate.TimestampUrl) { $arguments += @('/tr', $Certificate.TimestampUrl, '/td', 'sha256') }
    return $arguments
}

function Add-Signature {
    param(
        [string[]]$Paths,
        $Certificate,
        # Add a signature next to the existing ones instead of replacing them.
        [switch]$Append,
        # Require the result to chain to a trusted root. Not for test
        # certificates, which the build machine has no reason to trust.
        [switch]$Verify
    )

    $signtool = Find-KitTool 'signtool.exe'
    $arguments = Get-SignArguments $Certificate -Append:$Append
    foreach ($path in $Paths) {
        $log = Invoke-Tool -FilePath $signtool -Arguments ($arguments + @($path)) -Capture -AllowFailure
        if ($script:LastToolExitCode -ne 0) {
            throw "Signing `"$path`" with $($Certificate.Name) failed:`n$(($log + $script:LastToolErrors).Trim())"
        }
        if ($Verify) {
            $log = Invoke-Tool -FilePath $signtool -Arguments @('verify', '/pa', '/q', $path) -Capture -AllowFailure
            if ($script:LastToolExitCode -ne 0) {
                throw "`"$path`" was signed but does not verify (signtool verify /pa). Is $($Certificate.Name) a trusted code-signing certificate?"
            }
        }
        Write-Info "signed $(Split-Path -Leaf $path)"
    }
}

# Signs a package for the given mode and returns who signed it.
#
#   test         The driver and the catalog: all a test-signing machine checks.
#   attestation  Every executable. Microsoft replaces the catalog, so a fresh
#                one is left unsigned; the signature that matters to the
#                submission is the one on the cabinet. A catalog that already
#                carries a signature, as in a test-signed package that is
#                being re-signed, is signed too: signtool cannot take a
#                signature off a catalog, and signing replaces it.
function Protect-DriverPackage {
    param($PackageInfo, [string]$Mode, $Certificate)

    Write-Step "Signing ($Mode) with $($Certificate.Name)"
    $extensions = @('.sys', '.cat')
    if ($Mode -eq 'attestation') { $extensions = @('.sys', '.dll', '.exe') }
    $paths = @($PackageInfo.Files | Where-Object { $extensions -contains [System.IO.Path]::GetExtension($_) } |
               ForEach-Object { Join-Path $PackageInfo.Directory $_ })
    if ($Mode -eq 'attestation') {
        $paths += @($PackageInfo.Files | Where-Object { [System.IO.Path]::GetExtension($_) -eq '.cat' } |
                    ForEach-Object { Join-Path $PackageInfo.Directory $_ } |
                    Where-Object { (Get-AuthenticodeSignature -LiteralPath $_).SignerCertificate })
    }
    Add-Signature -Paths $paths -Certificate $Certificate -Verify:($Mode -eq 'attestation')
    return (Get-Signer $paths[0])
}

function Get-Signer {
    param([string]$Path)
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if (-not $signature.SignerCertificate) { return $null }
    return [pscustomobject]@{
        thumbprint = $signature.SignerCertificate.Thumbprint
        subject    = $signature.SignerCertificate.Subject
    }
}

# ---------------------------------------------------------------------------
#  Submission cabinet
#
#  The Hardware Dashboard takes one .cab per submission, with the driver in a
#  folder of its own (it rejects files in the cabinet root).
# ---------------------------------------------------------------------------
function New-SubmissionCab {
    param($PackageInfo, [string]$CabPath)

    $name = Split-Path -Leaf $CabPath
    $directory = Split-Path -Parent $CabPath
    $scratch = Join-Path $script:BuildRoot 'cab'
    Confirm-Directory $scratch
    $ddf = Join-Path $scratch ([System.IO.Path]::ChangeExtension($name, '.ddf'))

    $lines = @(
        '.OPTION EXPLICIT',
        '.Set CabinetFileCountThreshold=0',
        '.Set FolderFileCountThreshold=0',
        '.Set FolderSizeThreshold=0',
        '.Set MaxCabinetSize=0',
        '.Set MaxDiskFileCount=0',
        '.Set MaxDiskSize=0',
        '.Set CompressionType=MSZIP',
        '.Set Cabinet=on',
        '.Set Compress=on',
        ".Set CabinetNameTemplate=$name",
        # An empty disk directory writes the cabinet into the working
        # directory; "nul" suppresses makecab's setup.inf and setup.rpt.
        '.Set DiskDirectoryTemplate=',
        '.Set InfFileName=nul',
        '.Set RptFileName=nul',
        ".Set DestinationDir=$($PackageInfo.Driver)"
    )
    foreach ($file in $PackageInfo.Files) { $lines += ('"' + (Join-Path $PackageInfo.Directory $file) + '"') }
    [System.IO.File]::WriteAllLines($ddf, $lines, [System.Text.Encoding]::ASCII)

    Remove-Item -LiteralPath $CabPath -Force -ErrorAction SilentlyContinue
    $makecab = Join-Path $env:SystemRoot 'System32\makecab.exe'
    $log = Invoke-Tool -FilePath $makecab -Arguments @('/f', $ddf) -WorkingDirectory $directory -Capture -AllowFailure
    if ($script:LastToolExitCode -ne 0 -or -not (Test-Path -LiteralPath $CabPath)) {
        throw "makecab failed for `"$CabPath`":`n$(($log + $script:LastToolErrors).Trim())"
    }
    Write-Ok $CabPath
}

# Builds and signs the submission cabinet of a package and returns the entry
# that describes it in the package manifest.
function New-SignedCabinet {
    param($PackageInfo, [string]$CabPath, $Certificate, [switch]$Verify)

    New-SubmissionCab $PackageInfo $CabPath
    if ($Certificate) { Add-Signature -Paths @($CabPath) -Certificate $Certificate -Verify:$Verify }
    return [ordered]@{
        file   = (Split-Path -Leaf $CabPath)
        sha256 = (Get-FileHash -LiteralPath $CabPath -Algorithm SHA256).Hash
        signer = (Get-Signer $CabPath)
    }
}

# The files of a cabinet, as leaf names. expand.exe -D prints one
# "<cabinet>: <file>" line per entry.
function Get-CabFiles {
    param([string]$CabPath)
    $expand = Join-Path $env:SystemRoot 'System32\expand.exe'
    $listing = Invoke-Tool -FilePath $expand -Arguments @('-D', $CabPath) -Capture
    $prefix = "$($CabPath): "
    return @($listing -split "`r?`n" |
             Where-Object { $_.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase) } |
             ForEach-Object { Split-Path -Leaf $_.Substring($prefix.Length).Trim() })
}
