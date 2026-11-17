#Requires -Version 5.1

<#
.SYNOPSIS
Submits the cabinets built by "build.ps1 -Sign attestation" or by resign.ps1
to the Microsoft Hardware Dashboard (Partner Center) for attestation signing,
and collects the signed packages.

.DESCRIPTION
For each package it creates a product that requests the Windows signatures
for the package's architecture, uploads the cabinet, commits
the submission, waits for Microsoft to sign it, downloads the result into
signed\<package> next to the cabinets and checks the signatures on it.

Progress is kept in submission.json next to the cabinets, so -Status and
-Download work from a later session, and a cabinet that was already submitted
is not submitted twice.

Credentials are an Entra ID application associated with the Partner Center
account (Manager role, plus Hardware > Driver Submitter). They come from the
environment variables HDC_TENANT_ID, HDC_CLIENT_ID and HDC_CLIENT_SECRET, or
from the JSON file named by -CredentialFile:
  { "tenantId": "...", "clientId": "...", "clientSecret": "..." }

.PARAMETER Path
The directory holding the cabinets and their manifests, when it is not this
repository's out\<Os>: for example the workflow build that resign.ps1 signed.

.PARAMETER Os
Win10 (the default) or Win11: which build's cabinets to submit. Not used with
-Path.

.PARAMETER Configuration
Release (the default) or Debug, as given to build.ps1. Not used with -Path.

.PARAMETER Package
The packages to act on, by name, such as viogpu3d-x64,viogpudo-arm64. Defaults
to every cabinet built.

.PARAMETER CredentialFile
A JSON file with the Partner Center credentials. Defaults to config.psd1.

.PARAMETER ProductName
Text to put in front of the product names, which are the driver, its version,
the package and a timestamp. Defaults to config.psd1, then nothing.

.PARAMETER AnnouncementDate
The product's announcement date, which the API requires. Defaults to today.

.PARAMETER DryRun
Check the cabinets and show what would be requested, without contacting
Partner Center.

.PARAMETER NoWait
Submit and return; use -Status and -Download later.

.PARAMETER PollIntervalSeconds
How often to ask Partner Center for progress while waiting. Defaults to 60.

.PARAMETER TimeoutMinutes
How long to wait before giving up; the submission carries on regardless and
-Status picks it up. Defaults to 240.

.PARAMETER Status
Show where the recorded submissions stand.

.PARAMETER Download
Download the signed packages of the recorded submissions.

.PARAMETER Force
Submit again even though this cabinet was already submitted.

.PARAMETER NoExpand
Keep the downloaded .zip as it is; skips the signature check.

.PARAMETER AppendSignature
If a signed binary came back without the signature it was submitted with, add
that signature again next to Microsoft's. Uses the certificate that signed the
cabinet unless -CertFile, -CertThumbprint or -CertSubject names one.

.PARAMETER CertFile
For -AppendSignature: a .pfx to sign with (password in VIOGPU_SIGN_PASSWORD).

.PARAMETER CertThumbprint
For -AppendSignature: the thumbprint of a certificate in the certificate store.

.PARAMETER CertSubject
For -AppendSignature: the subject name of a certificate in the certificate store.

.PARAMETER TimestampUrl
For -AppendSignature: the RFC 3161 timestamp server. Defaults to DigiCert's.

.EXAMPLE
.\submit.ps1 -DryRun

.EXAMPLE
.\submit.ps1 -NoWait
.\submit.ps1 -Status
.\submit.ps1 -Download
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Path,
    [ValidateSet('Win10', 'Win11')] [string]$Os = 'Win10',
    [ValidateSet('Release', 'Debug')] [string]$Configuration = 'Release',
    [string[]]$Package = @(),
    [string]$CredentialFile,
    [string]$ProductName,
    [datetime]$AnnouncementDate = (Get-Date).Date,
    [switch]$DryRun,
    [switch]$NoWait,
    [int]$PollIntervalSeconds = 60,
    [int]$TimeoutMinutes = 240,
    [switch]$Status,
    [switch]$Download,
    [switch]$Force,
    [switch]$NoExpand,
    [switch]$AppendSignature,
    [string]$CertFile,
    [string]$CertThumbprint,
    [string]$CertSubject,
    [string]$TimestampUrl
)

