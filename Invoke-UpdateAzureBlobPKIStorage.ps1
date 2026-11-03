### create 2026-10-28 by Akif Calhan
### Uploads CRL/AIA files from the local CertEnroll folder to Azure Blob Storage (AzCopy v10)
### and verifies that the public CDP URL serves the same CRLs as the local CA.
### License: GPL-3.0-or-later
###
### Exit codes (visible as Last Run Result in the scheduled task):
###   0 = OK, 1 = upload failed, 2 = online CRL differs or is unreachable, 3 = prerequisite missing

# --- Configuration ----------------------------------------------------------
$BasePath    = 'C:\Scripts\CRLazcopy'
$AzCopy      = Join-Path $BasePath 'azcopy.exe'
$SasFile     = Join-Path $BasePath 'sas.txt'                                   # SAS token only, readable by SYSTEM + Administrators
$Destination = 'https://<storageaccount>.blob.core.windows.net/<container>'  # container URL without SAS
$PublicBase  = 'http://pki.example.com/<container>'                          # exactly the URL used in the CDP/AIA extensions (http!)
$Source      = Join-Path $env:SystemRoot 'System32\CertSrv\CertEnroll'
$LogDir      = Join-Path $BasePath 'logs'
$LogFile     = Join-Path $LogDir 'CRLUpload.log'
$KeepDays    = 30                                                              # retention for AzCopy logs and job plans
$Exclude     = ''                                                              # e.g. '*Root-CA*' on all issuing CAs except one, so only one CA uploads the root CRL/CRT

# Tab-delimited log line: timestamp, status, message
function Write-Log ($Status, $Text) { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`t$Status`t$Text" | Out-File $LogFile -Append -Encoding UTF8 }

# Stops the transcript and ends the script with the given exit code
function Exit-Script ($Code) { Write-Host "Exit code: $Code"; Stop-Transcript | Out-Null; exit $Code }

# --- Prerequisites ----------------------------------------------------------
New-Item $LogDir -ItemType Directory -Force | Out-Null

# Full console transcript as a fallback, one file per day (removed by the cleanup after $KeepDays)
Start-Transcript -Path (Join-Path $LogDir ("Transcript_{0:yyyyMMdd}.log" -f (Get-Date))) -Append | Out-Null
foreach ($p in $AzCopy, $SasFile, $Source) { if (-not (Test-Path $p)) { Write-Log 'ERROR' "Missing: $p"; Exit-Script 3 } }

# Keep AzCopy logs and job plans in a defined place (otherwise they grow unnoticed in the task account's profile)
$env:AZCOPY_LOG_LOCATION      = $LogDir
$env:AZCOPY_JOB_PLAN_LOCATION = Join-Path $LogDir 'plans'

$sas = (Get-Content $SasFile -Raw).Trim().TrimStart('?')

# --- Upload -----------------------------------------------------------------
# Native executables do not throw on failure, so the result is evaluated via $LASTEXITCODE
$excl = if ($Exclude) { "--exclude-pattern=$Exclude" }
$out = & $AzCopy copy "$Source\*" "$Destination`?$sas" --include-pattern='*.crl;*.crt' $excl --overwrite=ifSourceNewer --log-level=ERROR 2>&1
$rc  = $LASTEXITCODE
$out | ForEach-Object { Write-Host $_ }   # write AzCopy output to the transcript (AzCopy redacts the SAS signature)
$sum = ($out | Select-String 'File Transfers (Completed|Failed|Skipped)|Final Job Status' | ForEach-Object { $_.Line.Trim() }) -join ' | '

if ($rc -ne 0) {
    Write-Log 'ERROR' "AzCopy exit code $rc | $sum"
    $out | Select-String 'error|fail|denied|403' | Select-Object -First 10 | ForEach-Object { Write-Log 'ERROR' $_.Line.Trim() }
    Exit-Script 1
}
Write-Log 'OK' "Upload | $sum"

# --- Online check: does the public URL serve the same CRL as the local CA? ---
$bad = 0
foreach ($f in Get-ChildItem $Source -Filter '*.crl' -File | Where-Object { -not $Exclude -or $_.Name -notlike $Exclude }) {
    $url = "$PublicBase/$([uri]::EscapeDataString($f.Name))"   # '+' -> %2B (delta CRL), space -> %20
    $tmp = Join-Path $env:TEMP ("crlcheck_{0}.crl" -f [guid]::NewGuid())
    try {
        Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        if ((Get-FileHash $tmp).Hash -eq (Get-FileHash $f.FullName).Hash) { Write-Log 'OK' "Online up to date`t$url" }
        else { Write-Log 'WARN' "Online differs from local`t$url"; $bad++ }
    }
    catch { Write-Log 'ERROR' "Online not reachable`t$url`t$($_.Exception.Message)"; $bad++ }
    finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

# --- Cleanup ----------------------------------------------------------------
Get-ChildItem $LogDir -Recurse -File | Where-Object { $_.FullName -ne $LogFile -and $_.LastWriteTime -lt (Get-Date).AddDays(-$KeepDays) } | Remove-Item -Force -ErrorAction SilentlyContinue

if ($bad -gt 0) { Exit-Script 2 }
Exit-Script 0
