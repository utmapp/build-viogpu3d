#Requires -Version 5.1

<#
.SYNOPSIS
Signs packages that build.ps1 already built, test-signed or unsigned, with your
EV certificate, and produces the cabinets that submit.ps1 uploads.

.DESCRIPTION
This is the second half of "build.ps1 -Sign attestation", for a build that was
made somewhere the EV certificate is not: the GitHub workflow, or an earlier
local build. Download the workflow's artifact, then:

  resign -Path <artifact> -CertThumbprint <thumbprint>
  submit -Path <artifact>

For each package it removes whatever signatures the files carry, signs every
binary with the certificate, builds <name>.cab next to the package, signs that
too, and records the result in the package manifest. The packages are changed
in place; running it again starts over from the same files.

Only signtool (from the Windows SDK) is needed, and with -Provider also
inf2cat (from the Windows Driver Kit). Nothing is compiled.

.PARAMETER Path
The build to sign: the directory holding the package directories and their
manifests (viogpu3d-x64.json and so on), the directory above it (an extracted
workflow artifact), or the artifact's .zip, which is extracted next to itself.
Defaults to this repository's out\<Os>.

.PARAMETER Os
Win10 (the default) or Win11: which local build to sign. Not used with -Path.

.PARAMETER Configuration
Release (the default) or Debug: which local build to sign. Not used with -Path.

.PARAMETER Package
The packages to sign, by name, such as viogpu3d-x64,viogpudo-arm64. Defaults
to all of them.

.PARAMETER Provider
A name to put in each INF in place of "Red Hat, Inc.", which the driver
repository's INFs give as the provider and manufacturer of the driver. Windows
shows it as "Driver Provider" and "Manufacturer" in Device Manager. (The
publisher Windows asks about when a driver is installed is the signing
certificate, not this.) Changing the INF means rebuilding the catalog, which
needs inf2cat. Defaults to config.psd1, then to leaving the INF alone.

.PARAMETER CertFile
A .pfx to sign with. Its password, if any, is read from VIOGPU_SIGN_PASSWORD.

.PARAMETER CertThumbprint
The SHA-1 thumbprint of a certificate in the certificate store to sign with.

.PARAMETER CertSubject
The subject name of a certificate in the certificate store to sign with.

.PARAMETER TimestampUrl
An RFC 3161 timestamp server. Defaults to DigiCert's.

.PARAMETER AllowDirty
Sign a build that was made from sources with uncommitted changes, from
user-mode drivers built at different commits, or from an unknown revision.

.EXAMPLE
.\resign.ps1 -Path $HOME\Downloads\viogpu-Win10.zip -CertThumbprint 0123456789abcdef0123456789abcdef01234567

.EXAMPLE
.\resign.ps1
Signs the local out\Win10 build with the certificate named in config.psd1.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Path,
    [ValidateSet('Win10', 'Win11')] [string]$Os = 'Win10',
    [ValidateSet('Release', 'Debug')] [string]$Configuration = 'Release',
    [string[]]$Package = @(),
    [string]$Provider,
    [string]$CertFile,
    [string]$CertThumbprint,
    [string]$CertSubject,
    [string]$TimestampUrl,
    [switch]$AllowDirty
)

. (Join-Path $PSScriptRoot 'lib\common.ps1')
. (Join-Path $PSScriptRoot 'lib\package.ps1')

