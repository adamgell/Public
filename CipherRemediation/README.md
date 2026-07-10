# BitLocker Cipher Upgrade (128-bit → 256-bit)

A two-phase Intune feature that finds OS drives encrypted with a weak BitLocker
cipher (128-bit or non-XTS) and safely upgrades them to **XtsAes256**, escrowing
the new recovery key to Entra ID.

- **Phase 1 — Assess** (`Detect-BitLockerCipher.ps1`): a Proactive Remediation
  detection script that flags non-compliant devices in the Intune report.
- **Phase 2 — Remediate** (`Win32/`): a Win32 app — assigned to the device group
  built from the Phase 1 report — that decrypts, re-encrypts the full disk to
  XtsAes256, and backs the recovery key up to Entra ID via a reboot-surviving
  scheduled task.

Process flowchart: `media/cipher-upgrade-process.png`.

Scope: **OS drive `C:` only**. Compliant cipher: **`XtsAes256` only**. Target
runtime: **Windows PowerShell 5.1** (Intune's script engine).

---

## Phase 1 — Detection (Proactive Remediation)

`Detect-BitLockerCipher.ps1` is **detect-only** — it reports which devices are on
a weak cipher so you can build the remediation group. It does not change anything.

Deploy it in the Intune admin center under **Devices → Scripts and remediations**
(a.k.a. Proactive remediations):

- **Detection script file:** `Detect-BitLockerCipher.ps1`
- **Remediation script file:** *leave empty* (this is detect-only)
- **Run this script using the logged-on credentials:** No (runs as SYSTEM)
- **Enforce script signature check:** No
- **Run script in 64-bit PowerShell:** **Yes** (BitLocker cmdlets require 64-bit)
- **Schedule:** Daily (or as needed)
- **Assignment:** the Windows devices you want to assess

**How to read the results** (Reports → the remediation → *Device status*, column
*Pre-remediation detection output*):

| OS drive `C:` cipher | Exit | Report status | Meaning |
|---|---|---|---|
| `XtsAes256` | 0 | Without issues | Compliant — nothing to do |
| Not encrypted (`None`) | 0 | Without issues | Out of scope (a separate encryption baseline handles this) |
| `XtsAes128`, `Aes128`, `Aes256` (CBC), legacy/hardware, or unreadable | 1 | **With issues** | **Non-compliant** — the detected method is printed |

Build the **remediation device group** from the "With issues" devices (a dynamic
or assigned group). Phase 2 targets that group.

---

## Phase 2 — Remediation (Win32 app)

The Win32 app lives in `Win32/`. Assigning it to the remediation group installs a
SYSTEM scheduled task (`BitLockerCipherRemediation`) that advances one phase per
run and survives reboots: guardrail checks → verify the delivered policy →
decrypt → re-encrypt full-disk to XtsAes256 → escrow the recovery key → done.

### Package

Package the `Win32/` folder with IntuneWinAppUtil (setup file =
`Install-CipherRemediation.ps1`):

```
IntuneWinAppUtil.exe -c .\Win32 -s Install-CipherRemediation.ps1 -o <output>
```

### Intune Win32 app settings

- **Install command:** `powershell.exe -NoProfile -ExecutionPolicy Bypass -File Install-CipherRemediation.ps1`
- **Uninstall command:** `powershell.exe -NoProfile -ExecutionPolicy Bypass -File Uninstall-CipherRemediation.ps1`
- **Install behavior:** System
- **Detection rule:** custom detection **script** = `Win32/Detect-CipherRemediation.ps1`
  (this is the Win32 app's own detection — distinct from the Phase 1 Proactive
  Remediation script — and reports "installed" only when the drive is fully
  XtsAes256, encrypted, and the key is escrowed)
- **Run as 32-bit:** No (BitLocker cmdlets require 64-bit; the scripts also
  self-relaunch via `sysnative` as a safety net)
- **Assignment:** the remediation device group from Phase 1

### Behavior notes

- Install returns success immediately; the real work runs on the scheduled task
  (retries every 15 min, survives reboots). A full decrypt + full-disk
  re-encrypt can take **hours** — the app shows **In progress** until the
  detection rule passes, then flips to **Installed**. This is expected.
- The device is **never decrypted** unless the delivered Intune BitLocker policy
  sets `EncryptionMethodWithXtsOs = 7` (XtsAes256). A missing or weaker policy
  makes the device wait (never decrypting) until the policy lands, or it gives up
  after a 7-day cutoff. The policy is re-checked immediately before decryption
  starts, so a policy rollback during the wait cannot trigger a decrypt.
- **Uninstalling the app removes the scheduled task and working files only — it
  does not decrypt or otherwise change the drive's encryption.**

---

## Runtime, files, and safety

- **Recovery passwords are only ever stored hashed** (SHA-256) — never in
  plaintext, in any log, state file, or output.
- Working directory: `%ProgramData%\BitLockerCipherRemediation\` — `state.json`
  (state machine progress) and `remediation.log` (timestamped activity).
- **Requirements:** a TPM-equipped device (the OS-drive protector requires it);
  hardware self-encrypting drives are detected and skipped. Devices on battery or
  low on free disk space wait until conditions are safe before decrypting.
- **Before broad rollout:** validate a full decrypt → re-encrypt cycle on a
  Windows test device running Windows PowerShell 5.1 (the automated tests mock
  the BitLocker/TPM cmdlets and cannot exercise the real hardware path).
