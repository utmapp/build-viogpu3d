# The Microsoft Hardware Dashboard (Partner Center) API, as much of it as an
# attestation submission needs.
#
#   https://learn.microsoft.com/windows-hardware/drivers/dashboard/dashboard-api
#   https://learn.microsoft.com/windows-hardware/drivers/dashboard/manage-product-submissions
#
#   1. token       POST login.microsoftonline.com/<tenant>/oauth2/token
#   2. product     POST /v2.0/my/hardware/products
#   3. submission  POST .../products/{id}/submissions
#   4. upload      PUT  <the Azure blob SAS URI the submission returned>
#   5. commit      POST .../submissions/{id}/commit
#   6. poll        GET  .../submissions/{id}
#   7. download    the "signedPackage" link of the finished submission

$script:HdcApi      = 'https://manage.devcenter.microsoft.com/v2.0/my/hardware/products'
$script:HdcResource = 'https://manage.devcenter.microsoft.com'
$script:HdcBlock    = 4MB   # Azure block size, and the limit for a single-request upload

# Both login.microsoftonline.com and Azure storage require TLS 1.2, which
# Windows PowerShell 5.1 does not always negotiate by default.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------------------
#  Requested signatures
#
#  The operating systems Microsoft signs the package for: the dashboard's
#  "requested signatures". Each is WINDOWS_v100_<arch>_<release>_FULL, from the
#  "List of Operating System Codes" in
#  https://learn.microsoft.com/windows-hardware/drivers/dashboard/get-product-data
#
#  Every package asks for every client release from 1709, the first with the
#  DriverStore install (dirid 13) the viogpu3d INF depends on, and for no
#  server releases. That holds for a Win11 build too: its INF carries the same
#  10.0...16299 decoration as a Win10 one and installs on the same systems. To
#  sign a Win11 build for Windows 11 only, filter on $Os in
#  Get-RequestedSignatures. viogpudo gets the same list, although its Win10 INF
#  would install on older releases as well.
#
#  The published table is incomplete: it lacks ARM64 for RS5 and x64 for 26H1,
#  yet the API accepts both. Asking for a signature Microsoft no longer issues
#  fails product creation with HTTP 422; trim the list here when that happens,
#  and add a line when a new Windows release appears.
# ---------------------------------------------------------------------------
$script:HdcReleases = @(
    @{ Code = 'RS3';  Name = 'Windows 10 1709' }
    @{ Code = 'RS4';  Name = 'Windows 10 1803' }
    @{ Code = 'RS5';  Name = 'Windows 10 1809' }
    @{ Code = '19H1'; Name = 'Windows 10 1903' }
    @{ Code = 'VB';   Name = 'Windows 10 2004' }
    @{ Code = 'CO';   Name = 'Windows 11 21H2' }
    @{ Code = 'NI';   Name = 'Windows 11 22H2' }
    @{ Code = 'GE';   Name = 'Windows 11 24H2' }
    @{ Code = '25H2'; Name = 'Windows 11 25H2' }
    @{ Code = '26H1'; Name = 'Windows 11 26H1' }
)

function Get-RequestedSignatures {
    param([string]$Package, [string]$Os)
    # $Package is the architecture half of a package name. The arm64 and
    # arm64x packages both hold an ARM64 kernel driver.
    $arch = 'ARM64'
    if ($Package -eq 'x64') { $arch = 'X64' }
    return @($script:HdcReleases | ForEach-Object { "WINDOWS_v100_${arch}_$($_.Code)_FULL" })
}

# ---------------------------------------------------------------------------
#  Credentials and token
#
#  An Entra ID application associated with the Partner Center account, holding
#  the Manager role and Hardware > Driver Submitter. The secret is only ever
#  sent to login.microsoftonline.com.
# ---------------------------------------------------------------------------
$script:HdcCredentialFile = $null
$script:HdcCredential = $null
$script:HdcToken = $null
$script:HdcTokenExpiry = [datetime]::MinValue

