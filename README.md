# build-viogpu3d

Build scripts for **viogpu3d**, UTM's 3D-accelerated VirtIO GPU driver for
Windows guests. The driver comes from two repositories, and this one builds
both and puts them together:

| Repository | Provides |
| --- | --- |
| [utmapp/viogpu-wddm](https://github.com/utmapp/viogpu-wddm) | `viogpu3d.sys`, the WDDM kernel driver, and its two helpers `vgpusrv.exe` and `viogpuap.exe`; also `viogpudo.sys`, the display-only driver for the same device |
| [utmapp/mesa](https://github.com/utmapp/mesa) | `neptune_umd.dll`, the **Neptune** Direct3D user-mode driver, and `vulkan_virtio.dll`, the **Venus** Vulkan ICD |

The result is a driver package you can install on a test-signing guest, or an
EV-signed cabinet that `submit.ps1` sends to Microsoft for attestation signing.
The two can happen in different places: `resign.ps1` puts the EV signature on
a package that was built elsewhere, such as by the GitHub workflow. The
display-only driver, `viogpudo`, can be packaged, signed and submitted the same
way.

## Quick start

Check the three repositories out next to each other:

```
git clone https://github.com/utmapp/build-viogpu3d
git clone https://github.com/utmapp/viogpu-wddm
git clone https://github.com/utmapp/mesa
```

Then, from any command prompt:

```
cd build-viogpu3d
build
```

That builds everything for the machine's own architecture and leaves a
test-signed package in `out\Win10\viogpu3d-<arch>`. The first run takes a few
minutes; later runs are incremental.

`build.cmd`, `resign.cmd` and `submit.cmd` only start the `.ps1` of the same
name, so from PowerShell you can run those directly. `build -?`, `resign -?`
and `submit -?` print the full parameter help.

### Prerequisites

- **Visual Studio 2022** with the *Desktop development with C++* workload and
  the MSVC build tools for each architecture you build: x64/x86, ARM64 and, for
  `arm64x`, ARM64EC.
- The **Windows Driver Kit** matching that Visual Studio, for the kernel driver.
- **Python** 3.9 or newer and **Git**, on `PATH`.

Meson and Ninja are installed into a private virtual environment under
`build\tools` on the first run. The host can be x64 or ARM64; architectures
other than its own are cross-compiled.

### Sources somewhere else

The two checkouts are found, in this order, from the `-KmdSource` and
`-UmdSource` parameters, from `config.psd1`, and as `..\viogpu-wddm` and
`..\mesa`. To set them once, copy `config.example.psd1` to `config.psd1`, which
git ignores:

```powershell
@{
    KmdSource = 'D:\src\viogpu-wddm'
    UmdSource = 'D:\src\mesa'
}
```

## Building

```
build [-Target <what>] [-Arch <which>] [-Os Win10|Win11] [-Configuration Release|Debug]
      [-Clean] [-Sign test|attestation|none] [-Cab] [-Cert...]
```

### What: `-Target`

| Target | Builds |
| --- | --- |
| `all` (default) | `neptune` + `venus` + `kmd` |
| `umd` | `neptune` + `venus` |
| `neptune` | the Direct3D user-mode driver |
| `venus` | the Vulkan ICD |
| `kmd` | the viogpu3d kernel driver, and the package around it |
| `viogpudo` | the display-only driver and its package; not part of `all` |

Targets combine: `-Target neptune,kmd` rebuilds Neptune and repackages. The
viogpu3d package is assembled whenever `kmd` is among the targets, from the
most recent build of each user-mode driver, so `-Target kmd` alone repackages
without touching Mesa. Without `kmd`, the user-mode files are staged in
`out\umd` and no package is made.

`viogpudo` needs nothing from Mesa. Building it is the driver repository's
`build.bat viogpudo` and nothing more; what this adds is the package: the
driver's files alone in a clean directory (the driver repository puts both
drivers in one directory that it never empties), a fresh catalog, the
signature you asked for, and the manifest that `resign` and `submit` work
from.

### Which: `-Arch`

| Arch | Result |
| --- | --- |
| `x64` | package: x64 kernel driver, x64 user-mode drivers |
| `arm64` | package: ARM64 kernel driver, native ARM64 user-mode drivers only |
| `arm64x` | package: ARM64 kernel driver, ARM64X user-mode drivers, which also serve x64 applications under emulation |
| `x86` | user-mode only: the 32-bit Direct3D driver |
| `arm64ec` | user-mode only: the emulation view on its own |
| `all` | `x64`, `arm64x` and `x86`: what a release ships |

The default is the host's architecture. Several can be given at once.

`x86` and `arm64ec` are not packages of their own. There is no 32-bit kernel
driver: the current WDK has kernel libraries for x64 and ARM64 only. Listing
`x86` next to a package architecture adds the 32-bit driver to that package for
WOW64 applications, so `-Arch arm64x,x86` is the complete ARM64 package and
`-Arch arm64` is the quick one for native-only testing.

`viogpudo` has no user-mode half, so it comes as `x64` and `arm64` only:
`arm64x` gives the same package as `arm64`, and `x86` and `arm64ec` give none.

### The rest

- `-Os Win10` (default) or `Win11` selects the driver project configuration.
- `-Configuration Debug` selects the checked kernel driver. The user-mode
  drivers are always optimised builds with symbols, and so is the kernel driver
  by default: development builds and signed releases are the same binaries.
- `-Clean` rebuilds the selected targets from scratch.

### Recipes

| To | Run |
| --- | --- |
| build everything, incrementally | `build` |
| rebuild everything from scratch | `build -Clean` |
| build just the user-mode drivers | `build -Target umd` |
| build just Neptune, or just Venus | `build -Target neptune`, `build -Target venus` |
| build just the kernel driver and repackage | `build -Target kmd` |
| build the full ARM64 package | `build -Arch arm64x,x86` |
| build the checked kernel driver for Windows 11 | `build -Os Win11 -Configuration Debug` |
| build what a viogpu3d release contains | `build -Arch all` |
| build just the display-only driver | `build -Target viogpudo` |
| build both drivers for every architecture | `build -Target all,viogpudo -Arch all` |

## Output

Everything generated lands in two ignored directories.

```
out\
  Win10\                     one directory per -Os (Win10-Debug for -Configuration Debug)
    viogpu3d-x64\            a driver package: the .inf, .cat, .sys and every file it installs
    viogpu3d-arm64x\
    viogpudo-x64\            packages are named <driver>-<package>
    viogpu3d-x64.json        what that package is: version, revisions, files, signer
    viogpu3d-x64.cab         submission cabinet (-Sign attestation, -Cab, or resign)
    submission.json          submit.ps1's record of what was sent to Partner Center
    signed\viogpu3d-x64\     what Microsoft sent back
  umd\<package>\             the user-mode files of a package, as handed to the kernel driver build
  symbols\<arch>\            PDBs of the user-mode drivers (the kernel PDBs are in the package)
build\
  umd\<arch>\                Meson build directories; arm64x holds the stitched ARM64X DLLs
  tools\                     the Python environment with Meson and Ninja
```

To start over completely, delete `build` and `out`.

## Signing

`-Sign` decides what happens to the finished package.

| Mode | Does |
| --- | --- |
| `test` (default) | signs the `.sys` and the catalog for a guest in test-signing mode |
| `attestation` | signs every binary with your EV certificate, builds the package's `.cab` and signs that too |
| `none` | leaves the package unsigned |

Test signing uses the test certificate in the driver repository,
`build\VirtIOTestCert.pfx`, unless you name another one. The certificate is
named the same way in every mode:

| Parameter | Certificate |
| --- | --- |
| `-CertFile <pfx>` | a `.pfx` file; its password, if it has one, is read from the `VIOGPU_SIGN_PASSWORD` environment variable |
| `-CertThumbprint <sha1>` | a certificate in the certificate store, by thumbprint |
| `-CertSubject <name>` | a certificate in the certificate store, by subject name |

`-TimestampUrl` names an RFC 3161 timestamp server. Attestation signatures are
always timestamped (DigiCert's server by default); test signatures only when
you ask.

The certificate for attestation can live in `config.psd1`, so a release is
`build -Arch all -Sign attestation` without more parameters. Those settings do
not affect `-Sign test`.

### Installing a test-signed package

On the guest, once: enable test signing and trust the certificate.

```
bcdedit /set testsigning on
certutil -addstore Root VirtIOTestCert.cer
certutil -addstore TrustedPublisher VirtIOTestCert.cer
```

Reboot, copy the package directory over, and install it:

```
pnputil /add-driver viogpu3d.inf /install
```

## Releasing

A release is built, signed with your EV certificate, and submitted. On a
machine that has the certificate, the first two are one command:

```
build -Target all,viogpudo -Arch all -Sign attestation -CertThumbprint <thumbprint>
submit
```

When the build comes from somewhere that does not have it, sign it afterwards:

```
resign -Path <downloaded artifact> -CertThumbprint <thumbprint>
submit -Path <the directory resign names when it finishes>
```

**1. Build.** `-Sign attestation` refuses to run from a checkout with
uncommitted changes, or with user-mode drivers built at different commits,
because the package would name a revision that does not describe it.
`-AllowDirty` overrides that. `-Cab` with any other `-Sign` builds the same
cabinet as a rehearsal, without the EV certificate.

**Or re-sign.** `resign.ps1` takes packages that `build.ps1` already produced,
test-signed or unsigned, and leaves them as `-Sign attestation` would have. It
needs only `signtool` from the Windows SDK; nothing is compiled. `-Path` is
the workflow's artifact, as the downloaded `.zip` or extracted, or any copy of
an `out\<Os>` directory; without it, the local `out\<Os>` is signed. For each
package it

- checks the package against its manifest and its INF, and signs a scratch
  file to prove the certificate works and is trusted, before changing anything;
- removes every signature the binaries carry, so no test signature survives;
- signs every binary with the certificate (a test-signed catalog is signed
  too, which replaces its signature: Microsoft discards the submitted catalog
  either way, and `signtool` cannot simply take a signature off one);
- builds and signs the package's `.cab` next to it and records the new signer
  in the manifest.

The packages are changed in place, and running it again starts over from the
same files. Like the build, it refuses packages that were not built from clean
commits unless you pass `-AllowDirty`.

`resign -Provider "<name>"` also puts your name on the driver. The driver
repository's INFs give `Red Hat, Inc.` as the provider and manufacturer; this
replaces that string in each INF. It is what Device Manager shows as *Driver
Provider* and *Manufacturer* and what `pnputil` lists as the provider. The
*Publisher* that Windows asks about when a driver is installed is not in the
INF: that is the certificate that signed the catalog. Because the INF changes,
the catalog is rebuilt, and that takes `inf2cat` from the Windows Driver Kit.
Nothing else is renamed: the
device descriptions (`Red Hat VirtIO GPU 3D controller`) and the version
information inside the binaries stay as they were built. `Provider` can be set
once in `config.psd1`.

**2. Submit.** `submit.ps1` creates one Partner Center product per cabinet,
uploads it, commits the submission and waits for Microsoft to sign it. Each
product requests the signatures that match its package:

| Package | Signatures requested |
| --- | --- |
| `viogpu3d-x64`, `viogpudo-x64` | Windows 10 1709 through Windows 11 26H1, x64 |
| `viogpu3d-arm64x`, `viogpu3d-arm64`, `viogpudo-arm64` | Windows 10 1709 through Windows 11 26H1, ARM64 |

That is every client release the INF installs on, and it is the same for
`-Os Win10` and `-Os Win11`, whose INFs target the same systems. The list is
the table at the top of `lib\hdc.ps1`; add a line there when a new Windows
release appears. `submit -DryRun` checks the cabinets and prints exactly what
would be requested without contacting Partner Center.

**3. Collect.** The signed packages are downloaded to `signed\<name>` next to
the cabinets and checked: every submitted binary must be back, with
Microsoft's signature and still with yours. Microsoft has been seen to add its
signature next to the publisher's, but does not promise to; if yours is gone,
`submit -Download -AppendSignature` adds it again without disturbing
Microsoft's.

`resign` and `submit` act on every package they find; `-Package
viogpudo-x64,viogpudo-arm64` narrows that.

Attestation can take from minutes to hours. `submit -NoWait` returns after the
upload; `submit -Status` and `submit -Download` pick it up later, from the
`submission.json` next to the cabinets. That record is all they need, so
building again in the meantime is fine. A cabinet that was already submitted
is not submitted twice unless you pass `-Force`. Give them the same `-Path`
(or `-Os`) as the submission.

### Partner Center credentials

`submit.ps1` signs in as an Entra ID application associated with the Partner
Center account, with the *Manager* role and *Hardware > Driver Submitter*. Give
it the application's credentials in the environment:

```
HDC_TENANT_ID   HDC_CLIENT_ID   HDC_CLIENT_SECRET
```

or in a JSON file named by `-CredentialFile` (or `CredentialFile` in
`config.psd1`), kept outside any repository:

```json
{ "tenantId": "...", "clientId": "...", "clientSecret": "..." }
```

## Which commit is this?

Every build stamps the commits it was made from, as ten characters: the start
of the commit hash, or nine and a trailing `+` when the checkout had
uncommitted changes.

- **The INF** names the driver and Mesa commits in its header. On a guest, the
  installed copy is `C:\Windows\INF\oem<N>.inf`:

  ```
  ; Built from:
  ;   viogpu-wddm     9ee33e8d9b
  ;   mesa            3eac9d327e
  ```

- **`viogpu3d.sys` and `neptune_umd.dll`** carry their own commit in the
  product version, visible in Explorer's *Details* tab or with
  `(Get-Item neptune_umd.dll).VersionInfo.ProductVersion`:
  `100.6.101.58000 (git-3eac9d327e)`. A binary keeps its stamp when it is
  copied into a guest on its own. The file version stays the plain number.
- **`vulkan_virtio.dll`** reports its commit the way Mesa always does, in the
  Vulkan driver info string (`vulkaninfo`: `Mesa ... (git-3eac9d327e)`).
- **`out\<Os>\<name>.json`** records the same for each package, along with the
  commit of these build scripts. For `viogpudo`, whose INF and driver carry no
  stamp, this is the only record.

The stamp describes what was actually built: the user-mode revision is recorded
when Mesa is compiled, so repackaging later with `-Target kmd` still names the
commit the DLLs came from.

## How it fits together

**The version** is defined once, in the driver repository
(`build\Driver.RHEL.props`). Windows requires the Direct3D user-mode driver's
file version to equal the INF's `DriverVer`, so the build reads the number from
the driver project and stamps it into the Mesa build. To bump it, change it
there.

**Mesa** is configured once per architecture, always the same way, with only
Neptune and Venus enabled (`lib\umd.ps1` has the options). `-Target neptune`
and `-Target venus` choose ninja targets within that one configuration.
Neither driver needs LLVM, so none is built.

**ARM64X.** Windows on ARM runs native ARM64 processes and, under emulation,
x64 ones. No single DLL serves both, so `arm64x` builds each driver twice, for
`arm64` and for `arm64ec`, and ships the pair behind an ARM64X front DLL that
the loader resolves per process: `neptune_umd.dll` forwards to
`neptune_umd_arm64.dll` and `neptune_umd_ec.dll`, and likewise
`vulkan_virtio.dll`. The tools that build the front DLLs are in the Mesa fork.
Meson has no ARM64EC machine, which is what `meson\arm64ec-shim.c` works
around.

**WOW64.** 32-bit applications need a 32-bit driver, and ARM64X has no 32-bit
view. The x86 Neptune build is packaged as `neptune_umd_x86.dll`, under its own
name because it shares the DriverStore directory with the 64-bit one. No 32-bit
Vulkan ICD is registered, so x86 builds Neptune only.

**The package.** The user-mode files of a viogpu3d package are staged, under
their final names, in one flat directory (`out\umd\<package>`). The kernel
driver build is pointed at it with `VIOGPU_UMD_DIR`, packages what it finds
there and writes the matching INF. The final package, of either driver, is
then assembled in an empty directory from an explicit file list, catalogued
and signed, so nothing stale can ride along.

```
build.ps1                  build, package and sign
resign.ps1                 put the EV signature on packages built elsewhere
submit.ps1                 Partner Center (each has a .cmd that starts it)
lib\common.ps1             processes, Visual Studio environments, configuration, revisions
lib\umd.ps1                the Mesa build, ARM64X, staging
lib\kmd.ps1                the kernel driver build
lib\package.ps1            package assembly, catalog, signing, cabinets
lib\hdc.ps1                the Partner Center API and the requested-signature table
meson\                     cross files, pinned Python requirements, the ARM64EC shim
```

## Continuous integration

`.github\workflows\build.yml` checks out the three repositories and runs the
same `build.ps1` for both drivers, test-signed, when started by hand. Its
artifact holds the packages, their manifests and the symbols. The packages install as they are on
a test-signing guest; to release them, download the artifact and hand it to
`resign` and `submit` as above.