Invoke-Main {
    $config = Read-LocalConfig
    foreach ($name in 'Provider', 'CertFile', 'CertThumbprint', 'CertSubject', 'TimestampUrl') {
        if (-not (Get-Variable -Name $name -ValueOnly) -and $config.ContainsKey($name)) {
            Set-Variable -Name $name -Value $config[$name]
        }
    }
    $script:BuildRoot = Join-Path $script:RepoRoot 'build'

    if ($Provider) {
        # It goes into a quoted INF string, in a file that is not Unicode.
        $Provider = $Provider.Trim()
        if ($Provider -notmatch '^[\x20-\x7E]+$' -or $Provider -match '["%]') {
            throw "-Provider `"$Provider`" cannot go into an INF: use plain ASCII without quotation marks or percent signs."
        }
        try {
            Find-KitTool 'inf2cat.exe' | Out-Null
        } catch {
            throw '-Provider changes the INF, so the catalog has to be rebuilt, and inf2cat.exe (Windows Driver Kit) was not found.'
        }
    }

    # --- which build -----------------------------------------------------------
    $submitArguments = "-Os $Os"
    if ($Configuration -eq 'Debug') { $submitArguments += ' -Configuration Debug' }
    if ($Path) {
        $source = Resolve-FullPath $Path
        if ((Test-Path -LiteralPath $source -PathType Leaf) -and [System.IO.Path]::GetExtension($source) -eq '.zip') {
            # A downloaded artifact. Extract it afresh, so that a second run
            # cannot mix two downloads.
            $extracted = Join-Path (Split-Path -Parent $source) ([System.IO.Path]::GetFileNameWithoutExtension($source))
            # ... unless the first one is already with Microsoft: that
            # directory then holds the only record of the submission.
            if ((Test-Path -LiteralPath $extracted) -and
                (Get-ChildItem -LiteralPath $extracted -Recurse -Filter 'submission.json' -File | Select-Object -First 1)) {
                throw "`"$extracted`" was extracted from this archive before and has been submitted from. Pass that directory as -Path to sign it again, or delete it to start over."
            }
            Write-Step "Extracting $(Split-Path -Leaf $source)"
            Reset-Directory $extracted
            Expand-Archive -LiteralPath $source -DestinationPath $extracted -Force
            Write-Info $extracted
            $source = $extracted
        }
        $directory = Resolve-PackageRoot $source
        $submitArguments = "-Path `"$directory`""
    } else {
        $directory = Join-Path (Join-Path $script:RepoRoot 'out') $Os
        if ($Configuration -eq 'Debug') { $directory += '-Debug' }
        if (-not (Test-Path -LiteralPath $directory)) { throw "`"$directory`" not found. Build first, or pass -Path." }
    }

    $manifests = Get-PackageManifests $directory
    $names = @($Package | ForEach-Object { $_ -split '[,;\s]+' } | Where-Object { $_ })
    if (-not $names) { $names = @($manifests.Keys | Sort-Object) }
    if (-not $names) { throw "No packages in `"$directory`"." }
    foreach ($name in $names) {
        if (-not $manifests.ContainsKey($name)) {
            throw "No `"$name`" package in `"$directory`". It has: $(@($manifests.Keys | Sort-Object) -join ', ')."
        }
    }

    $certificate = Resolve-Certificate -Mode attestation -CertFile $CertFile -CertThumbprint $CertThumbprint `
                                       -CertSubject $CertSubject -TimestampUrl $TimestampUrl

    # --- look before touching anything ---------------------------------------
    # Every package is checked first, so that a problem with the second one
    # does not leave the first one signed and the set half done.
    Write-Step "Re-signing $directory"
    $packages = @()
    foreach ($name in $names) {
        $manifest = $manifests[$name]
        $info = Get-PackageInfo $directory $manifest
        if (-not (Test-Path -LiteralPath $info.Directory -PathType Container)) { throw "`"$($info.Directory)`" not found." }
        $version = Test-DriverPackage -Driver $info.Driver -Directory $info.Directory -Files $info.Files
        if ($version -ne $info.Version) {
            throw "The $name package is version $version but its manifest says $($info.Version)."
        }

        # Which commits it was built from: the driver, Mesa for the 3D driver,
        # and these scripts.
        $revisions = Get-JsonValue $manifest 'revisions'
        $stamps = @($revisions.PSObject.Properties | ForEach-Object { [string]$_.Value })
        $built = @($revisions.PSObject.Properties | ForEach-Object { "$($_.Name) $($_.Value)" }) -join ', '
        $signedBy = Get-JsonValue (Get-JsonValue (Get-JsonValue $manifest 'signing') 'signer') 'subject'
        if (-not $signedBy) { $signedBy = 'nobody' }
        Write-Info "$name $($info.Version): $($info.Files.Count) files, signed by $signedBy"
        Write-Info "  built from $built"
        $rename = ''
        if ($Provider) {
            $rename = Test-InfProvider $info $Provider
            if ($rename -eq 'replace') { Write-Info "  provider `"$($script:UpstreamProvider)`" becomes `"$Provider`"" }
        }
        $info | Add-Member -NotePropertyName Rename -NotePropertyValue $rename

        # The same rule as build.ps1 -Sign attestation: a release names the
        # commits it was built from, so each has to be one clean commit.
        if (-not $AllowDirty -and (-not $stamps -or @($stamps | Where-Object { $_ -notmatch '^[0-9a-f]{10}$' }))) {
            throw "The $name package was not built from clean commits ($built). Build it again from committed sources, or pass -AllowDirty."
        }
        $packages += $info
    }

    # The certificate gets the same treatment: sign a scratch copy of one
    # binary first, so that a wrong, absent or untrusted certificate stops
    # here and not after the existing signatures have been removed.
    Write-Step "Checking $($certificate.Name)"
    Confirm-Directory $script:BuildRoot
    $sample = Join-Path $packages[0].Directory "$($packages[0].Driver).sys"
    $scratch = Join-Path $script:BuildRoot 'resign-check.sys'
    try {
        Copy-Item -LiteralPath $sample -Destination $scratch -Force
        Remove-Signature @($scratch)
        Add-Signature -Paths @($scratch) -Certificate $certificate -Verify
    } finally {
        Remove-Item -LiteralPath $scratch -Force -ErrorAction SilentlyContinue
    }

    # --- sign --------------------------------------------------------------------
    $cabinets = @()
    foreach ($info in $packages) {
        Write-Step "Package: $($info.Name)"
        if ($info.Rename -eq 'replace') {
            # The catalog holds a hash of the INF, so it is rebuilt, which
            # also leaves it without a signature.
            Set-InfProvider $info $Provider
            New-Catalog -Driver $info.Driver -Package $info.Package -Directory $info.Directory
            Write-Info "provider is now `"$Provider`"; catalog rebuilt"
        }

        # Off with what is there (a test signature, usually), on with the
        # certificate. A signed catalog is handled by Protect-DriverPackage.
        Remove-Signature @($info.Files | ForEach-Object { Join-Path $info.Directory $_ })
        $signer = Protect-DriverPackage $info 'attestation' $certificate

        Write-Step "Submission cabinet: $($info.Name)"
        $cabPath = Join-Path $directory "$($info.Name).cab"
        Remove-Item -LiteralPath $cabPath -Force -ErrorAction SilentlyContinue
        $cabinet = New-SignedCabinet $info $cabPath $certificate -Verify

        # The manifest keeps everything the build recorded; only who signed
        # the package changes, and the cabinet is new.
        $manifest = $info.Manifest
        $entries = @(@('signing', [ordered]@{ mode = 'attestation'; signer = $signer }), @('cab', $cabinet))
        if ($info.Rename) { $entries += , @('provider', $Provider) }
        foreach ($entry in $entries) {
            if ($manifest.PSObject.Properties[$entry[0]]) {
                $manifest.($entry[0]) = $entry[1]
            } else {
                $manifest | Add-Member -NotePropertyName $entry[0] -NotePropertyValue $entry[1]
            }
        }
        Write-JsonFile (Join-Path $directory "$($info.Name).json") $manifest
        $cabinets += $cabPath
    }

    Write-Step 'Done'
    foreach ($cabPath in $cabinets) { Write-Ok $cabPath }
    Write-Info "Next: .\submit.ps1 $submitArguments"
}
