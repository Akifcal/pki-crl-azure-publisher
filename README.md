# Invoke-UpdateAzureBlobPKIStorage

Publishes CRLs and AIA certificates from an AD CS issuing CA to Azure Blob Storage with AzCopy v10, then checks that the public CDP URL serves exactly the same CRLs as the local CA.

This gives you a highly available, Internet-reachable CDP/AIA location without internal web servers, a DMZ or a reverse proxy, so revocation checks also work for clients outside the corporate network.

## What it does

1. Uploads `*.crl` and `*.crt` from `%SystemRoot%\System32\CertSrv\CertEnroll` to a blob container. Only files newer than the online copy are uploaded (`--overwrite=ifSourceNewer`).
2. Downloads every local CRL from the public CDP URL and compares the SHA256 hash with the local file.
3. Writes a tab-delimited log (`CRLUpload.log`) plus a daily PowerShell transcript and returns an exit code that shows up as *Last Run Result* in Task Scheduler.

| Exit code | Meaning |
|---|---|
| 0 | Upload OK, all online CRLs match the local CRLs |
| 1 | AzCopy failed (auth, network, SAS expired, ...) |
| 2 | An online CRL differs from the local one or cannot be downloaded |
| 3 | Prerequisite missing (azcopy.exe, sas.txt or CertEnroll folder) |

## Requirements

- Windows Server with AD CS (issuing CA), Windows PowerShell 5.1
- [AzCopy v10](https://learn.microsoft.com/azure/storage/common/storage-use-azcopy-v10) (`azcopy.exe` in the script folder)
- Azure Storage account with a blob container, anonymous read access on blob level
- A DNS name (CNAME) for the CDP/AIA URL, e.g. `pki.example.com`, used in the CA's CDP and AIA extensions
- Outbound HTTPS from the CA to `*.blob.core.windows.net`, HTTP to the public CDP URL

## Setup

### 1. Storage account

- Create a container (e.g. `certdata`) with public access level **Blob**.
- CDP/AIA URLs should be `http://`, because revocation checking over HTTPS creates a chicken-and-egg problem. If clients use plain HTTP, **Secure transfer required** must be disabled on the storage account.
- Map your own DNS name to the storage account (custom domain or CDN), so the URL inside issued certificates does not depend on the storage account name.

### 2. SAS token

Create a **Stored Access Policy** on the container and a SAS token based on it, with minimum permissions:

- Permissions: `r`, `c`, `w` (read, create, write), **no** delete, list or immutable
- Lifetime: 1-2 years, with a reminder to renew

A SAS based on a stored access policy can be revoked by deleting the policy, without rotating the storage account key.

Put only the token (with or without leading `?`) into `sas.txt` and restrict access:

```powershell
icacls C:\Scripts\CRLazcopy\sas.txt /inheritance:r /grant:r "SYSTEM:R" "Administrators:F"
```

### 3. Script configuration

Copy `Invoke-UpdateAzureBlobPKIStorage.ps1` and `azcopy.exe` to `C:\Scripts\CRLazcopy` and adjust the configuration block:

| Variable | Description |
|---|---|
| `$BasePath` | Script folder |
| `$Destination` | Container URL **without** SAS, e.g. `https://<storageaccount>.blob.core.windows.net/certdata` |
| `$PublicBase` | Exactly the URL used in the CDP/AIA extensions, e.g. `http://pki.example.com/certdata` |
| `$KeepDays` | Retention for AzCopy logs, job plans and transcripts |
| `$Exclude` | File name pattern to skip (upload and online check), see below |

### 4. Multiple issuing CAs

If several issuing CAs upload to the same container and each of them also holds the root CRL/CRT, let only **one** of them upload the root files:

- Designated CA: `$Exclude = ''`
- All other issuing CAs: `$Exclude = '*Root-CA*'` (adjust to your root CA name)

Otherwise a CA with an older copy of the root CRL can overwrite a newer one, because `ifSourceNewer` compares timestamps, not content. Check with `Get-ChildItem C:\Windows\System32\CertSrv\CertEnroll` that the pattern matches only the root files.

### 5. Scheduled task

Import `CRLazcopy-Task.xml` (Task Scheduler → *Import Task...*) or:

```powershell
Register-ScheduledTask -TaskName 'CRLazcopy' -Xml (Get-Content .\CRLazcopy-Task.xml -Raw)
```

The task runs as SYSTEM every hour and 5 minutes after startup, with a 30 minute time limit and no parallel instances. The upload interval must be clearly shorter than the delta CRL overlap period:

```powershell
certutil -getreg CA\CRLDeltaOverlapUnits; certutil -getreg CA\CRLDeltaOverlapPeriod
```

## Testing

```powershell
# interactive
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-UpdateAzureBlobPKIStorage.ps1; "ExitCode: $LASTEXITCODE"
Get-Content .\logs\CRLUpload.log -Tail 20

# in the task context
Start-ScheduledTask 'CRLazcopy'; Start-Sleep 30; Get-ScheduledTaskInfo 'CRLazcopy' | % { "$($_.LastRunTime)`t$($_.LastTaskResult)`t$($_.NextRunTime)" }
```

Expected: exit code 0, one `Online up to date` line per CRL. A second run should report all files as *Skipped*.

Negative tests: rename `sas.txt` (exit 3), change one character of the SAS signature (exit 1).

From a client outside the network:

```powershell
certutil -URL http://pki.example.com/certdata/<CA-Name>.crl
```

## Logs

All logs are written to `$BasePath\logs`:

| File | Content |
|---|---|
| `CRLUpload.log` | Tab-delimited: timestamp, status, message (kept) |
| `Transcript_yyyyMMdd.log` | Full console output per day |
| `<JobId>.log` | AzCopy job log (errors only) |
| `plans\` | AzCopy job plans |

Everything except `CRLUpload.log` is removed after `$KeepDays` days.

## License

GPL-3.0-or-later
