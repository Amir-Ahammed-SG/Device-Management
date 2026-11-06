# Chrome kiosk setup copies

Google Chrome is currently **Not available** in the installation menu. The release bundle retains both browser setups for both clients, and the Chrome scripts can still run directly. Thorough Check still expects Edge for browser-specific checks and fixes, so it cannot validate these Chrome settings.

| Client | Standalone Chrome setup | Kiosk origin | Desktop shortcut |
| --- | --- | --- | --- |
| SaaS | `Installations\KIOSK\SaaS\Kiosk_Mode_Setup_Chrome.ps1` | `https://kiosk.ordermonkey.com` | `LaunchKiosk.lnk`, updated and verified |
| Subway | `Installations\KIOSK\Subway\Kiosk_Mode_Setup_Chrome.ps1` | `https://kiosk.subway.ch` | `LaunchKiosk.lnk`, updated and verified |

Run the appropriate command from the DeviceManagement folder in **Administrator, 64-bit Windows PowerShell 5.1**:

```powershell
# SaaS
& '.\Installations\KIOSK\SaaS\Kiosk_Mode_Setup_Chrome.ps1'

# Subway (run this instead for a Subway kiosk)
& '.\Installations\KIOSK\Subway\Kiosk_Mode_Setup_Chrome.ps1'
```

An existing enabled local account and initialized `C:\Users\<account>` profile are required. Install Chrome first: setup searches 64-bit Program Files, 32-bit Program Files, then the selected kiosk account's per-user Chrome installation. It does not download a browser or create an account.

Chrome is temporarily marked **Not available** in the SaaS and Subway browser menus. Selecting it does not start setup; the implementation below is retained for future use.

The account, Restaurant ID, Kiosk ID, and Hostname prompts match the Edge copies. The hostname suggestion comes from Windows DNSHostName and retains names longer than 15 characters, such as OM-DHK-PAN-KIOSK. If detection is unavailable, the full name must be entered manually. The confirmed hostname is passed unchanged to the onboarding URL; Windows is not renamed. `-WhatIf` prints an overview without prompting or writing.

## Changes on the kiosk PC

- Replaces the selected account's `Scripts\LaunchKiosk.ps1` and Startup `LaunchKiosk.bat` to launch Chrome. These are the same launcher paths used by Edge, so the selected account starts one browser. The original Edge setup source files remain available.
- Uses Chrome `--kiosk`, `--incognito`, `--disable-pinch`, and `--overscroll-history-navigation=0`, with quoted URL and profile arguments. `Scripts\ChromeKioskProfile` is a separate profile directory, created by Chrome on first launch. Chrome opens an Incognito kiosk session; existing Edge sessions and Chrome's ordinary profile are not migrated. Re-run Chrome KIOSK Installation on existing kiosks to update their saved launcher, then close existing Chrome kiosk windows and relaunch.
- Disables Chrome translation and allows the appropriate kiosk origin to access the local network under `HKLM:\SOFTWARE\Policies\Google\Chrome`. Other allowlist entries are retained. These browser policies apply to Chrome machine-wide. Local-network permission is distinct from general popup blocking.
- Sets local-account auto-login username, computer/domain, and AutoAdminLogon. Existing DefaultPassword values are preserved. A stored nonempty password for another account stops setup before writes. If DefaultPassword is absent, setup uses an empty value as in the original passwordless-account setup. A password-protected account needs correctly configured auto-login credentials separately; saved registry settings alone do not prove sign-in works.
- For both clients, saves and verifies the desktop shortcut targeting the startup BAT, including when a shortcut already exists.

Chrome setup does not write Edge policies, Edge Visual Search settings, Windows swipe/touchpad settings, or restart Explorer. Browser gestures are handled by Chrome launch arguments. Chrome fullscreen kiosk mode does not configure Windows Assigned Access or prevent Windows keyboard shortcuts.

## Verification and recovery

All prerequisites and in-memory snapshots precede writes. Setup verifies the saved registry values and types, launcher bytes, and desktop shortcut properties before reporting success. On failure it attempts to restore the prior registry values and exact file bytes; rollback failures are reported. Newly created empty directories and registry keys may remain. No credential snapshot is written to disk.

Local validation covers both clients, all three Chrome locations, input retries, launcher quoting, existing credentials and allowlists, repeated setup, missing prerequisites, ineffective writes, rollback, and WhatIf. Existing Edge installation tests are also retained. These tests simulate Windows mutations and do not install anything on the development computer.

On a test kiosk, close existing Chrome kiosk windows, sign in as the kiosk account, and check startup, fullscreen, the onboarding URL, touchscreen pinch/swipe behavior, local-device access, and reboot auto-login. Inspect `chrome://policy` for policy acceptance. Browser launch and sign-in require this device check; the script verifies configuration on disk and in the registry.

Policy and switch references: [Chrome enterprise policy list](https://chromeenterprise.google/policies/), [Chrome translation policy](https://support.google.com/chrome/a/answer/9036555), [Windows Chrome local-network registry policy](https://learn.microsoft.com/en-us/ecdn/how-to/configure-local-network-access-policy), [Chromium kiosk switch](https://github.com/chromium/chromium/blob/main/chrome/common/chrome_switches.h).
