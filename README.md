# AD CS CRL Publishing to Azure Blob Storage

![PowerShell](https://img.shields.io/badge/PowerShell-5391FE?style=for-the-badge&logo=powershell&logoColor=white)
![Windows Server](https://img.shields.io/badge/Windows%20Server-0078D6?style=for-the-badge&logo=windows&logoColor=white)
![Azure](https://img.shields.io/badge/Azure-0089D6?style=for-the-badge&logo=microsoftazure&logoColor=white)
![Security](https://img.shields.io/badge/Security-PKI-C0392B?style=for-the-badge)

![License](https://img.shields.io/badge/License-GPLv3-blue.svg)

This repository contains a PowerShell script that publishes the CRLs and AIA certificates of a Microsoft **Enterprise Issuing CA** to **Azure Blob Storage** using AzCopy v10, and verifies that the public CDP URL serves exactly the same CRLs as the local CA. It provides a highly available, Internet-reachable CDP/AIA location without internal web servers, a DMZ or a reverse proxy, so revocation checks also work for clients outside the corporate network.

**Author:** Ing. Akif Calhan  
**Year:** 2026  
**License:** GNU General Public License v3.0 (GPLv3)

---

## 🛡️ Security & Reliability (Modern Best Practices)

The script is designed for unattended operation on a Tier 0 system. It treats a silent upload failure as the main risk, because an expired CRL online breaks revocation checking for every client.

- **No secrets in code:** The SAS token is read from a separate `sas.txt`, restricted to `SYSTEM` and `Administrators` via `icacls`. AzCopy redacts the SAS signature in its output, so the token does not appear in logs or transcripts.
- **Least-privilege SAS:** Designed for a SAS token with `r`, `c`, `w` only (no delete, no list), based on a **Stored Access Policy** so it can be revoked without rotating the storage account key.
- **Reliable error detection:** Native executables do not throw PowerShell exceptions, so the AzCopy result is evaluated via `$LASTEXITCODE` instead of `try/catch`. Failures bubble up as exit codes to the scheduled task's *Last Run Result*.
- **Online verification:** After each upload, every local CRL is downloaded from the public CDP URL and compared by SHA256 hash. A missing, outdated or unreachable online CRL is reported even if the upload itself succeeded.
- **Delta CRL support:** File names are URL-encoded (`+` → `%2B`), so delta CRLs are checked correctly.
- **Multi-CA safe:** With several issuing CAs uploading to the same container, `$Exclude` ensures that only one CA publishes the root CRL/CRT. This prevents an older root CRL from overwriting a newer one, because `ifSourceNewer` compares timestamps, not content.
- **Audit trail:** Tab-delimited log for direct Excel import, plus a full daily PowerShell transcript. AzCopy logs and job plans are kept in a defined folder instead of growing unnoticed in the task account's profile.

> **Out of scope:** CA hardening (ESC6/ESC11/ESC16), certificate template and ACL findings (ESC1–ESC5, ESC7, ESC9/10, ESC13–15) and the CDP/AIA extension configuration itself are not covered by this script. See the [pki](https://github.com/Akifcal/pki) repository for CA configuration.

---

## 📁 Included Files

1. **Invoke-UpdateAzureBlobPKIStorage.ps1:** Upload and online verification script.
2. **CRLazcopy-Task.xml:** Scheduled task definition for import into Task Scheduler.

---

## 🚀 Features & Configuration Details

### 1. Upload Script

Designed for an Enterprise Issuing CA (domain joined) with the default `CertEnroll` folder.

- **Source:** `%SystemRoot%\System32\CertSrv\CertEnroll`, file types `*.crl` and `*.crt`.
- **Upload Mode:** Only files newer than the online copy are uploaded (`--overwrite=ifSourceNewer`).
- **Verification:** SHA256 comparison of every local CRL against the public CDP URL.
- **Logging:** `CRLUpload.log` (tab-delimited, kept), `Transcript_yyyyMMdd.log`, AzCopy job logs (errors only).
- **Retention:** Transcripts, AzCopy logs and job plans are removed after 30 days (`$KeepDays`).

| Exit code | Meaning |
|---|---|
| `0` | Upload OK, all online CRLs match the local CRLs |
| `1` | AzCopy failed (authentication, network, SAS expired, ...) |
| `2` | An online CRL differs from the local one or cannot be downloaded |
| `3` | Prerequisite missing (`azcopy.exe`, `sas.txt` or `CertEnroll` folder) |

### 2. Scheduled Task

- **Account:** `SYSTEM` (S-1-5-18), run with highest privileges.
- **Triggers:** Every **1 hour** (indefinitely) and **at startup** with a 5-minute delay.
- **Limits:** 30-minute time limit, no parallel instances, missed runs are started as soon as possible.
- **Compatibility:** Windows Server 2016 and later.

---

## 💻 Usage

The configuration is a block of variables at the top of the script. Run all commands in an elevated PowerShell window.

### Prerequisites

1. **Azure Storage:** Create a container (e.g. `certdata`) with public access level **Blob**. If clients use `http://` CDP/AIA URLs, disable **Secure transfer required** on the storage account.
2. **DNS:** Map your own name (e.g. `pki.yourdomain.com`) to the storage account, so issued certificates do not depend on the storage account name.
3. **SAS Token:** Create a Stored Access Policy with `r`, `c`, `w` and a lifetime of 1–2 years, then a SAS token based on it.
4. **AzCopy:** Download [AzCopy v10](https://learn.microsoft.com/azure/storage/common/storage-use-azcopy-v10) and place `azcopy.exe` in the script folder.

### For the Issuing CA

1. Copy the script and `azcopy.exe` to `C:\Scripts\CRLazcopy`.
2. **Input 1:** Set `$Destination` to the container URL **without** SAS (e.g. `https://<storageaccount>.blob.core.windows.net/certdata`).
3. **Input 2:** Set `$PublicBase` to exactly the URL used in the CDP/AIA extensions (e.g. `http://pki.yourdomain.com/certdata`).
4. **Input 3:** Put only the SAS token into `sas.txt` and restrict access:
   ```powershell
   icacls C:\Scripts\CRLazcopy\sas.txt /inheritance:r /grant:r "SYSTEM:R" "Administrators:F"
   ```
5. Run the script once interactively and check the log:
   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-UpdateAzureBlobPKIStorage.ps1; "ExitCode: $LASTEXITCODE"
   Get-Content .\logs\CRLUpload.log -Tail 20
   ```
   Expected: exit code `0` and one `Online up to date` line per CRL. A second run reports all files as *Skipped*.

### For Multiple Issuing CAs

1. **Designated CA:** `$Exclude = ''`, uploads and verifies the root CRL/CRT.
2. **All other Issuing CAs:** `$Exclude = '*Root-CA*'` (adjust to your root CA name).
3. Verify with `Get-ChildItem C:\Windows\System32\CertSrv\CertEnroll` that the pattern matches only the root files.

### Scheduled Task

1. Import the task definition:
   ```powershell
   Register-ScheduledTask -TaskName 'CRLazcopy' -Xml (Get-Content .\CRLazcopy-Task.xml -Raw)
   ```
2. Start it once and check the result in the SYSTEM context:
   ```powershell
   Start-ScheduledTask 'CRLazcopy'; Start-Sleep 30; Get-ScheduledTaskInfo 'CRLazcopy' | % { "$($_.LastRunTime)`t$($_.LastTaskResult)`t$($_.NextRunTime)" }
   ```
3. Make sure the upload interval is clearly shorter than the delta CRL overlap:
   ```powershell
   certutil -getreg CA\CRLDeltaOverlapUnits; certutil -getreg CA\CRLDeltaOverlapPeriod
   ```

---

## ⚠️ Disclaimer

This program is distributed in the hope that it will be useful, but **WITHOUT ANY WARRANTY**; without even the implied warranty of **MERCHANTABILITY** or **FITNESS FOR A PARTICULAR PURPOSE**. See the [GNU General Public License](https://www.gnu.org/licenses/gpl-3.0.html) for more details.
