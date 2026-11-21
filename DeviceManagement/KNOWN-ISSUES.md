# Known issues and operational limits

1. SaaS/Subway KIOSK Thorough Check and KIOSK Installation are implemented.
   Payment Service package operations, other client/device installations and
   POS/KDS Thorough Check remain unavailable. Selecting them changes nothing.
2. The local file-based check handler finds a recent HTML report by timestamp.
   The CDN in-memory dispatcher verifies the exact report path returned by the
   engine. Local timestamp selection can be ambiguous with simultaneous runs.
3. The Zabbix installation package is downloaded without a pinned package hash.
   Apply can repair its hostname to the detected Windows DNS hostname and verify
   service settings, but Server/ServerActive are not validated. A service Pass
   does not certify complete monitoring configuration.
4. The interactive launcher exits with code 0 when the operator leaves the menu,
   even if the last operation failed. Individual operation results retain status.
5. No Windows 10 Nmap installer binary is committed or embedded. Prepare and
   verify a local package using Packages/Nmap before offline delivery. The public
   installer requires interaction; fully silent installation requires Nmap OEM.
6. Isolated fixtures do not replace a controlled test-PC run for real services,
   registry, profiles and installers. Browser tests require permission to start
   Edge child processes; native Restart Manager integration is opt-in. See the
   [testing guide](Docs/Testing.md).
7. Historical report-layout records target retired separate client sources.
   Their restore utility has been removed. Review archived records before any
   manual restoration; never apply them directly to the shared engine. See
   [recovery instructions](Docs/Maintenance.md).
