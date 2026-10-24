# Known issues

1. Only SaaS/Subway KIOSK Thorough Check is implemented in the current launcher.
   Payment Service, installation operations and POS/KDS Thorough Check remain
   Pending. Earlier status notes describing these as implemented are obsolete.
2. The local file-based KIOSK handler finds a recent HTML report by timestamp.
   The CDN in-memory dispatcher now receives and verifies the exact report path.
3. The Zabbix installation package is downloaded without a pinned package hash.
   Existing-agent configuration is observed, not repaired. Server/ServerActive
   are not validated, so service Pass does not certify complete agent settings.
4. The interactive launcher exits with code 0 after the operator leaves the menu,
   even if the last operation failed. Individual results retain their status.
5. The Windows 10 Nmap installer package is not populated. The last official
   download attempt failed certificate validation; see
   [preparation status](Docs/Validation/Nmap-Package-Status.md). Existing Nmap is
   retained; the public installer requires interaction. Fully silent installation
   requires Nmap OEM.
6. The last parent regression suite has 36 existing failures; see
   [validation status](Docs/Validation/README.md). Isolated tests do not replace
   a controlled test-PC run for services, registry, profiles and installers.

The local launcher requires both client check sources beside the parent of its
project directory. CDN memory delivery embeds these sources. It does not include
a local Windows 10 Nmap installer; that installer remains a separate manual step.
