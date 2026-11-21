# Shared KIOSK setup

Choose **SaaS or Subway > KIOSK > KIOSK Installation** in Device Management.
Run the menu in an Administrator terminal with 64-bit Windows PowerShell 5.1.

Both clients use `Install.ps1` and `Setup-Edge.ps1`. The selected client is passed
explicitly; URLs and payment settings come from `../../Config/KioskClients.psd1`.
Microsoft Edge is the default installation browser. Selecting KIOSK Installation
starts its setup prompts directly, with no browser selection screen. Result Back
returns to the operation menu. Other client/device installations remain pending.

All inputs are collected before setup writes anything:

| Prompt | Behaviour |
| --- | --- |
| Kiosk User | Suggests existing SELISE-KIOSK, otherwise SELISE; another existing, enabled local account can be entered. |
| Restaurant ID | Required; empty or unsafe URL values are requested again. |
| Kiosk ID | Required; empty or unsafe URL values are requested again. |
| Hostname | Suggests the full Windows DNS hostname; Enter confirms it or a valid manual hostname can be entered. |

The selected account's existing `C:\Users\<account>` profile and the configured
Edge executable must exist before changes start. IDs accept letters, digits,
dots, underscores, dashes and tildes. If DNS hostname detection is unavailable,
enter the full hostname manually; a shortened environment name is not substituted.

Setup configures auto-login with the original empty DefaultPassword, Edge and
gesture settings, Explorer restart, launcher, Startup BAT and Desktop shortcut.
Existing shortcuts are preserved and verified. A mismatched shortcut requires
manual review. The handler verifies registry, file and shortcut values before
reporting success. Installation does not generate a Thorough Check report,
install Zabbix or rename Windows.

For direct setup from the application folder, select the client explicitly:

```powershell
.\Installations\KIOSK\Setup-Edge.ps1 -ClientType SaaS
.\Installations\KIOSK\Setup-Edge.ps1 -ClientType Subway
```

The menu adds context/admin checks, native exit handling and result readback.
Client-specific setup scripts are no longer provided.
