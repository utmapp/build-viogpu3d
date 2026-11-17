# Machine-specific defaults for build.ps1 and submit.ps1.
#
# Copy this file to config.psd1 (which git ignores) and keep what applies. Every
# setting is the default for the parameter of the same name, so the command
# line still wins. Relative paths are relative to this directory.
#
# Secrets do not belong here. The .pfx password is read from the
# VIOGPU_SIGN_PASSWORD environment variable and the Partner Center credentials
# from HDC_TENANT_ID / HDC_CLIENT_ID / HDC_CLIENT_SECRET (or from the file
# CredentialFile points at, which should live outside any repository).
@{
    # Source checkouts. Without these, build.ps1 looks for ..\viogpu-wddm and
    # ..\mesa next to this repository.
    # KmdSource = '..\viogpu-wddm'
    # UmdSource = '..\mesa'

    # The certificate for -Sign attestation, named one of three ways. Plain
    # test signing ignores these and uses the driver repository's test
    # certificate unless a -Cert* parameter is given on the command line.
    # CertThumbprint = '0123456789abcdef0123456789abcdef01234567'
    # CertSubject    = 'Example Corporation'
    # CertFile       = 'C:\path\to\certificate.pfx'
    # TimestampUrl   = 'http://timestamp.digicert.com'

    # resign.ps1: the name to put in the INF in place of "Red Hat, Inc.", as
    # the driver's provider and manufacturer.
    # Provider = 'Example Corporation'

    # submit.ps1: a JSON file with tenantId, clientId and clientSecret, and
    # text to put in front of the product names it creates in Partner Center
    # ("<driver> <version> <package> <timestamp>").
    # CredentialFile = 'C:\path\outside\the\repository\hdc-credentials.json'
    # ProductName    = 'Example'
}