. (Join-Path $PSScriptRoot 'lib\common.ps1')
. (Join-Path $PSScriptRoot 'lib\package.ps1')
. (Join-Path $PSScriptRoot 'lib\hdc.ps1')

$MicrosoftSigner = 'Microsoft Windows Hardware Compatibility Publisher'

# ---------------------------------------------------------------------------
#  State: submission.json next to the cabinets, one entry per package.
# ---------------------------------------------------------------------------
function Get-Entry {
    param($State, [string]$Name)
    return (Get-JsonValue $State.packages $Name)
}

function Set-Entry {
    param($State, [string]$Name, $Value)
    if ($State.packages.PSObject.Properties[$Name]) {
        $State.packages.$Name = $Value
    } else {
        $State.packages | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

# ---------------------------------------------------------------------------
#  Before upload: the cabinet must be the one the build recorded, hold every
#  file of the package, and carry a trusted signature. Each of these is cheap
#  to check here and costs a product and an hour to learn from the dashboard.
# ---------------------------------------------------------------------------
function Test-Cabinet {
    param($Manifest, [string]$CabPath, [switch]$ReportOnly)

    if (-not (Test-Path -LiteralPath $CabPath)) { throw "`"$CabPath`" not found. Run build.ps1 -Sign attestation, or resign.ps1." }
    $hash = (Get-FileHash -LiteralPath $CabPath -Algorithm SHA256).Hash
    if ($hash -ne $Manifest.cab.sha256) { throw "`"$CabPath`" is not the cabinet its manifest describes. Rebuild it." }

    $inside = Get-CabFiles $CabPath
    $missing = @($Manifest.files | Where-Object { $inside -notcontains $_ })
    if ($missing) { throw "`"$CabPath`" lacks $($missing -join ', ')." }

    Invoke-Tool -FilePath (Find-KitTool 'signtool.exe') -Arguments @('verify', '/pa', '/q', $CabPath) -Capture -AllowFailure | Out-Null
    $signer = Get-JsonValue (Get-JsonValue $Manifest.cab 'signer') 'subject'
    if (-not $signer) { $signer = 'nobody' }
    Write-Info "$(Split-Path -Leaf $CabPath): $($inside.Count) files, signed by $signer"
    if ($script:LastToolExitCode -ne 0) {
        $problem = "`"$CabPath`" does not carry a trusted signature (signtool verify /pa). Attestation requires an EV-signed cabinet: build with -Sign attestation, or sign this build with resign.ps1."
        if (-not $ReportOnly) { throw $problem }
        Write-Note "The dashboard would reject this: $problem"
    }
    return $hash
}

# ---------------------------------------------------------------------------
#  Polling: one pass over the recorded submissions. Returns $true once every
#  one of them has either finished or failed.
# ---------------------------------------------------------------------------
function Update-Status {
    param($State, [string[]]$Names, [string]$StatePath)

    $settled = $true
    foreach ($name in $Names) {
        $entry = Get-Entry $State $name
        if (-not $entry) { continue }
        $submission = Get-HdcSubmission $entry.productId $entry.submissionId
        $entry.commitStatus = [string](Get-JsonValue $submission 'commitStatus')
        $workflow = Get-JsonValue $submission 'workflowStatus'
        if ($workflow) {
            $entry.step = [string](Get-JsonValue $workflow 'currentStep')
            $entry.state = [string](Get-JsonValue $workflow 'state')
        }
        $failed = ($entry.commitStatus -eq 'commitFailed') -or ($entry.state -eq 'failed')
        $done = (Get-HdcDownload $submission 'signedPackage') -and $entry.state -eq 'completed' -and
                $entry.step -eq 'finalizeIngestion'
        $entry.result = ''
        if ($failed) { $entry.result = 'failed' } elseif ($done) { $entry.result = 'signed' }

        $line = "[$name] $($entry.commitStatus)"
        if ($entry.step) { $line += ", $($entry.step) $($entry.state)" }
        if ($failed) { Write-Note $line } elseif ($done) { Write-Ok $line } else { Write-Info $line }
        foreach ($message in @(Get-JsonValue $workflow 'messages')) {
            if ($message) { Write-Note "      $message" }
        }
        if (-not ($failed -or $done)) { $settled = $false }
    }
    Write-JsonFile $StatePath $State
    return $settled
}

# ---------------------------------------------------------------------------
#  Download and check the signed package
# ---------------------------------------------------------------------------
function Save-SignedPackage {
    param($State, [string]$Name, [string]$Directory)

    $entry = Get-Entry $State $Name
    if (-not $entry) { Write-Note "[$Name] nothing submitted"; return $null }

    # The download links are short-lived SAS URIs: always ask again.
    $submission = Get-HdcSubmission $entry.productId $entry.submissionId
    $link = Get-HdcDownload $submission 'signedPackage'
    if (-not $link) { Write-Note "[$Name] not signed yet"; return $null }

    $target = Join-Path $Directory "signed\$Name"
    Confirm-Directory $target
    $zip = Join-Path $target "$Name-signed.zip"
    Invoke-WebRequest -Uri $link -OutFile $zip -UseBasicParsing
    Write-Ok "[$Name] $zip"

    # Files the INF does not reference come back unsigned; the dashboard says
    # which in a report of its own.
    $report = Get-HdcDownload $submission 'unreferencedFilesReport'
    if ($report) {
        $reportPath = Join-Path $target 'unreferenced-files.txt'
        try {
            Invoke-WebRequest -Uri $report -OutFile $reportPath -UseBasicParsing
            Write-Note "[$Name] the dashboard reported unreferenced files: $reportPath"
        } catch {
            Write-Note "[$Name] the dashboard reported unreferenced files, but the report could not be downloaded"
        }
    }

    if ($NoExpand) { return $null }
    $expanded = Join-Path $target 'package'
    Reset-Directory $expanded
    Expand-Archive -LiteralPath $zip -DestinationPath $expanded -Force
    return $expanded
}

# Checks what came back: every submitted binary present, each with Microsoft's
# signature and with the publisher's own.
#
# The attestation documentation describes the service both as appending its
# signature and as overwriting an existing one. It has been seen to append,
# which leaves the binaries dual-signed, but that is not promised, so look.
# Returns the binaries that lack the publisher's signature.
function Test-SignedPackage {
    param($Entry, [string]$Name, [string]$Directory)

    $signtool = Find-KitTool 'signtool.exe'
    $returned = @(Get-ChildItem -LiteralPath $Directory -Recurse -File)
    $binaries = @($Entry.files | Where-Object { [System.IO.Path]::GetExtension($_) -in '.sys', '.dll', '.exe' })
    $publisher = $Entry.signer

    $lost = @()
    $unsigned = @()
    $withoutPublisher = @()
    foreach ($binary in $binaries) {
        $file = @($returned | Where-Object { $_.Name -ieq $binary })
        if (-not $file) { $lost += $binary; continue }
        # /all /v lists every signature on the file with its certificate chain.
        $report = Invoke-Tool -FilePath $signtool -Capture -AllowFailure -Arguments @('verify', '/pa', '/all', '/v', $file[0].FullName)
        if ($report -notmatch [regex]::Escape($MicrosoftSigner)) { $unsigned += $binary }
        if ($report -notmatch $publisher.thumbprint) { $withoutPublisher += $file[0].FullName }
    }

    if ($lost)     { Write-Note "[$Name] not returned at all: $($lost -join ', ')" }
    if ($unsigned) { Write-Note "[$Name] without Microsoft's signature: $($unsigned -join ', ')" }
    if ($lost -or $unsigned) { $script:Incomplete += $Name }
    if ($withoutPublisher) {
        Write-Note "[$Name] without the signature of $($publisher.subject): $(@($withoutPublisher | ForEach-Object { Split-Path -Leaf $_ }) -join ', ')"
    } elseif (-not ($lost -or $unsigned)) {
        Write-Ok "[$Name] all $($binaries.Count) binaries carry Microsoft's signature and the publisher's: $Directory"
    }
    return $withoutPublisher
}

function Complete-Download {
    param($State, [string[]]$Names, [string]$Directory)

    $script:Incomplete = @()
    $needSignature = @()
    foreach ($name in $Names) {
        $expanded = Save-SignedPackage $State $name $Directory
        if (-not $expanded) { continue }
        $entry = Get-Entry $State $name
        $missing = @(Test-SignedPackage $entry $name $expanded)
        if (-not $missing) { continue }
        if (-not $AppendSignature) { $needSignature += $name; continue }

        # /as adds a signature without disturbing Microsoft's. The catalog
        # stays valid: it records Authenticode hashes, which leave out a
        # file's signatures.
        $thumbprint = $CertThumbprint
        if (-not ($CertFile -or $CertThumbprint -or $CertSubject)) { $thumbprint = $entry.signer.thumbprint }
        $certificate = Resolve-Certificate -Mode attestation -CertFile $CertFile -CertThumbprint $thumbprint `
                                           -CertSubject $CertSubject -TimestampUrl $TimestampUrl
        Write-Step "Appending the publisher signature: $name"
        Add-Signature -Paths $missing -Certificate $certificate -Append -Verify
    }

    if ($script:Incomplete) {
        throw "The signed package of $($script:Incomplete -join ', ') is incomplete (see above). Do not ship it."
    }
    if ($needSignature) {
        Write-Note "Run again with -Download -AppendSignature to restore the publisher signature on: $($needSignature -join ', ')."
    }
}

Invoke-Main {
    $config = Read-LocalConfig
    foreach ($name in 'CredentialFile', 'ProductName', 'CertFile', 'CertThumbprint', 'CertSubject', 'TimestampUrl') {
        if (-not (Get-Variable -Name $name -ValueOnly) -and $config.ContainsKey($name)) {
            Set-Variable -Name $name -Value $config[$name]
        }
    }
    $script:HdcCredentialFile = $CredentialFile
    $script:BuildRoot = Join-Path $script:RepoRoot 'build'

    if ($Path) {
        $directory = Resolve-PackageRoot $Path
    } else {
        $directory = Join-Path (Join-Path $script:RepoRoot 'out') $Os
        if ($Configuration -eq 'Debug') { $directory += '-Debug' }
        if (-not (Test-Path -LiteralPath $directory)) { throw "`"$directory`" not found. Run build.ps1 -Sign attestation first." }
    }

    $statePath = Join-Path $directory 'submission.json'
    $state = Read-JsonFile $statePath
    if (-not $state) { $state = [pscustomobject]@{ packages = [pscustomobject]@{} } }
    $names = @($Package | ForEach-Object { $_ -split '[,;\s]+' } | Where-Object { $_ })

    # --- -Status and -Download -------------------------------------------------
    # These work from the submission record alone. It holds everything they
    # need, so rebuilding while Microsoft is still signing does no harm.
    if ($Status -or $Download) {
        $recorded = @($state.packages.PSObject.Properties | ForEach-Object { $_.Name } | Sort-Object)
        if (-not $names) { $names = $recorded }
        $unknown = @($names | Where-Object { $recorded -notcontains $_ })
        if ($unknown -or -not $names) {
            $what = 'any package'
            if ($unknown) { $what = $unknown -join ', ' }
            throw "Nothing has been submitted from `"$directory`" for $what."
        }
        if ($Status) {
            Write-Step "Submissions in $directory"
            Update-Status $state $names $statePath | Out-Null
        } else {
            Write-Step 'Downloading the signed packages'
            Complete-Download $state $names $directory
        }
        return
    }

    # --- which cabinets --------------------------------------------------------
    $manifests = @{}
    $built = Get-PackageManifests $directory
    foreach ($name in $built.Keys) {
        if (Get-JsonValue $built[$name] 'cab') { $manifests[$name] = $built[$name] }
    }
    if (-not $names) { $names = @($manifests.Keys | Sort-Object) }
    if (-not $names) { throw "No submission cabinets in `"$directory`". Run build.ps1 -Sign attestation, or resign.ps1, first." }
    foreach ($name in $names) {
        if (-not $manifests.ContainsKey($name)) {
            throw "No submission cabinet for `"$name`" in `"$directory`". It has: $(@($manifests.Keys | Sort-Object) -join ', ')."
        }
    }

    # --- submit ----------------------------------------------------------------
    $submitted = @()
    foreach ($name in $names) {
        $manifest = $manifests[$name]
        Write-Step "Package $name, version $($manifest.version), $($manifest.os)"
        $cab = Join-Path $directory $manifest.cab.file
        $hash = Test-Cabinet $manifest $cab -ReportOnly:$DryRun

        $signatures = Get-RequestedSignatures $manifest.package $manifest.os
        $productTitle = "$ProductName $($manifest.driver) $($manifest.version) $($manifest.package) $((Get-Date).ToString('yyyyMMdd-HHmmss'))".Trim()
        $body = New-HdcProductBody -Name $productTitle -Signatures $signatures -AnnouncementDate $AnnouncementDate
        Write-Info "requesting $($signatures.Count) signatures:"
        foreach ($signature in $signatures) { Write-Info "  $signature" }

        if ($DryRun) {
            Write-Info 'Product that would be created:'
            ($body | ConvertTo-Json -Depth 5) -split "`r?`n" | ForEach-Object { Write-Info "  $_" }
            continue
        }

        $entry = Get-Entry $state $name
        if ($entry -and $entry.cabSha256 -eq $hash -and -not $Force) {
            Write-Note "This cabinet was already submitted (product $($entry.productId)). Use -Force to submit it again."
            $submitted += $name
            continue
        }

        $ids = Submit-HdcPackage -CabPath $cab -Name $productTitle -ProductBody $body
        Set-Entry $state $name ([pscustomobject]@{
            cabSha256    = $hash
            version      = $manifest.version
            files        = @($manifest.files)
            signer       = $manifest.cab.signer
            productId    = $ids.ProductId
            productName  = $productTitle
            submissionId = $ids.SubmissionId
            submittedUtc = (Get-Date).ToUniversalTime().ToString('o')
            commitStatus = 'commitPending'
            step         = ''
            state        = ''
            result       = ''
        })
        Write-JsonFile $statePath $state
        Write-Info "https://partner.microsoft.com/dashboard/hardware/driver/$($ids.ProductId)"
        $submitted += $name
    }
    if ($DryRun) { Write-Step 'Dry run: nothing was submitted'; return }

    if ($NoWait) {
        Write-Step 'Submitted'
        Write-Info 'Follow up with: .\submit.ps1 -Status, then .\submit.ps1 -Download'
        return
    }

    # --- wait ------------------------------------------------------------------
    Write-Step "Waiting for Microsoft (every $PollIntervalSeconds s, up to $TimeoutMinutes min)"
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while (-not (Update-Status $state $submitted $statePath)) {
        if ((Get-Date) -ge $deadline) {
            throw "Still in progress after $TimeoutMinutes minutes. Check later with -Status, then collect with -Download."
        }
        Start-Sleep -Seconds $PollIntervalSeconds
    }
    $failed = @($submitted | Where-Object { (Get-Entry $state $_).result -eq 'failed' })
    if ($failed) {
        $links = @($failed | ForEach-Object { "https://partner.microsoft.com/dashboard/hardware/driver/$((Get-Entry $state $_).productId)" })
        throw "Attestation failed for $($failed -join ', '). See $($links -join ' and ')."
    }

    Write-Step 'Downloading the signed packages'
    Complete-Download $state $submitted $directory
}
