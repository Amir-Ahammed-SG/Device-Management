# Subway KIOSK setup

Choose **Subway > KIOSK > KIOSK Installation** in Device Management, in an
Administrator terminal running 64-bit Windows PowerShell 5.1.

| Prompt | Behaviour |
| --- | --- |
| Kiosk User | Suggests existing SELISE-KIOSK, otherwise SELISE. Enter confirms; another existing, enabled local account can be entered. |
| Restaurant ID | Required; empty or unsafe URL values are requested again. |
| Kiosk ID | Required; empty or unsafe URL values are requested again. |
| Hostname | Suggests the current Windows computer name; Enter confirms or a valid manual hostname can be entered. |

All inputs are collected before setup writes anything. The selected account's
existing C:\Users\<account> profile and the script's original Edge path must exist.
IDs accept letters, digits, dots, underscores, dashes and tildes, matching SaaS.

The source is the supplied Subway script. Apart from replacing its four static
inputs with prompts and renaming ZabbixHostName to HostName, its setup body is
retained exactly: Subway URL, auto-login, existing policy writes, Explorer
restart, launcher, Startup BAT and Desktop shortcut. This includes the original
duplicate policy command and existing-shortcut behaviour. No new policy is added.
The original empty auto-login DefaultPassword is retained.

HostName is a local variable. The URL still uses the same `host=` parameter;
renaming that variable does not change the URL parameter contract or configure
a Zabbix Agent. Windows itself is not renamed.

The separate handler verifies resulting registry/files and Desktop shortcut
properties before reporting success. An incorrect existing shortcut is retained
as in the original script and reported for manual review. The script can also
run directly; menu context/admin checks and result readback belong to the handler.