function Get-HdcCredential {
    if ($script:HdcCredential) { return $script:HdcCredential }

    if ($env:HDC_TENANT_ID -and $env:HDC_CLIENT_ID -and $env:HDC_CLIENT_SECRET) {
        Write-Info 'Credentials from HDC_TENANT_ID / HDC_CLIENT_ID / HDC_CLIENT_SECRET'
        $script:HdcCredential = [pscustomobject]@{
            tenantId = $env:HDC_TENANT_ID; clientId = $env:HDC_CLIENT_ID; clientSecret = $env:HDC_CLIENT_SECRET
        }
        return $script:HdcCredential
    }

    $path = $script:HdcCredentialFile
    if (-not $path -or -not (Test-Path -LiteralPath $path)) {
        throw @'
No Partner Center credentials. Set HDC_TENANT_ID, HDC_CLIENT_ID and HDC_CLIENT_SECRET,
or pass -CredentialFile (or set CredentialFile in config.psd1) naming a JSON file:
  { "tenantId": "...", "clientId": "...", "clientSecret": "..." }
'@
    }
    $credential = Read-JsonFile $path
    foreach ($field in 'tenantId', 'clientId', 'clientSecret') {
        if (-not (Get-JsonValue $credential $field)) { throw "`"$path`" has no `"$field`"." }
    }
    Write-Info "Credentials from $path"
    $script:HdcCredential = $credential
    return $credential
}

# Client-credentials grant, cached until shortly before it expires so that a
# long poll outlives the 60 minute token.
function Get-HdcToken {
    if ($script:HdcToken -and (Get-Date) -lt $script:HdcTokenExpiry) { return $script:HdcToken }
    $credential = Get-HdcCredential
    $body = @{
        grant_type    = 'client_credentials'
        client_id     = $credential.clientId
        client_secret = $credential.clientSecret
        resource      = $script:HdcResource
    }
    try {
        $response = Invoke-RestMethod -Method Post -UseBasicParsing -Body $body `
            -Uri "https://login.microsoftonline.com/$($credential.tenantId)/oauth2/token" `
            -ContentType 'application/x-www-form-urlencoded'
    } catch {
        throw "Could not get an Entra ID token: $(Get-WebErrorDetail $_)"
    }
    $lifetime = 3600
    if ($response.expires_in) { $lifetime = [int]$response.expires_in }
    $script:HdcToken = $response.access_token
    $script:HdcTokenExpiry = (Get-Date).AddSeconds($lifetime - 300)
    return $script:HdcToken
}

# ---------------------------------------------------------------------------
#  HTTP
# ---------------------------------------------------------------------------

# Invoke-WebRequest discards the body of an error response, which is where the
# API puts its error code and message. Recover it.
function Get-WebErrorDetail {
    param($ErrorRecord)
    $detail = $ErrorRecord.Exception.Message
    $response = $ErrorRecord.Exception.Response
    if (-not $response) { return $detail }
    $code = ''
    try { $code = [int]$response.StatusCode } catch { }
    try {
        $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
        $text = $reader.ReadToEnd()
        $reader.Close()
        if ($text) { $detail = "HTTP $code - $text" } elseif ($code) { $detail = "HTTP $code - $detail" }
    } catch { }
    return $detail
}

function Get-WebErrorStatus {
    param($ErrorRecord)
    $response = $ErrorRecord.Exception.Response
    if (-not $response) { return 0 }
    try { return [int]$response.StatusCode } catch { return 0 }
}

# One Hardware API call. Throttling (429) and server errors are retried: giving
# up halfway through a submission strands a product without a committed
# submission.
function Invoke-HdcApi {
    param(
        [ValidateSet('GET', 'POST')] [string]$Method,
        [string]$Uri,
        $Body,
        [switch]$EmptyBody
    )
    for ($attempt = 1; ; $attempt++) {
        $request = @{
            Uri             = $Uri
            Method          = $Method
            Headers         = @{ Authorization = "Bearer $(Get-HdcToken)"; Accept = 'application/json' }
            ContentType     = 'application/json'
            UseBasicParsing = $true
        }
        if ($null -ne $Body) {
            $request.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 10))
        } elseif ($EmptyBody) {
            $request.Body = [byte[]]@()
        }
        try {
            $response = Invoke-WebRequest @request
            if ($response.Content) { return ($response.Content | ConvertFrom-Json) }
            return $null
        } catch {
            $status = Get-WebErrorStatus $_
            if (($status -ne 429 -and $status -lt 500) -or $attempt -ge 5) {
                throw "$Method $Uri failed: $(Get-WebErrorDetail $_)"
            }
            $wait = [Math]::Min(60, [Math]::Pow(2, $attempt) * 5)
            Write-Note "HTTP $status from the dashboard; retrying in $wait s ($attempt of 5)"
            Start-Sleep -Seconds $wait
        }
    }
}

# ---------------------------------------------------------------------------
#  Upload to the submission's Azure blob SAS URI
#
#  Up to one block the file goes in a single request; anything larger is
#  staged as blocks and committed with a block list.
# ---------------------------------------------------------------------------
function Send-BlobRequest {
    param([string]$Uri, [byte[]]$Content, [hashtable]$Headers = @{})
    $request = [Net.HttpWebRequest]::Create($Uri)
    $request.Method = 'PUT'
    $request.ContentType = 'application/octet-stream'
    $request.ContentLength = $Content.Length
    $request.Timeout = 300000
    $request.ReadWriteTimeout = 300000
    $request.AllowWriteStreamBuffering = $false
    $request.Headers.Add('x-ms-version', '2021-08-06')
    foreach ($name in $Headers.Keys) { $request.Headers.Add($name, $Headers[$name]) }
    $stream = $request.GetRequestStream()
    try {
        if ($Content.Length -gt 0) { $stream.Write($Content, 0, $Content.Length) }
    } finally {
        $stream.Dispose()
    }
    $request.GetResponse().Close()
}

