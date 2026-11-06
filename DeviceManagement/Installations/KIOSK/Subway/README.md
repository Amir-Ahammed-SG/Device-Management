# Subway KIOSK setup

Choose **Subway > KIOSK > KIOSK Installation** in Device Management, in an
Administrator terminal running 64-bit Windows PowerShell 5.1.

| Prompt | Behaviour |
| --- | --- |
| Kiosk User | Suggests existing SELISE-KIOSK, otherwise SELISE. Enter confirms; another existing, enabled local account can be entered. |
| Restaurant ID | Required; empty or unsafe URL values are requested again. |
| Kiosk ID | Required; empty or unsafe URL values are requested again. |
| Hostname | Suggests the full Windows DNS hostname, including names longer than 15 characters; Enter confirms or a valid manual hostname can be entered. |

All inputs are collected before setup writes anything. The selected account's
existing C:\Users\<account> profile and the script's original Edge path must exist.
IDs accept letters, digits, dots, underscores, dashes and tildes, matching SaaS.

The shared Edge setup uses Subway client configuration, auto-login, browser policies, Explorer restart, launcher, Startup BAT and Desktop shortcut. The allowlist is written once, and existing shortcuts are preserved and verified. The original empty auto-login DefaultPassword is retained.

HostName is a local variable. The URL still uses the same `host=` parameter;
renaming that variable does not change the URL parameter contract or configure
a Zabbix Agent. Windows itself is not renamed.

The shared handler verifies resulting registry/files and Desktop shortcut
properties before reporting success. An incorrect existing shortcut is retained
as in the original script and reported for manual review. The script can also
run directly; menu context/admin checks and result readback belong to the handler.


## Browser selection

KIOSK Installation offers **Microsoft Edge only**. Back and Exit make no setup changes.

Hostname detection reads `Win32_ComputerSystem.DNSHostName` directly. If it is unavailable, enter the full hostname manually; setup does not substitute a shortened environment name.
