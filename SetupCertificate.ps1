# INPUT
#     $runPath
#     $myPath
#     $env:ContactEMailForLetsEncrypt
#     $env:CerificatePfxPassword
#     $env:CerificatePfxUrl
#
# OUTPUT
#     $certificateCerFile (if self signed)
#     $certificateThumbprint
#     $dnsIdentity

$ContactEMailForLetsEncrypt = "$env:ContactEMailForLetsEncrypt"
$CertificatePfxPassword = "$env:CertificatePfxPassword"
$certificatePfxUrl = "$env:certificatePfxUrl"
$certificatePfxFile = ""

if ("$certificatePfxUrl" -ne "" -and "$CertificatePfxPassword" -ne "") {

    $certificatePfxFile = Join-Path $myPath "certificate.pfx"
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    (New-Object System.Net.WebClient).DownloadFile($certificatePfxUrl, $certificatePfxFile)
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($certificatePfxFile, $certificatePfxPassword)
    $certificateThumbprint = $cert.Thumbprint
    Write-Host "Certificate File Thumbprint $certificateThumbprint"
    if (!(Get-Item Cert:\LocalMachine\my\$certificateThumbprint -ErrorAction SilentlyContinue)) {
        Write-Host "Importing Certificate to LocalMachine\my"
        Import-PfxCertificate -FilePath $certificatePfxFile -CertStoreLocation cert:\localMachine\my -Password (ConvertTo-SecureString -String $certificatePfxPassword -AsPlainText -Force) | Out-Null
    }
    $dnsidentity = $cert.GetNameInfo("SimpleName",$false)
    if ($dnsidentity.StartsWith("*")) {
        $dnsidentity = $dnsidentity.Substring($dnsidentity.IndexOf(".")+1)
    }
    Write-Host "DNS identity $dnsidentity"

} elseif ("$ContactEMailForLetsEncrypt" -ne "") {

    try {
        Write-Host "Using LetsEncrypt to create SSL Certificate"

        Write-Host "Using default website for LetsEncrypt"
        
        Write-Host "Installing NuGet PackageProvider"
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
        
        Write-Host "Installing ACME-PS PowerShell Module"
        Install-Module -Name ACME-PS -RequiredVersion "1.5.0" -Force

        Write-Host "Importing ACME-PS module"
        Import-Module ACME-PS

        $certificatePfxFile = Join-Path $myPath "certificate.pfx"
        $stateDir = Join-Path $myPath 'acmeState'

        Write-Host "Initializing ACME State"
        New-ACMEState -Path $stateDir

        Write-Host "Registring Contact EMail address and accept Terms Of Service"
        Get-ACMEServiceDirectory -State $stateDir -ServiceName "LetsEncrypt" -PassThru | Out-Null

        Write-Host "New Nonce"
        New-ACMENonce -State $stateDir | Out-Null

        Write-Host "New AccountKey"
        New-ACMEAccountKey -state $stateDir -PassThru | Out-Null

        Write-Host "New Account"
        New-ACMEAccount -state $stateDir -EmailAddresses $ContactEMailForLetsEncrypt -AcceptTOS | Out-Null

        Write-Host "Creating new dns Identifier"
        $identifier = New-ACMEIdentifier $publicDnsName
    
        Write-Host "Creating ACME Order"
        $order = New-ACMEOrder -state $stateDir -Identifiers $identifier
    
        Write-Host "Getting ACME Authorization"
        $authZ = Get-ACMEAuthorization -State $stateDir -Order $order
    
        Write-Host "Getting ACME Challenge"
        $challenge = Get-ACMEChallenge -state $stateDir $authZ "http-01"
    
        # Create the file requested by the challenge
        $fileName = "C:\inetpub\wwwroot$($challenge.Data.RelativeUrl)"
        $challengePath = [System.IO.Path]::GetDirectoryName($filename);
        if(-not (Test-Path $challengePath)) {
            New-Item -Path $challengePath -ItemType Directory | Out-Null
        }
    
        Set-Content -Path $fileName -Value $challenge.Data.Content -NoNewLine
    
        # Check if the challenge is readable
        Invoke-WebRequest $challenge.Data.AbsoluteUrl -UseBasicParsing | Out-Null
    
        Write-Host "Completing ACME Challenge"
        # Signal the ACME server that the challenge is ready
        $challenge | Complete-ACMEChallenge $stateDir | Out-Null
    
        # Wait a little bit and update the order, until we see the states
        while($order.Status -notin ("ready","invalid")) {
            Start-Sleep -Seconds 10
            $order | Update-ACMEOrder -state $stateDir -PassThru | Out-Null
        }
    
        $certKeyFile = "$stateDir\$publicDnsName-$(get-date -format yyyy-MM-dd-HH-mm-ss).key.xml"
        $certKey = New-ACMECertificateKey -path $certKeyFile
    
        Write-Host "Completing ACME Order"
        Complete-ACMEOrder -state $stateDir -Order $order -CertificateKey $certKey | Out-Null
    
        # Now we wait until the ACME service provides the certificate url
        while(-not $order.CertificateUrl) {
            Start-Sleep -Seconds 15
            $order | Update-Order -state $stateDir -PassThru | Out-Null
        }
    
        # As soon as the url shows up we can create the PFX
        Write-Host "Exporting certificate to $certificatePfxFilename"
        Export-ACMECertificate -state $stateDir -Order $order -CertificateKey $certKey -Path $certificatePfxFilename -Password $certificatePfxPassword
    
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($certificatePfxFile, $certificatePfxPassword)
        $certificateThumbprint = $cert.Thumbprint
        
        Write-Host "Importing Certificate to LocalMachine\my"
        Import-PfxCertificate -FilePath $certificatePfxFile -CertStoreLocation cert:\localMachine\my -Password (ConvertTo-SecureString -String $certificatePfxPassword -AsPlainText -Force) | Out-Null
        
        $dnsidentity = $cert.GetNameInfo("SimpleName",$false)
        if ($dnsidentity.StartsWith("*")) {
            $dnsidentity = $dnsidentity.Substring($dnsidentity.IndexOf(".")+1)
        }
        Write-Host "DNS identity $dnsidentity"
    }
    catch {
        # If Any error occurs (f.ex. rate-limits), setup self signed certificate
        Write-Host "Error creating letsEncrypt certificate, reverting to self-signed"
        Write-Host "Error was:"
        Write-Host $_.Exception.Message
        . (Join-Path $runPath $MyInvocation.MyCommand.Name)
    }
} else {
    . (Join-Path $runPath $MyInvocation.MyCommand.Name)
}