function Send-HdcPackage {
    param([string]$Path, [string]$SasUri)

    $file = Get-Item -LiteralPath $Path
    Write-Info ('Uploading {0} ({1:N1} MB)' -f $file.Name, ($file.Length / 1MB))
    if ($file.Length -le $script:HdcBlock) {
        Send-BlobRequest -Uri $SasUri -Content ([IO.File]::ReadAllBytes($file.FullName)) -Headers @{ 'x-ms-blob-type' = 'BlockBlob' }
        return
    }

    # The SAS URI already has a query string, so parameters are appended with
    # "&". Block IDs must be base64 strings of equal length.
    $blockIds = @()
    $stream = [IO.File]::OpenRead($file.FullName)
    try {
        $buffer = New-Object byte[] $script:HdcBlock
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $blockId = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($blockIds.Count.ToString('D6')))
            $chunk = $buffer
            if ($read -lt $buffer.Length) {
                $chunk = New-Object byte[] $read
                [Array]::Copy($buffer, $chunk, $read)
            }
            Send-BlobRequest -Uri "$SasUri&comp=block&blockid=$([Uri]::EscapeDataString($blockId))" -Content $chunk
            $blockIds += $blockId
        }
    } finally {
        $stream.Dispose()
    }
    $list = '<?xml version="1.0" encoding="utf-8"?><BlockList>' +
            (($blockIds | ForEach-Object { "<Latest>$_</Latest>" }) -join '') + '</BlockList>'
    Send-BlobRequest -Uri "$SasUri&comp=blocklist" -Content ([Text.Encoding]::UTF8.GetBytes($list))
}

# ---------------------------------------------------------------------------
#  Products and submissions
# ---------------------------------------------------------------------------

# The body of the "create product" call. A product carries one set of requested
# signatures and accepts exactly one initial submission, so every package of
# every release gets a product of its own.
function New-HdcProductBody {
    param([string]$Name, [string[]]$Signatures, [datetime]$AnnouncementDate)
    return [ordered]@{
        productName          = $Name
        testHarness          = 'Attestation'
        announcementDate     = $AnnouncementDate.ToString('yyyy-MM-dd\THH:mm:ss')
        deviceMetadataIds    = @()
        deviceType           = 'internalExternal'
        isTestSign           = $false
        isFlightSign         = $false
        marketingNames       = @()
        # Product types select HLK tests; attestation runs none.
        selectedProductTypes = @{}
        requestedSignatures  = $Signatures
        additionalAttributes = @{}
    }
}

function Get-HdcSubmission {
    param([string]$ProductId, [string]$SubmissionId)
    return (Invoke-HdcApi -Method GET -Uri "$($script:HdcApi)/$ProductId/submissions/$SubmissionId")
}

function Get-HdcDownload {
    param($Submission, [string]$Type)
    $downloads = Get-JsonValue $Submission 'downloads'
    $items = Get-JsonValue $downloads 'items'
    if (-not $items) { return $null }
    $item = @($items | Where-Object { $_.type -eq $Type })
    if ($item) { return $item[0].url }
    return $null
}

# Creates the product and its submission, uploads the cabinet and commits.
# Returns the product and submission IDs as strings: they are 64-bit numbers
# and must survive a JSON round trip intact.
function Submit-HdcPackage {
    param([string]$CabPath, [string]$Name, $ProductBody)

    Write-Info "Creating product `"$Name`""
    $product = Invoke-HdcApi -Method POST -Uri $script:HdcApi -Body $ProductBody
    $productId = $product.id.ToString()

    $submission = Invoke-HdcApi -Method POST -Uri "$($script:HdcApi)/$productId/submissions" `
                                -Body @{ name = "$Name initial"; type = 'initial' }
    $submissionId = $submission.id.ToString()
    Write-Info "product $productId, submission $submissionId"

    $sas = Get-HdcDownload $submission 'initialPackage'
    if (-not $sas) { throw "Submission $submissionId has no upload link." }
    Send-HdcPackage -Path $CabPath -SasUri $sas

    Invoke-HdcApi -Method POST -Uri "$($script:HdcApi)/$productId/submissions/$submissionId/commit" -EmptyBody | Out-Null
    Write-Ok 'Uploaded and committed'
    return [pscustomobject]@{ ProductId = $productId; SubmissionId = $submissionId }
}
