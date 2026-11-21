# Shared kiosk services functions. Dot-sourced into the engine's scope.

function Get-ThoroughAppSettingsPrinterInventory {
    # Collect connection evidence once; rendering must never query the device.
    try { $printers=@(Get-Printer -ErrorAction Stop) } catch { return }
    $ports=@()
    try { $ports=@(Get-PrinterPort -ErrorAction Stop) } catch { $ports=@() }
    foreach($printer in $printers){
        $connection='Not verified'
        $portNames=@(([string]$printer.PortName -split ',') | ForEach-Object {$_.Trim()} | Where-Object {$_})
        if($portNames.Count -eq 1){
            $port=@($ports | Where-Object { $_.Name -ieq $portNames[0] })
            if($port.Count -eq 1){
                if($portNames[0] -match '^USB\d+$' -and [string]$port[0].PortMonitor -ieq 'USB Monitor'){$connection='USB'}
                elseif($port[0].PSObject.Properties['PrinterHostAddress'] -and -not [string]::IsNullOrWhiteSpace([string]$port[0].PrinterHostAddress)){$connection='IP'}
            }
        }
        [pscustomobject]@{Name=[string]$printer.Name;PortName=[string]$printer.PortName;ConnectionType=$connection}
    }
}

function Format-ThoroughFinalServiceRecovery {
    param([Parameter(Mandatory=$true)]$Row,[AllowEmptyString()][string]$Html)
    # Final presentation only; summarize observed actions without changing any result.
    if($Row.ItemSub -notin @('Type: Payment Gateway Middleware','Type: Infrastructure Monitoring','Type: Windows Update Engine','Type: Old Payment Service')){return $Html}
    $requirements=Get-ThoroughReportHighlightFields (Get-ReportRequirement $Row)
    $labels=@('First failure','Second failure','Subsequent failures')
    $blockPattern='(?is)<div class="kv-block">(?<Body>(?:<div(?: class="service-recovery-summary")?>(?:<span class="kv-label">[^<]*</span>)?[^<]*</div>\s*)*)</div>'
    [regex]::Replace($Html,$blockPattern,[Text.RegularExpressions.MatchEvaluator]{
        param($block)
        $body=$block.Groups['Body'].Value
        if($body.Contains('class="service-recovery-summary"') -or ($body -match 'class="kv-label">' -and $body -notmatch 'class="kv-label">(?:First failure|Second failure|Subsequent failures):')){return $block.Value}
        $observed=Get-ThoroughReportHighlightFields $body
        $unknown=$false;$mismatched=$false
        if($Row.PSObject.Properties['RecoveryDetails'] -and $Row.RecoveryDetails.PSObject.Properties['Verified'] -and -not $Row.RecoveryDetails.Verified){$unknown=$true}
        foreach($label in $labels){
            if(-not $requirements.ContainsKey($label) -or [string]::IsNullOrWhiteSpace([string]$requirements[$label])){$unknown=$true;continue}
            $actual=if($observed.ContainsKey($label)){([string]$observed[$label]).Trim()}else{''}
            if(-not $actual -or $actual -match '(?i)not verified|not detected|not recorded|unknown|unavailable'){$unknown=$true;continue}
            if($actual -ine ([string]$requirements[$label]).Trim()){$mismatched=$true}
        }
        $summary=if($mismatched){'Not Configured'}elseif($unknown){'Not Verified'}else{'Configured'}
        $line='<div class="service-recovery-summary"><span class="kv-label">Recovery:</span> '+$summary+'</div>'
        $render=[pscustomobject]@{Written=$false}
        $body=[regex]::Replace($body,'(?is)<div><span class="kv-label">(?:First failure|Second failure|Subsequent failures):</span>\s*[^<]*</div>',[Text.RegularExpressions.MatchEvaluator]{
            param($field)
            if($render.Written){return ''}
            $render.Written=$true
            $line
        })
        if(-not $render.Written){$body+=$line}
        '<div class="kv-block">'+$body+'</div>'
    })
}

function ConvertTo-FirewallRuleObservation {
    param($Filter,$Rule)
    [pscustomobject]@{
        Direction=[string]$Rule.Direction
        Protocol=$(if([string]$Filter.Protocol -in @('TCP','6')){'TCP'}else{[string]$Filter.Protocol})
        Ports=@($Filter.LocalPort | ForEach-Object {[string]$_})
        Enabled=$(switch([string]$Rule.Enabled){'True'{'Yes'};'False'{'No'};default{[string]$Rule.Enabled}})
        Action=[string]$Rule.Action
    }
}

function Test-ZabbixMonitoringHostname {
    param([string]$Hostname)
    return (-not [string]::IsNullOrWhiteSpace($Hostname) -and $Hostname -notin @('Not detected','Not verified','Unknown') -and $Hostname -match '^[A-Za-z0-9 ._-]{1,128}\z')
}

function Read-ZabbixMonitoringHostname {
    param([string]$SuggestedName)
    if(-not (Test-CanApply)){throw 'Zabbix hostname input is disabled outside Apply Fix or the installation tool.'}
    do {
        $suggested=Test-ZabbixMonitoringHostname $SuggestedName
        $prompt=if($suggested){'Zabbix hostname ['+$SuggestedName+']'}else{'Zabbix hostname'}
        $hostname=([string](Read-Host $prompt)).Trim()
        if(-not $hostname -and $suggested){$hostname=$SuggestedName}
        if(Test-ZabbixMonitoringHostname $hostname){return $hostname}
        Write-Host 'Enter one Zabbix hostname (up to 128 letters, numbers, spaces, dots, underscores or hyphens).' -ForegroundColor Yellow
    }while($true)
}

function Get-ZabbixHostnameSetting {
    param([string]$CommandLine,[string]$DefaultConfigurationPath=(Join-Path $env:ProgramFiles 'Zabbix Agent 2\zabbix_agent2.conf'),[switch]$AllowMissing)
    if([string]::IsNullOrWhiteSpace($CommandLine)){throw 'The Zabbix service command line is unavailable.'}
    $match=[regex]::Match($CommandLine,'(?:^|\s)(?:-c|--config)(?:\s+|=)(?:"([^"]+)"|(\S+))')
    $root=if($match.Success){if($match.Groups[1].Success){$match.Groups[1].Value}else{$match.Groups[2].Value}}else{$DefaultConfigurationPath}
    $root=[Environment]::ExpandEnvironmentVariables($root)
    if(-not [IO.Path]::IsPathRooted($root)){throw 'A relative Zabbix configuration path requires manual review.'}
    $pending=[Collections.Generic.Queue[string]]::new();$pending.Enqueue($root)
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $settings=[Collections.Generic.List[object]]::new()
    $rootFile=$null;$dynamicHostname=$false
    while($pending.Count){
        $path=$pending.Dequeue()
        if(-not $seen.Add([IO.Path]::GetFullPath($path))){continue}
        if($seen.Count -gt 100){throw 'Too many Zabbix configuration includes.'}
        $file=Read-ThoroughTextFile $path
        if($null -eq $rootFile){$rootFile=$file}
        foreach($line in [regex]::Matches($file.Text,'(?m)^[^\r\n]*')){
            $entry=[regex]::Match($line.Value,'^\s*Hostname\s*=\s*(?<Value>[^\r\n]*?)\s*$')
            if($entry.Success){
                if(((-not $AllowMissing) -and [string]::IsNullOrWhiteSpace($entry.Groups['Value'].Value)) -or $entry.Groups['Value'].Value.Contains(',')){throw 'An empty or multi-host Hostname setting requires manual review.'}
                $settings.Add([pscustomobject]@{File=$file;Value=$entry.Groups['Value'].Value;Offset=$line.Index+$entry.Groups['Value'].Index;Length=$entry.Groups['Value'].Length})
            } elseif($line.Value -match '^\s*HostnameItem\s*=\s*\S'){$dynamicHostname=$true}
            elseif($line.Value -match '^\s*Include\s*=\s*(.+?)\s*$'){
                $include=[Environment]::ExpandEnvironmentVariables($Matches[1])
                if(-not [IO.Path]::IsPathRooted($include)){$include=Join-Path ([IO.Path]::GetDirectoryName($root)) $include}
                foreach($included in @(Get-ChildItem -Path $include -File -ErrorAction Stop)){$pending.Enqueue($included.FullName)}
            }
        }
    }
    if($AllowMissing -and $settings.Count -eq 0 -and -not $dynamicHostname){return [pscustomobject]@{File=$rootFile;Value='';Offset=$rootFile.Text.Length;Length=0;Append=$true}}
    if($settings.Count -ne 1 -or ($dynamicHostname -and [string]::IsNullOrWhiteSpace($settings[0].Value))){throw 'A single explicit Zabbix Hostname setting is required; dynamic or multiple settings need manual review.'}
    return $settings[0]
}

function Set-ZabbixDeviceHostname {
    param([Parameter(Mandatory=$true)][string]$CommandLine,[Parameter(Mandatory=$true)][string]$Hostname,[string]$BackupFolder,[switch]$OnlyIfMissing)
    if(-not (Test-CanApply)){throw 'Zabbix hostname repair is disabled outside Apply Fix.'}
    if(-not (Test-ZabbixMonitoringHostname $Hostname)){throw 'The Zabbix monitoring hostname is invalid.'}
    $setting=Get-ZabbixHostnameSetting -CommandLine $CommandLine -AllowMissing:$OnlyIfMissing
    if($setting.Value -ceq $Hostname){return [pscustomobject]@{Changed=$false;BackupPath=$null}}
    if($OnlyIfMissing -and -not [string]::IsNullOrWhiteSpace($setting.Value)){throw 'The Zabbix hostname changed during input; the existing value was preserved.'}
    if($setting.PSObject.Properties['Append'] -and $setting.Append){
        $newline=if($setting.File.Text.Contains("`r`n")){"`r`n"}else{"`n"}
        $text=$setting.File.Text+$newline+'Hostname='+$Hostname+$newline
    }else{$text=$setting.File.Text.Remove($setting.Offset,$setting.Length).Insert($setting.Offset,$Hostname)}
    $service=Get-Service -Name 'Zabbix Agent 2' -ErrorAction Stop
    if($service.Status -ne 'Running'){throw 'The Zabbix service is not running; no hostname configuration was changed.'}
    $change=Write-ThoroughTextChange -Original $setting.File -Text $text -BackupFolder $BackupFolder
    try {
        if((Get-ZabbixConfiguredHostname -CommandLine $CommandLine) -cne $Hostname){throw 'Zabbix hostname readback did not match the entered monitoring hostname.'}
        $service=Get-Service -Name 'Zabbix Agent 2' -ErrorAction Stop
        if($service.Status -ne 'Running'){throw 'The Zabbix service is not running; hostname activation could not be verified.'}
        Restart-Service -Name 'Zabbix Agent 2' -ErrorAction Stop
        (Get-Service -Name 'Zabbix Agent 2' -ErrorAction Stop).WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running,[TimeSpan]::FromSeconds(30))
        if((Get-ZabbixConfiguredHostname -CommandLine $CommandLine) -cne $Hostname){throw 'Zabbix hostname changed during service verification.'}
    } catch {
        $reason=$_.Exception.Message
        try {
            Restore-ThoroughTextChange $change
            $reason+=' Previous Zabbix configuration restored.'
            $service=Get-Service -Name 'Zabbix Agent 2' -ErrorAction Stop
            if($service.Status -eq 'Running'){Restart-Service -Name 'Zabbix Agent 2' -ErrorAction Stop}
            else {Start-Service -Name 'Zabbix Agent 2' -ErrorAction Stop}
            (Get-Service -Name 'Zabbix Agent 2' -ErrorAction Stop).WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running,[TimeSpan]::FromSeconds(30))
        } catch {$reason+=' Zabbix restoration/service state requires manual verification.'}
        throw $reason
    }
    return $change
}

function Get-AuditService {
    param([Parameter(Mandatory = $true)][string]$ServiceName)
    # Escape WQL literals and retrieve only the requested service on each readback.
    $escapedServiceName = $ServiceName.Replace('\', '\\').Replace("'", "\'")
    Write-AuditOperation "Reading service '$ServiceName'..."
    return Get-CimInstance -ClassName Win32_Service -Filter "Name='$escapedServiceName'" -OperationTimeoutSec 30 -ErrorAction Stop |
        Where-Object { $_.Name -eq $ServiceName } | Select-Object -First 1
}

function Get-ServiceRecoverySnapshot {
    param([Parameter(Mandatory=$true)][string]$ServiceName)
    if (-not ('KioskAudit.ServiceRecoverySettings' -as [type])) {
        Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace KioskAudit {
    public sealed class RecoveryPolicySnapshot {
        public UInt32 ResetPeriod;
        public int[] ActionTypes = new int[0];
        public UInt32[] DelaysMs = new UInt32[0];
    }
    public static class ServiceRecoverySettings {
        [StructLayout(LayoutKind.Sequential)]
        private struct FailureActions {
            public UInt32 ResetPeriod;
            public IntPtr RebootMessage;
            public IntPtr Command;
            public UInt32 ActionCount;
            public IntPtr Actions;
        }
        [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern IntPtr OpenSCManager(string machine, string database, UInt32 access);
        [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern IntPtr OpenService(IntPtr manager, string name, UInt32 access);
        [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool QueryServiceConfig2(IntPtr service, UInt32 level, IntPtr buffer, UInt32 length, out UInt32 needed);
        [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool ChangeServiceConfig2(IntPtr service, UInt32 level, ref FailureActions policy);
        [DllImport("advapi32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseServiceHandle(IntPtr handle);

        private static void Validate(RecoveryPolicySnapshot value) {
            if (value == null || value.ActionTypes == null || value.DelaysMs == null || value.ActionTypes.Length != value.DelaysMs.Length)
                throw new InvalidOperationException("Recovery action and timing data could not be verified.");
        }
        private static int ActionAt(RecoveryPolicySnapshot value, int index) {
            return value.ActionTypes.Length == 0 ? 0 : value.ActionTypes[Math.Min(index, value.ActionTypes.Length - 1)];
        }
        private static UInt32 DelayAt(RecoveryPolicySnapshot value, int index) {
            return value.DelaysMs.Length == 0 ? 0U : value.DelaysMs[Math.Min(index, value.DelaysMs.Length - 1)];
        }
        public static bool MatchesActions(RecoveryPolicySnapshot value, bool restartFirstTwo) {
            Validate(value);
            int count = Math.Max(3, value.ActionTypes.Length);
            for (int index = 0; index < count; index++) {
                int expected = restartFirstTwo && index < 2 ? 1 : 0;
                if (ActionAt(value, index) != expected) return false;
            }
            return true;
        }
        public static RecoveryPolicySnapshot WithRequiredActions(RecoveryPolicySnapshot current, bool restartFirstTwo) {
            Validate(current);
            int count = Math.Max(3, current.ActionTypes.Length);
            RecoveryPolicySnapshot result = new RecoveryPolicySnapshot();
            result.ResetPeriod = current.ResetPeriod;
            result.ActionTypes = new int[count];
            result.DelaysMs = new UInt32[count];
            for (int index = 0; index < count; index++) {
                result.ActionTypes[index] = restartFirstTwo && index < 2 ? 1 : 0;
                // Windows repeats the last entry for further failures. Preserve
                // that existing delay when a missing action slot must be added.
                // An absent action array has no configured delay (zero).
                result.DelaysMs[index] = DelayAt(current, index);
            }
            return result;
        }
        public static bool TimingMatches(RecoveryPolicySnapshot before, RecoveryPolicySnapshot after) {
            Validate(before); Validate(after);
            if (before.ResetPeriod != after.ResetPeriod) return false;
            int count = Math.Max(before.DelaysMs.Length, after.DelaysMs.Length);
            for (int index = 0; index < count; index++) {
                if (DelayAt(before, index) != DelayAt(after, index)) return false;
            }
            return true;
        }
        private static IntPtr ReadBuffer(IntPtr service, out FailureActions policy, out UInt32 allocated) {
            UInt32 needed;
            bool first = QueryServiceConfig2(service, 2, IntPtr.Zero, 0, out needed);
            int error = Marshal.GetLastWin32Error();
            if (!first && error != 122) throw new Win32Exception(error);
            if (needed < Marshal.SizeOf(typeof(FailureActions)) || needed > Int32.MaxValue)
                throw new InvalidOperationException("Invalid recovery configuration buffer.");
            IntPtr buffer = Marshal.AllocHGlobal((int)needed);
            allocated = needed;
            try {
                if (!QueryServiceConfig2(service, 2, buffer, allocated, out needed)) throw new Win32Exception(Marshal.GetLastWin32Error());
                policy = (FailureActions)Marshal.PtrToStructure(buffer, typeof(FailureActions));
                return buffer;
            } catch { Marshal.FreeHGlobal(buffer); throw; }
        }
        private static RecoveryPolicySnapshot Snapshot(FailureActions policy, IntPtr buffer, UInt32 allocated) {
            RecoveryPolicySnapshot value = new RecoveryPolicySnapshot();
            value.ResetPeriod = policy.ResetPeriod;
            if (policy.ActionCount == 0) return value;
            long start = buffer.ToInt64(), actions = policy.Actions.ToInt64();
            long bytes = (long)policy.ActionCount * 8;
            if (policy.ActionCount > Int32.MaxValue || policy.Actions == IntPtr.Zero || actions < start || bytes > allocated || actions - start > allocated - bytes)
                throw new InvalidOperationException("Invalid recovery action/timing array.");
            value.ActionTypes = new int[(int)policy.ActionCount];
            value.DelaysMs = new UInt32[(int)policy.ActionCount];
            for (int index = 0; index < value.ActionTypes.Length; index++) {
                value.ActionTypes[index] = Marshal.ReadInt32(policy.Actions, index * 8);
                value.DelaysMs[index] = unchecked((UInt32)Marshal.ReadInt32(policy.Actions, index * 8 + 4));
            }
            return value;
        }
        private static RecoveryPolicySnapshot ReadHandle(IntPtr service) {
            FailureActions policy; UInt32 allocated;
            IntPtr buffer = ReadBuffer(service, out policy, out allocated);
            try { return Snapshot(policy, buffer, allocated); }
            finally { Marshal.FreeHGlobal(buffer); }
        }
        public static RecoveryPolicySnapshot Read(string name) {
            IntPtr manager = IntPtr.Zero, service = IntPtr.Zero;
            try {
                manager = OpenSCManager(null, null, 1);
                if (manager == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
                service = OpenService(manager, name, 1);
                if (service == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
                return ReadHandle(service);
            } finally {
                if (service != IntPtr.Zero) CloseServiceHandle(service);
                if (manager != IntPtr.Zero) CloseServiceHandle(manager);
            }
        }
        public static void SetActions(string name, bool restartFirstTwo) {
            IntPtr manager = IntPtr.Zero, service = IntPtr.Zero, buffer = IntPtr.Zero, actions = IntPtr.Zero;
            try {
                manager = OpenSCManager(null, null, 1);
                if (manager == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
                // Query/change configuration; restart actions also require SERVICE_START.
                service = OpenService(manager, name, restartFirstTwo ? 0x13U : 0x3U);
                if (service == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
                FailureActions policy; UInt32 allocated;
                buffer = ReadBuffer(service, out policy, out allocated);
                RecoveryPolicySnapshot before = Snapshot(policy, buffer, allocated);
                if (MatchesActions(before, restartFirstTwo)) return;
                RecoveryPolicySnapshot desired = WithRequiredActions(before, restartFirstTwo);
                actions = Marshal.AllocHGlobal(checked(desired.ActionTypes.Length * 8));
                for (int index = 0; index < desired.ActionTypes.Length; index++) {
                    Marshal.WriteInt32(actions, index * 8, desired.ActionTypes[index]);
                    Marshal.WriteInt32(actions, index * 8 + 4, unchecked((int)desired.DelaysMs[index]));
                }
                // Preserve the original reset period and every effective delay.
                // Null message/command pointers mean leave those values unchanged.
                policy.ResetPeriod = desired.ResetPeriod;
                policy.RebootMessage = IntPtr.Zero;
                policy.Command = IntPtr.Zero;
                policy.ActionCount = (UInt32)desired.ActionTypes.Length;
                policy.Actions = actions;
                if (!ChangeServiceConfig2(service, 2, ref policy)) throw new Win32Exception(Marshal.GetLastWin32Error());
                RecoveryPolicySnapshot after = ReadHandle(service);
                if (!MatchesActions(after, restartFirstTwo) || !TimingMatches(before, after))
                    throw new InvalidOperationException("Recovery action readback failed or existing timing was not preserved.");
            } finally {
                if (actions != IntPtr.Zero) Marshal.FreeHGlobal(actions);
                if (buffer != IntPtr.Zero) Marshal.FreeHGlobal(buffer);
                if (service != IntPtr.Zero) CloseServiceHandle(service);
                if (manager != IntPtr.Zero) CloseServiceHandle(manager);
            }
        }
    }
}
'@
    }
    [KioskAudit.ServiceRecoverySettings]::Read($ServiceName)
}

function Set-ServiceRecoveryActionPolicy {
    param([Parameter(Mandatory=$true)][string]$ServiceName,[switch]$RestartFirstTwo)
    if (-not (Test-CanApply)) {throw 'Recovery changes are disabled in Audit mode.'}
    [void](Get-ServiceRecoverySnapshot -ServiceName $ServiceName)
    [KioskAudit.ServiceRecoverySettings]::SetActions($ServiceName,[bool]$RestartFirstTwo)
}

function Read-ServiceRecoveryPolicy {
    param([Parameter(Mandatory=$true)][string]$ServiceName)
    $snapshot=Get-ServiceRecoverySnapshot -ServiceName $ServiceName
    [KioskAudit.ServiceRecoverySettings]::MatchesActions($snapshot,$true)
}

function Invoke-ServiceRecoveryRepair {
    param([Parameter(Mandatory=$true)][string]$ServiceName)
    if (-not (Test-CanApply)) {throw 'Recovery changes are disabled in Audit mode.'}
    Set-ServiceRecoveryActionPolicy -ServiceName $ServiceName -RestartFirstTwo
    if (-not (Read-ServiceRecoveryPolicy -ServiceName $ServiceName)) {throw 'Required recovery actions were not verified after Apply.'}
    return $true
}

function Read-ServiceNoActionRecoveryPolicy {
    param([Parameter(Mandatory=$true)][string]$ServiceName)
    $snapshot=Get-ServiceRecoverySnapshot -ServiceName $ServiceName
    [KioskAudit.ServiceRecoverySettings]::MatchesActions($snapshot,$false)
}

function Invoke-ServiceNoActionRecoveryRepair {
    param([Parameter(Mandatory=$true)][string]$ServiceName)
    if (-not (Test-CanApply)) {throw 'Recovery changes are disabled in Audit mode.'}
    Set-ServiceRecoveryActionPolicy -ServiceName $ServiceName
    if (-not (Read-ServiceNoActionRecoveryPolicy -ServiceName $ServiceName)) {throw 'Take No Action recovery was not verified after Apply.'}
    return $true
}

function Get-ServiceRecoveryActionTypes {
    param ([Parameter(Mandatory=$true)][string]$ServiceName)
    if (-not ('KioskAudit.ServiceRecoveryReportReader' -as [type])) {
        Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace KioskAudit {
    public static class ServiceRecoveryReportReader {
        [StructLayout(LayoutKind.Sequential)]
        private struct FailureActions {
            public UInt32 ResetPeriod;
            public IntPtr RebootMessage;
            public IntPtr Command;
            public UInt32 ActionCount;
            public IntPtr Actions;
        }
        [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern IntPtr OpenSCManager(string machine, string database, UInt32 access);
        [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern IntPtr OpenService(IntPtr manager, string name, UInt32 access);
        [DllImport("advapi32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool QueryServiceConfig2(IntPtr service, UInt32 level, IntPtr buffer, UInt32 length, out UInt32 needed);
        [DllImport("advapi32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseServiceHandle(IntPtr handle);
        public static int[] ReadActionTypes(string name) {
            IntPtr manager=IntPtr.Zero, service=IntPtr.Zero, buffer=IntPtr.Zero;
            try {
                manager=OpenSCManager(null,null,1);
                if(manager==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
                service=OpenService(manager,name,1);
                if(service==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
                UInt32 needed;
                bool first=QueryServiceConfig2(service,2,IntPtr.Zero,0,out needed);
                int error=Marshal.GetLastWin32Error();
                if(!first && error!=122) throw new Win32Exception(error);
                if(needed==0 || needed>Int32.MaxValue) throw new InvalidOperationException("Invalid recovery buffer size.");
                buffer=Marshal.AllocHGlobal((int)needed);
                UInt32 allocated=needed;
                if(!QueryServiceConfig2(service,2,buffer,allocated,out needed)) throw new Win32Exception(Marshal.GetLastWin32Error());
                FailureActions policy=(FailureActions)Marshal.PtrToStructure(buffer,typeof(FailureActions));
                if(policy.ActionCount==0) return new int[0];
                long start=buffer.ToInt64(), actions=policy.Actions.ToInt64();
                long bytes=(long)policy.ActionCount*8;
                if(policy.Actions==IntPtr.Zero || actions<start || bytes>allocated || actions-start>allocated-bytes)
                    throw new InvalidOperationException("Invalid recovery action array.");
                int[] result=new int[(int)policy.ActionCount];
                for(int index=0;index<result.Length;index++) result[index]=Marshal.ReadInt32(policy.Actions,index*8);
                return result;
            } finally {
                if(buffer!=IntPtr.Zero) Marshal.FreeHGlobal(buffer);
                if(service!=IntPtr.Zero) CloseServiceHandle(service);
                if(manager!=IntPtr.Zero) CloseServiceHandle(manager);
            }
        }
    }
}
'@
    }
    [KioskAudit.ServiceRecoveryReportReader]::ReadActionTypes($ServiceName)
}

function ConvertFrom-ServiceRecoveryActionTypes {
    param ([AllowEmptyCollection()][int[]]$Types)
    $names=@{ 0='Take No Action'; 1='Restart the service'; 2='Restart the computer'; 3='Run a program' }
    $values=for ($index=0;$index -lt 3;$index++) {
        $action=if ($Types.Count -eq 0) { 0 } else { $Types[[Math]::Min($index,$Types.Count-1)] }
        if ($names.ContainsKey($action)) { $names[$action] } else { 'Unknown action ('+$action+')' }
    }
    if ($Types.Count -gt 3) {
        $subsequent=@(for ($index=2;$index -lt $Types.Count;$index++) {
            $action=$Types[$index]
            if ($names.ContainsKey($action)) { $names[$action] } else { 'Unknown action ('+$action+')' }
        }) | Select-Object -Unique
        $values[2]=$subsequent -join ' / '
    }
    [pscustomobject]@{ First=$values[0]; Second=$values[1]; Subsequent=$values[2]; Verified=(@($Types | Where-Object { $_ -notin @(0,1,2,3) }).Count -eq 0); Error='' }
}

function Get-ServiceRecoveryDetails {
    param ([Parameter(Mandatory=$true)][string]$ServiceName)
    try { ConvertFrom-ServiceRecoveryActionTypes -Types @(Get-ServiceRecoveryActionTypes -ServiceName $ServiceName) }
    catch { [pscustomobject]@{ First='Not verified'; Second='Not verified'; Subsequent='Not verified'; Verified=$false; Error=$_.Exception.Message } }
}

function Invoke-RequiredServiceCheck {
    param([string]$ServiceName, [string]$ItemTitle, [string]$ItemSub, [switch]$DeferConsole)
    $serviceStatus = 'Fail'
    $serviceState = 'Not verified'
    $startupState = 'Not verified'
    $recoveryState = 'Not verified'
    $serviceActions = [System.Collections.Generic.List[string]]::new()
    try {
        $serviceSnapshot = Get-AuditService -ServiceName $ServiceName
        if (-not $serviceSnapshot) { throw 'Service is not installed; install it before retrying.' }
        $serviceState = [string]$serviceSnapshot.State
        $startupState = [string]$serviceSnapshot.StartMode
        if (Test-CanApply) {
            if ($serviceSnapshot.StartMode -ne 'Auto') {
                Set-Service -Name $ServiceName -StartupType Automatic -ErrorAction Stop
                $serviceActions.Add('Startup set to Automatic')
            }
            if ($serviceSnapshot.State -ne 'Running') {
                Start-Service -Name $ServiceName -ErrorAction Stop
                $waitService = Get-Service -Name $ServiceName -ErrorAction Stop
                $waitService.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(30))
                $serviceActions.Add('Service started')
            }
        }
        $serviceSnapshot = Get-AuditService -ServiceName $ServiceName
        if (-not $serviceSnapshot) { throw 'Service disappeared during verification.' }
        $serviceState = [string]$serviceSnapshot.State
        $startupState = [string]$serviceSnapshot.StartMode
        $recoveryValid = Read-ServiceRecoveryPolicy -ServiceName $ServiceName
        if (-not $recoveryValid -and (Test-CanApply)) {
            $recoveryValid = Invoke-ServiceRecoveryRepair -ServiceName $ServiceName
            $serviceActions.Add('Crash recovery configured and verified')
        }
        $serviceSnapshot = Get-AuditService -ServiceName $ServiceName
        if (-not $serviceSnapshot) { throw 'Service disappeared during final verification.' }
        $serviceState = [string]$serviceSnapshot.State
        $startupState = [string]$serviceSnapshot.StartMode
        $recoveryState = if ($recoveryValid) { 'Verified' } else { 'Required restart policy is missing' }
        if ($serviceState -ne 'Running' -or $startupState -ne 'Auto' -or -not $recoveryValid) {
            throw "Required Running / Automatic / restart recovery. Found: $serviceState / $startupState / $recoveryState."
        }
        $serviceStatus = 'Pass'
        if ($serviceActions.Count -eq 0) { $serviceActions.Add('Service settings verified; no changes needed') }
    } catch {
        $serviceActions.Add("Failed: $($_.Exception.Message)")
        if (-not (Test-CanApply)) { $serviceActions.Add('Audit only: no changes made; run apply mode after review') }
        # Preserve truthful current state even when a repair failed halfway through.
        try {
            $failedSnapshot = Get-AuditService -ServiceName $ServiceName
            if ($failedSnapshot) {
                $serviceState = [string]$failedSnapshot.State
                $startupState = [string]$failedSnapshot.StartMode
            }
        } catch { $serviceActions.Add('Current service state could not be refreshed') }
    }
    $recoveryDetails=Get-ServiceRecoveryDetails -ServiceName $ServiceName
    if (-not $recoveryDetails.Verified) {
        $serviceStatus='Fail'
        $serviceActions.Add('Recovery actions not verified: '+$recoveryDetails.Error)
    }
    $findingArguments=@{ ServiceState=$serviceState; StartupType=$startupState; Recovery=$recoveryDetails }
    if ($ItemSub -eq 'Type: Payment Gateway Middleware') { $findingArguments.ServiceName=$ServiceName; $findingArguments.Version='Not verified' }
    $serviceFound=ConvertTo-ServiceFindingHtml @findingArguments
    $serviceShortcut = '<code>services.msc</code>'
    Add-AuditEntry -SectionNumber $sec3Num -SectionTitle $sec3Title -ItemTitle $ItemTitle -ItemSub $ItemSub -Shortcut $serviceShortcut -FoundStateHtml $serviceFound -Status $serviceStatus -ActionTaken ([System.Net.WebUtility]::HtmlEncode(($serviceActions -join '; '))) -DeferConsole:$DeferConsole
    $auditRows[$auditRows.Count-1] | Add-Member -NotePropertyName RecoveryDetails -NotePropertyValue $recoveryDetails
}

function Get-PaymentExecutablePath {
    param ($Service)
    $commandLine = [Environment]::ExpandEnvironmentVariables([string]$Service.PathName).Trim()
    $match = [regex]::Match($commandLine, '^(?:"([^"]+\.exe)"|(.+?\.exe))(?=\s|$)', 'IgnoreCase')
    if (-not $match.Success) { throw "Executable path is not readable for $($Service.Name)." }
    if ($match.Groups[1].Success) { return $match.Groups[1].Value }
    return $match.Groups[2].Value
}

function Get-PaymentExecutableVersion {
    param ($Service)
    $path = Get-PaymentExecutablePath $Service
    $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($path)
    if (-not $info.FileVersion) { throw "Executable version is missing for $($Service.Name)." }
    [version]::new($info.FileMajorPart, $info.FileMinorPart, $info.FileBuildPart, $info.FilePrivatePart)
}

function Get-ThoroughPaymentVersionDetails {
    param ([Parameter(Mandatory = $true)][string]$ExecutablePath)
    $fileVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($ExecutablePath).FileVersion
    if ([string]::IsNullOrWhiteSpace($fileVersion)) { $fileVersion = 'Not detected' }
    $executableFolder = Split-Path $ExecutablePath -Parent
    $packageVersion = $null
    foreach ($versionFile in @(
        (Join-Path $executableFolder 'version.txt'),
        (Join-Path (Split-Path $executableFolder -Parent) 'version.txt')
    )) {
        if (Test-Path -LiteralPath $versionFile -PathType Leaf) {
            $candidate = ([IO.File]::ReadAllText($versionFile)).Trim()
            $parsed = $null
            if ([version]::TryParse($candidate, [ref]$parsed)) { $packageVersion = $candidate; break }
        }
    }
    if ([string]::IsNullOrWhiteSpace($packageVersion)) { $packageVersion = $fileVersion }
    [pscustomobject]@{ Version = $packageVersion; ExecutableFileVersion = $fileVersion }
}

function Remove-ThoroughPaymentJsonComments {
    param ([Parameter(Mandatory = $true)][string]$Text)
    $output = New-Object Text.StringBuilder
    $inString = $false
    $escaped = $false
    $lineComment = $false
    $blockComment = $false
    for ($index = 0; $index -lt $Text.Length; $index++) {
        $character = $Text[$index]
        $next = if ($index + 1 -lt $Text.Length) { $Text[$index + 1] } else { [char]0 }
        if ($lineComment) {
            if ($character -eq "`r" -or $character -eq "`n") { $lineComment = $false; [void]$output.Append($character) }
            continue
        }
        if ($blockComment) {
            if ($character -eq '*' -and $next -eq '/') { $blockComment = $false; $index++; continue }
            if ($character -eq "`r" -or $character -eq "`n") { [void]$output.Append($character) }
            continue
        }
        if ($inString) {
            [void]$output.Append($character)
            if ($escaped) { $escaped = $false; continue }
            if ($character -eq '\') { $escaped = $true; continue }
            if ($character -eq '"') { $inString = $false }
            continue
        }
        if ($character -eq '"') { $inString = $true; [void]$output.Append($character); continue }
        if ($character -eq '/' -and $next -eq '/') { $lineComment = $true; $index++; continue }
        if ($character -eq '/' -and $next -eq '*') { $blockComment = $true; $index++; continue }
        [void]$output.Append($character)
    }
    if ($blockComment) { throw 'appsettings.json contains an unterminated block comment.' }
    $output.ToString()
}

function ConvertFrom-ThoroughPaymentJson {
    param ([Parameter(Mandatory = $true)][string]$Text)
    Remove-ThoroughPaymentJsonComments $Text | ConvertFrom-Json -ErrorAction Stop
}

function Get-ThoroughPaymentConfigValue {
    param ($Object, [Parameter(Mandatory = $true)][string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) {
        foreach ($key in $Object.Keys) { if ([string]$key -ieq $Name) { return $Object[$key] } }
        return $null
    }
    $property = $Object.PSObject.Properties | Where-Object Name -IEQ $Name | Select-Object -First 1
    if ($property) { return $property.Value }
    return $null
}

function Get-ThoroughServiceEndpointRequirements {
    [ordered]@{
        MonitoringServiceBaseUrl='https://msblocks.selise.biz/api/business-kiosk'
        CmsGatewayBaseUrl='https://msblocks.selise.biz/api/business-fnb-gateway'
        OrderServiceBaseUrl='https://msblocks.selise.biz/api/business-fnb-ordermanagement'
    }
}

function Test-ThoroughPaymentServiceV13 {
    param([string]$Version)
    $parsed=$null
    return ([version]::TryParse($Version,[ref]$parsed) -and $parsed.Major -eq 13)
}

function Update-ThoroughServiceEndpointText {
    param([Parameter(Mandatory=$true)][string]$Text)
    # Locate root JSON values without reserializing customer settings or comments.
    $configuration=ConvertFrom-ThoroughPaymentJson $Text
    $tokens=@([regex]::Matches($Text,'"(?:\\.|[^"\\])*"|//[^\r\n]*|/\*[\s\S]*?\*/|[{}\[\]:,]|[^\s{}\[\]:,]+') | Where-Object {$_.Value -notmatch '^/[/\*]'})
    if(-not $tokens.Count -or $tokens[0].Value -ne '{' -or $tokens[-1].Value -ne '}'){throw 'AppSettings must be a JSON object.'}
    $required=Get-ThoroughServiceEndpointRequirements
    $seen=@{};$edits=New-Object 'Collections.Generic.List[object]';$changed=New-Object 'Collections.Generic.List[string]'
    $depth=0;$rootClose=$null;$previous=$null
    for($index=0;$index -lt $tokens.Count;$index++){
        $token=$tokens[$index]
        if($token.Value -in @('{','[')){$depth++;continue}
        if($token.Value -in @('}',']')){
            $depth--
            if($depth -eq 0){$rootClose=$token;$previous=$tokens[$index-1]}
            continue
        }
        if($depth -ne 1 -or $token.Value -notmatch '^"' -or $index+2 -ge $tokens.Count -or $tokens[$index+1].Value -ne ':'){continue}
        $key=ConvertFrom-Json -InputObject $token.Value -ErrorAction Stop
        if(-not $required.Contains($key)){continue}
        if($seen.ContainsKey($key)){throw ('Duplicate AppSettings endpoint requires manual review: '+$key)}
        $seen[$key]=$true
        $valueToken=$tokens[$index+2]
        if($valueToken.Value -notmatch '^"' -and $valueToken.Value -ne 'null'){throw ('AppSettings endpoint must be a string or null: '+$key)}
        $actual=[string](Get-ThoroughPaymentConfigValue $configuration $key)
        if($actual.Trim() -cne $required[$key]){
            $edits.Add([pscustomobject]@{Offset=$valueToken.Index;Length=$valueToken.Length;Replacement=($required[$key] | ConvertTo-Json -Compress)})
            $changed.Add($key)
        }
    }
    $missing=@($required.Keys | Where-Object {-not $seen.ContainsKey($_)})
    if($missing.Count){
        $newline=if($Text.Contains("`r`n")){"`r`n"}else{"`n"}
        $lines=@(foreach($key in $missing){'  "'+$key+'": '+($required[$key] | ConvertTo-Json -Compress);$changed.Add($key)})
        if($previous.Value -notin @('{',',')){$edits.Add([pscustomobject]@{Offset=$previous.Index+$previous.Length;Length=0;Replacement=','})}
        $edits.Add([pscustomobject]@{Offset=$rootClose.Index;Length=0;Replacement=($newline+($lines -join (','+$newline))+$newline)})
    }
    $candidate=$Text
    foreach($edit in @($edits | Sort-Object Offset -Descending)){$candidate=$candidate.Remove($edit.Offset,$edit.Length).Insert($edit.Offset,$edit.Replacement)}
    $verified=ConvertFrom-ThoroughPaymentJson $candidate
    foreach($key in $required.Keys){if([string](Get-ThoroughPaymentConfigValue $verified $key) -cne $required[$key] -and $changed.Contains($key)){throw ('AppSettings candidate verification failed: '+$key)}}
    [pscustomobject]@{Text=$candidate;ChangedKeys=$changed.ToArray()}
}

function Set-ThoroughServiceEndpoints {
    param([Parameter(Mandatory=$true)][string]$Path,[string]$BackupFolder)
    if(-not (Test-CanApply)){throw 'AppSettings endpoint repair is disabled outside Apply Fix.'}
    $original=Read-ThoroughTextFile $Path
    $candidate=Update-ThoroughServiceEndpointText $original.Text
    if(-not $candidate.ChangedKeys.Count){return [pscustomobject]@{Changed=$false;ChangedKeys=@();BackupPath=$null}}
    $change=Write-ThoroughTextChange -Original $original -Text $candidate.Text -BackupFolder $BackupFolder
    try {
        $verified=ConvertFrom-ThoroughPaymentJson ([IO.File]::ReadAllText($Path))
        $required=Get-ThoroughServiceEndpointRequirements
        foreach($key in $required.Keys){if(([string](Get-ThoroughPaymentConfigValue $verified $key)).Trim() -cne $required[$key]){throw ('AppSettings endpoint readback failed: '+$key)}}
    } catch {
        $reason=$_.Exception.Message
        try {Restore-ThoroughTextChange $change;$reason+=' Previous AppSettings restored.'} catch {$reason+=' AppSettings restoration requires manual verification.'}
        throw $reason
    }
    [pscustomobject]@{Changed=$true;ChangedKeys=@($candidate.ChangedKeys);BackupPath=$change.BackupPath}
}

function Find-ThoroughPaymentConfigValues {
    param ($Object, [Parameter(Mandatory = $true)][string]$Name, [int]$Depth = 0)
    if ($null -eq $Object -or $Depth -gt 20 -or $Object -is [string] -or $Object -is [ValueType]) { return }
    if ($Object -is [Collections.IDictionary]) {
        foreach ($key in $Object.Keys) {
            if ([string]$key -ieq $Name) { Write-Output $Object[$key] }
            Find-ThoroughPaymentConfigValues $Object[$key] $Name ($Depth + 1)
        }
        return
    }
    if ($Object -is [Collections.IEnumerable]) {
        foreach ($item in $Object) { Find-ThoroughPaymentConfigValues $item $Name ($Depth + 1) }
        return
    }
    foreach ($property in $Object.PSObject.Properties) {
        if ($property.Name -ieq $Name) { Write-Output $property.Value }
        Find-ThoroughPaymentConfigValues $property.Value $Name ($Depth + 1)
    }
}

function Format-ThoroughPaymentAuditValue {
    param ($Value)
    if ($null -eq $Value) { return 'Not configured' }
    if ($Value -is [string] -and $Value.Length -eq 0) { return '(empty)' }
    if ($Value -is [bool]) { return $Value.ToString() }
    return [string]$Value
}

function Add-ThoroughPaymentTerminalLines {
    param (
        [Parameter(Mandatory = $true)][Collections.Generic.List[string]]$Lines,
        [Parameter(Mandatory = $true)][string]$Label,
        $Terminals,
        [Parameter(Mandatory = $true)][string[]]$Fields
    )
    $items = @($Terminals)
    if ($items.Count -eq 0 -or $null -eq $items[0]) {
        $Lines.Add("  ${Label}: Not configured")
        return
    }
    for ($index = 0; $index -lt $items.Count; $index++) {
        foreach ($field in $Fields) {
            $value = Get-ThoroughPaymentConfigValue $items[$index] $field
            $Lines.Add(("  {0} {1} {2}: {3}" -f $Label, ($index + 1), $field, (Format-ThoroughPaymentAuditValue $value)))
        }
    }
}

function Get-ThoroughPaymentConfigurationAuditLines {
    param (
        [Parameter(Mandatory = $true)]$Configuration,
        [Parameter(Mandatory = $true)][string]$ServiceName,
        [Parameter(Mandatory = $true)][string]$ConfigurationPath,
        [string]$ServiceVersion
    )
    $lines = New-Object 'Collections.Generic.List[string]'
    $provider = ([string](Get-ThoroughPaymentConfigValue $Configuration 'PaymentService')).Trim().ToUpperInvariant()
    $providerDisplay = if ([string]::IsNullOrWhiteSpace($provider)) { 'Not configured' } else { $provider }
    $lines.Add('AppSettings File:')
    $lines.Add('  Payment Service: ' + $ServiceName)
    $lines.Add('  File Path: ' + $ConfigurationPath)
    $lines.Add('  PaymentService: ' + $providerDisplay)

    $paymentConfiguration = Get-ThoroughPaymentConfigValue $Configuration 'PaymentConfiguration'
    $lines.Add('PaymentConfiguration:')
    switch ($provider) {
        'PRINT' {
            $lines.Add('  Terminal Sections: Ignored for PRINT')
        }
        'SIX' {
            $lines.Add('  SixTerminals:')
            Add-ThoroughPaymentTerminalLines $lines 'SixTerminal' (Get-ThoroughPaymentConfigValue $paymentConfiguration 'SixTerminals') @('KioskId', 'TerminalId', 'Currency', 'LogDirectory', 'IsDeferredInitiation')
        }
        { $_ -in @('NETS', 'NEXIDE') } {
            $lines.Add('  NetsTerminals:')
            $terminals = Get-ThoroughPaymentConfigValue $paymentConfiguration 'NetsTerminals'
            Add-ThoroughPaymentTerminalLines $lines 'NetsTerminal' $terminals @('PosId', 'KioskId', 'TerminalIPAddress', 'TerminalId', 'Currency', 'Language', 'IsSetupEnabled')
        }
        default {
            $lines.Add('  Terminal Sections: Not configured')
        }
    }

    $scheduleConfiguration = Get-ThoroughPaymentConfigValue $Configuration 'ScheduleConfiguration'
    $nestedSchedules = Get-ThoroughPaymentConfigValue $scheduleConfiguration 'Schedules'
    $schedules = if ($null -ne $nestedSchedules) { @($nestedSchedules) } else { @($scheduleConfiguration) }
    $kioskPrintSchedules = @($schedules | Where-Object { [string](Get-ThoroughPaymentConfigValue $_ 'Provider') -ieq 'KitchenTicketPrint' })
    if ($kioskPrintSchedules.Count -eq 0) {
        $lines.Add('WebApp Printer:')
        foreach ($field in @('Provider', 'BranchUUID', 'IsKioskPrintingEnabled', 'IsEnabled')) { $lines.Add("  ${field}: Not configured") }
    } else {
        for ($index = 0; $index -lt $kioskPrintSchedules.Count; $index++) {
            $label = if ($kioskPrintSchedules.Count -eq 1) { 'WebApp Printer:' } else { 'WebApp Printer {0}:' -f ($index + 1) }
            $lines.Add($label)
            foreach ($field in @('Provider', 'BranchUUID', 'IsKioskPrintingEnabled', 'IsEnabled')) {
                $lines.Add("  ${field}: " + (Format-ThoroughPaymentAuditValue (Get-ThoroughPaymentConfigValue $kioskPrintSchedules[$index] $field)))
            }
        }
    }
    if($provider -in @('SIX','NETS','NEXIDE')){
        $payoutSchedules=@(Get-ThoroughPayoutSchedules -Schedules $schedules -Provider $provider)
        if($payoutSchedules.Count -eq 0){
            $lines.Add(('Cron Job - '+$(if($provider -eq 'SIX'){'SIX Terminal'}else{'NETS Terminal'})+':'))
            foreach($field in @('Provider','IsEnabled')){$lines.Add("  ${field}: Not configured")}
        }else{
            for($index=0;$index -lt $payoutSchedules.Count;$index++){
                $label='Cron Job - '+$(if($provider -eq 'SIX'){'SIX Terminal'}else{'NETS Terminal'})+':'
                $lines.Add($label)
                foreach($field in @('Provider','IsEnabled')){$lines.Add("  ${field}: "+(Format-ThoroughPaymentAuditValue (Get-ThoroughPaymentConfigValue $payoutSchedules[$index] $field)))}
            }
        }
    }
    $printConfiguration = Get-ThoroughPaymentConfigValue $Configuration 'Print'
    $lines.Add('Print:')
    $lines.Add('  Kitchen Printer: ' + (Format-ThoroughPaymentAuditValue (Get-ThoroughPaymentConfigValue $printConfiguration 'PrinterName')))
    $lines.Add('  Kiosk/POS Printer: ' + (Format-ThoroughPaymentAuditValue (Get-ThoroughPaymentConfigValue $printConfiguration 'KioskPrinterName')))
    if(Test-ThoroughPaymentServiceV13 $ServiceVersion){
        $lines.Add('  Disable Chinese Mode: ' + (Format-ThoroughPaymentAuditValue (Get-ThoroughPaymentConfigValue $printConfiguration 'KioskPrinterDisableChineseMode')))
    }
    $lines.Add('Service Endpoints:')
    foreach ($endpoint in @('MonitoringServiceBaseUrl', 'CmsGatewayBaseUrl', 'OrderServiceBaseUrl')) {
        $lines.Add("  ${endpoint}: " + (Format-ThoroughPaymentAuditValue (Get-ThoroughPaymentConfigValue $Configuration $endpoint)))
    }
    return $lines.ToArray()
}

function Select-PaymentPrimary {
    param ([object[]]$Services)
    $candidates = @($Services | Where-Object { $_.State -eq 'Running' })
    if ($candidates.Count -eq 0) { $candidates = @($Services) }
    if ($candidates.Count -eq 1) { return $candidates[0] }
    $ranked = @($candidates | ForEach-Object {
        [pscustomobject]@{ Service = $_; Version = Get-PaymentExecutableVersion $_ }
    } | Sort-Object Version -Descending)
    if ($ranked.Count -eq 0) { throw 'No payment service found.' }
    if ($ranked[0].Version -eq $ranked[1].Version) { throw 'Multiple payment services have the same latest executable version; primary selection requires review.' }
    $ranked[0].Service
}

function Find-KioskPaymentServices {
    param ([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Services)

    $expectedServices = @($Services | Where-Object {
        $script:KioskClientSettings.PreferredServiceNames -contains [string]$_.Name -or
        ($script:KioskClientSettings.PreferredServiceNamePattern -and [string]$_.Name -match $script:KioskClientSettings.PreferredServiceNamePattern)
    })
    $runningExpectedServices = @($expectedServices | Where-Object { $_.State -eq 'Running' })
    if ($runningExpectedServices.Count -gt 0) { return $expectedServices }

    $runningFallbackServices = @($Services | Where-Object {
        $_.State -eq 'Running' -and (
            $_.PathName -match 'Kiosk Payment Middleware\.exe' -or
            $_.Name -match '^AspPayment' -or
            $_.DisplayName -match 'Payment\s*Middleware|AspPayment'
        )
    })
    if ($runningFallbackServices.Count -gt 0) { return $runningFallbackServices }

    return $expectedServices
}

function Invoke-LegacyPaymentServiceCheck {
    param (
        [Parameter(Mandatory=$true)]$LegacyService,
        [Parameter(Mandatory=$true)][string]$PrimaryServiceName,
        [Parameter(Mandatory=$true)][bool]$PrimaryVerified
    )
    $serviceName=[string]$LegacyService.Name
    $status='Fail'
    $state='Not verified'
    $startup='Not verified'
    $action='Legacy service was not verified'
    $legacyChanges=New-Object 'Collections.Generic.List[string]'
    try {
        if ($serviceName -ieq $PrimaryServiceName) { throw 'Primary service cannot be handled as a legacy service.' }
        $snapshot=Get-AuditService -ServiceName $serviceName
        if (-not $snapshot) { throw 'Legacy service is missing.' }
        $state=[string]$snapshot.State
        $startup=[string]$snapshot.StartMode
        # Complete read-only recovery preflight before changing this service.
        $noAction=Read-ServiceNoActionRecoveryPolicy -ServiceName $serviceName
        if (Test-CanApply) {
            if (-not $PrimaryVerified) { throw 'Primary service verification failed; secondary service preserved.' }
            $primary=Get-AuditService -ServiceName $PrimaryServiceName
            if (-not $primary -or $primary.State -ne 'Running' -or $primary.StartMode -ne 'Auto' -or -not (Read-ServiceRecoveryPolicy -ServiceName $PrimaryServiceName)) {
                throw 'Primary service settings no longer pass verification; secondary service preserved.'
            }
            # Prevent automatic restart before stopping an older payment service.
            if (-not $noAction) { $noAction=Invoke-ServiceNoActionRecoveryRepair -ServiceName $serviceName; $legacyChanges.Add('Recovery actions set to Take No Action') }
            if (-not $noAction) { throw 'Take No Action recovery could not be verified; remaining changes skipped.' }
            if ($startup -ne 'Manual') { Set-Service -Name $serviceName -StartupType Manual -ErrorAction Stop; $legacyChanges.Add('Startup set to Manual') }
            if ($state -ne 'Stopped') {
                Stop-Service -Name $serviceName -ErrorAction Stop
                $legacyChanges.Add('Service stop requested')
                $waitService=Get-Service -Name $serviceName -ErrorAction Stop
                $waitService.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped,[TimeSpan]::FromSeconds(30))
            }
        }
        $snapshot=Get-AuditService -ServiceName $serviceName
        if (-not $snapshot) { throw 'Legacy service disappeared during verification.' }
        $state=[string]$snapshot.State
        $startup=[string]$snapshot.StartMode
        $noAction=Read-ServiceNoActionRecoveryPolicy -ServiceName $serviceName
        if ($state -ne 'Stopped' -or $startup -ne 'Manual' -or -not $noAction) { throw 'Stopped / Manual with first, second and subsequent failures set to Take No Action is required.' }
        $status='Offline'
        $action=if($legacyChanges.Count){($legacyChanges -join '; ')+'; readback verified'}else{'No change needed; verified Stopped / Manual; all recovery actions: Take No Action'}
        if (-not (Test-CanApply)) { $action+='; Audit only: no changes made' }
    } catch { $action=($legacyChanges -join '; '); if($action){$action+='; '}; $action+='Failed: '+$_.Exception.Message }
    # Read back actual state after any partial failure; never substitute expected values.
    try {
        $snapshot=Get-AuditService -ServiceName $serviceName
        if ($snapshot) { $state=[string]$snapshot.State; $startup=[string]$snapshot.StartMode }
        else { $state='Missing'; $startup='Not verified'; $status='Fail' }
    } catch { $state='Not verified'; $startup='Not verified'; $status='Fail'; $action+='; current service state unreadable' }
    $recovery=Get-ServiceRecoveryDetails -ServiceName $serviceName
    if (-not $recovery.Verified -or $recovery.First -ne 'Take No Action' -or $recovery.Second -ne 'Take No Action' -or $recovery.Subsequent -ne 'Take No Action' -or $state -ne 'Stopped' -or $startup -ne 'Manual') {
        $status='Fail'
        if ($action -notlike 'Failed:*') { $action+='; final service/recovery readback did not meet the requirements' }
    }
    $found=ConvertTo-ServiceFindingHtml -ServiceState $state -StartupType $startup -Recovery $recovery
    Add-AuditEntry -SectionNumber $sec3Num -SectionTitle $sec3Title -ItemTitle "$serviceName (Legacy)" -ItemSub 'Type: Old Payment Service' -Shortcut '<code>services.msc</code>' -FoundStateHtml $found -Status $status -ActionTaken ([Net.WebUtility]::HtmlEncode($action))
}

function Read-PaymentTaskScriptText {
    param([string]$Path,[string]$WorkingDirectory)
    $pathValue=$Path.Trim('"')
    if($pathValue -match '[%$]' -or $pathValue.StartsWith('\\')){throw 'Task script path is dynamic or remote.'}
    if(-not [IO.Path]::IsPathRooted($pathValue)){
        if(-not [IO.Path]::IsPathRooted($WorkingDirectory) -or $WorkingDirectory.StartsWith('\\') -or $WorkingDirectory -match '[%$]'){throw 'Task script working directory is not a verified local path.'}
        $pathValue=Join-Path $WorkingDirectory $pathValue
    }
    if($pathValue -notmatch '^[A-Za-z]:\\'){throw 'Task script is not on a local Windows drive.'}
    $file=Get-Item -LiteralPath $pathValue -ErrorAction Stop
    if($file.PSIsContainer -or $file.Length -gt 262144){throw 'Task script is unavailable or exceeds the inspection limit.'}
    [IO.File]::ReadAllText($file.FullName)
}

function Get-PaymentTaskLiteral {
    param($Expression,[Collections.IDictionary]$Variables)
    if($Expression -is [Management.Automation.Language.StringConstantExpressionAst]){return [string]$Expression.Value}
    if($Expression -is [Management.Automation.Language.ExpandableStringExpressionAst] -and $Expression.NestedExpressions.Count -eq 0){return [string]$Expression.Value}
    if($Expression -is [Management.Automation.Language.VariableExpressionAst] -and $Variables.Contains($Expression.VariablePath.UserPath)){return [string]$Variables[$Expression.VariablePath.UserPath]}
    throw 'Task service target is not a verified literal value.'
}

function Get-PaymentTaskPowerShellOperations {
    param([string]$Text,[int]$Depth=0)
    if($Depth -gt 2 -or $Text.Length -gt 262144){throw 'Task action exceeds the inspection limit.'}
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tokens,[ref]$errors)
    if($errors.Count -or $ast.ParamBlock -or $ast.BeginBlock -or $ast.ProcessBlock -or $ast.DynamicParamBlock){throw 'Task action syntax or parameters require manual verification.'}
    $variables=@{}
    foreach($statement in $ast.EndBlock.Statements){
        if($statement -is [Management.Automation.Language.AssignmentStatementAst]){
            if($statement.Operator.ToString() -ne 'Equals' -or $statement.Left -isnot [Management.Automation.Language.VariableExpressionAst]){throw 'Dynamic task variable assignment requires manual verification.'}
            $right=$statement.Right
            if($right -is [Management.Automation.Language.PipelineAst] -and $right.PipelineElements.Count -eq 1){$right=$right.PipelineElements[0]}
            if($right -isnot [Management.Automation.Language.CommandExpressionAst]){throw 'Task variable assignment is not static.'}
            $variables[$statement.Left.VariablePath.UserPath]=Get-PaymentTaskLiteral $right.Expression $variables
            continue
        }
        if($statement -isnot [Management.Automation.Language.PipelineAst] -or $statement.PipelineElements.Count -ne 1){throw 'Conditional or indirect task action requires manual verification.'}
        $command=$statement.PipelineElements[0]
        if($command -isnot [Management.Automation.Language.CommandAst]){throw 'Task action is not a verified service command.'}
        $elements=$command.CommandElements
        if($command.InvocationOperator.ToString() -eq 'Ampersand' -and $elements.Count -eq 1 -and $elements[0] -is [Management.Automation.Language.ScriptBlockExpressionAst]){
            Get-PaymentTaskPowerShellOperations -Text $elements[0].ScriptBlock.Extent.Text.Trim().TrimStart('{').TrimEnd('}') -Depth ($Depth+1)
            continue
        }
        $name=$command.GetCommandName() -replace '^Microsoft\.PowerShell\.Management\\',''
        if($name -in @('Write-Host','Write-Output','Write-Verbose','Start-Sleep')){continue}
        if($name -notin @('Restart-Service','Stop-Service','Start-Service')){throw 'Unsupported task command requires manual verification.'}
        $target=$null
        for($index=1;$index -lt $elements.Count;$index++){
            $element=$elements[$index]
            if($element -is [Management.Automation.Language.CommandParameterAst]){
                if($element.ParameterName -in @('Force','PassThru')){continue}
                if($element.ParameterName -notin @('Name','ErrorAction')){throw 'Unsupported service command parameter.'}
                $argument=$element.Argument
                if($null -eq $argument){$index++;if($index -ge $elements.Count){throw 'Service parameter has no value.'};$argument=$elements[$index]}
                $value=Get-PaymentTaskLiteral $argument $variables
                if($element.ParameterName -eq 'Name'){if($null -ne $target){throw 'Service target is ambiguous.'};$target=$value}
            }else{
                if($null -ne $target){throw 'Multiple service targets require manual verification.'}
                $target=Get-PaymentTaskLiteral $element $variables
            }
        }
        if([string]::IsNullOrWhiteSpace($target) -or $target.IndexOfAny([char[]]'*?[]') -ge 0){throw 'Task service target is missing or contains a wildcard.'}
        [pscustomobject]@{Operation=($name -replace '-Service$','').ToLowerInvariant();Target=$target}
    }
}

function Get-PaymentTaskBatchOperations {
    param([string]$Text)
    foreach($line in @($Text -split '\r?\n|&&')){
        $line=$line.Trim().TrimStart('@')
        if(-not $line -or $line -match '^(?i:rem(?:\s|$)|::|echo\s+off$|timeout\s+/t\s+\d+(?:\s+/nobreak)?$)'){continue}
        if(($line -replace '"[^"]*"','') -match '[&|<>()^]'){throw 'Batch action contains an unsupported shell operator.'}
        $parts=ConvertFrom-KioskEdgeArguments $line
        if($parts.Count -lt 3 -or [IO.Path]::GetFileName($parts[0]) -notin @('net','net.exe','sc','sc.exe') -or $parts[1] -notin @('stop','start')){throw 'Batch action is conditional or unsupported; please check manually.'}
        if($parts.Count -gt 3 -and ($parts.Count -ne 4 -or $parts[3] -ne '/y')){throw 'Batch action contains unsupported service arguments.'}
        if($parts[2] -match '[%$*?\[\]]'){throw 'Batch service target is dynamic.'}
        [pscustomobject]@{Operation=$parts[1].ToLowerInvariant();Target=$parts[2]}
    }
}

function Get-PaymentRestartTaskAction {
    param($Action,[string]$ServiceName)
    $execute=[string](Get-ThoroughPaymentConfigValue $Action 'Execute')
    $arguments=[string](Get-ThoroughPaymentConfigValue $Action 'Arguments')
    $workingDirectory=[string](Get-ThoroughPaymentConfigValue $Action 'WorkingDirectory')
    $summary=($execute+' '+$arguments).Trim()
    $operations=@();$verified=$false;$reason=''
    try{
        $program=[IO.Path]::GetFileName($execute.Trim('"'))
        if($program -in @('powershell','powershell.exe','pwsh','pwsh.exe')){
            $parts=ConvertFrom-KioskEdgeArguments $arguments
            $modeIndex=-1
            for($index=0;$index -lt $parts.Count;$index++){if($parts[$index] -in @('-Command','-c','-File','-f','-EncodedCommand','-enc')){$modeIndex=$index;break}}
            if($modeIndex -lt 0 -or $modeIndex+1 -ge $parts.Count){throw 'PowerShell task action has no readable command or script.'}
            $mode=$parts[$modeIndex];$tail=@($parts | Select-Object -Skip ($modeIndex+1))
            if($mode -in @('-File','-f')){
                if($tail.Count -ne 1){throw 'Parameterized task script requires manual verification.'}
                $code=Read-PaymentTaskScriptText $tail[0] $workingDirectory
            }elseif($mode -in @('-EncodedCommand','-enc')){
                if($tail.Count -ne 1 -or $tail[0].Length -gt 349528){throw 'Encoded task action requires manual verification.'}
                $code=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($tail[0]))
            }else{$code=$tail -join ' '}
            $operations=@(Get-PaymentTaskPowerShellOperations $code)
        }elseif($program -in @('cmd','cmd.exe')){
            $match=[regex]::Match($arguments,'(?is)^\s*(?:(?:/d|/s)\s+)*/c\s+(.+)$')
            if(-not $match.Success){throw 'Command task action has no supported /c command.'}
            $code=$match.Groups[1].Value.Trim()
            if($code.StartsWith('""') -and $code.EndsWith('""')){$code=$code.Substring(1,$code.Length-2)}
            $fileMatch=[regex]::Match($code,'(?is)^(?:"([^"\r\n]+\.(?:bat|cmd))"|([^\s"]+\.(?:bat|cmd)))$')
            if($fileMatch.Success){$scriptPath=if($fileMatch.Groups[1].Success){$fileMatch.Groups[1].Value}else{$fileMatch.Groups[2].Value};$code=Read-PaymentTaskScriptText $scriptPath $workingDirectory}
            elseif($code.StartsWith('"') -and $code.EndsWith('"')){$code=$code.Substring(1,$code.Length-2)}
            $operations=@(Get-PaymentTaskBatchOperations $code)
        }elseif([IO.Path]::GetExtension($program) -in @('.bat','.cmd')){
            if(-not [string]::IsNullOrWhiteSpace($arguments)){throw 'Parameterized batch action requires manual verification.'}
            $operations=@(Get-PaymentTaskBatchOperations (Read-PaymentTaskScriptText $execute $workingDirectory))
        }elseif($program -in @('net','net.exe','sc','sc.exe')){
            $operations=@(Get-PaymentTaskBatchOperations ($program+' '+$arguments))
        }else{throw 'Task action type requires manual verification.'}
        $verified=$true
    }catch{$reason=$_.Exception.Message;$operations=@()}
    [pscustomobject]@{Summary=$summary;Operations=$operations;Verified=$verified;Reason=$reason;ReferencesService=($summary.IndexOf($ServiceName,[StringComparison]::OrdinalIgnoreCase) -ge 0)}
}

function Get-PaymentRestartTaskSchedule {
    param($Task)
    $details=New-Object 'Collections.Generic.List[string]'
    $active=0;$unknown=$false
    $triggers=@(Get-ThoroughPaymentConfigValue $Task 'Triggers' | Where-Object {$null -ne $_})
    foreach($trigger in $triggers){
        $class=Get-ThoroughPaymentConfigValue $trigger 'CimClass'
        $type=[string](Get-ThoroughPaymentConfigValue $class 'CimClassName')
        if(-not $type){$type='Trigger'}else{$type=$type -replace '^MSFT_Task','' -replace 'Trigger$',''}
        $enabled=Get-ThoroughPaymentConfigValue $trigger 'Enabled'
        $start=[string](Get-ThoroughPaymentConfigValue $trigger 'StartBoundary')
        $end=[string](Get-ThoroughPaymentConfigValue $trigger 'EndBoundary')
        $parts=New-Object 'Collections.Generic.List[string]';$parts.Add($type)
        if($enabled -isnot [bool]){$unknown=$true;$parts.Add('Enabled: Not verified')}else{$parts.Add('Enabled: '+$enabled)}
        if($start){$parts.Add('Start: '+$start)}
        if($end){$parts.Add('End: '+$end)}
        foreach($field in @('DaysInterval','WeeksInterval','DaysOfWeek','DaysOfMonth','MonthsOfYear','Delay','RandomDelay')){
            $value=Get-ThoroughPaymentConfigValue $trigger $field
            if($null -ne $value -and [string]$value -ne ''){$parts.Add($field+': '+$value)}
        }
        $repetition=Get-ThoroughPaymentConfigValue $trigger 'Repetition'
        foreach($field in @('Interval','Duration')){$value=[string](Get-ThoroughPaymentConfigValue $repetition $field);if($value){$parts.Add('Repetition '+$field+': '+$value)}}
        $usable=$enabled -is [bool] -and $enabled
        if($end){$endTime=[DateTimeOffset]::MinValue;if(-not [DateTimeOffset]::TryParse($end,[ref]$endTime)){$unknown=$true;$usable=$false}elseif($endTime -le [DateTimeOffset]::Now){$usable=$false;$parts.Add('Expired')}}
        if($start){
            $startTime=[DateTimeOffset]::MinValue
            if(-not [DateTimeOffset]::TryParse($start,[ref]$startTime)){$unknown=$true;$usable=$false}
            elseif($type -eq 'Time' -and $startTime -le [DateTimeOffset]::Now){
                $interval=[string](Get-ThoroughPaymentConfigValue $repetition 'Interval')
                $duration=[string](Get-ThoroughPaymentConfigValue $repetition 'Duration')
                if(-not $interval){$usable=$false;$parts.Add('Elapsed one-time trigger')}
                elseif($duration){try{if($startTime.Add([Xml.XmlConvert]::ToTimeSpan($duration)) -le [DateTimeOffset]::Now){$usable=$false;$parts.Add('Repetition period expired')}}catch{$unknown=$true;$usable=$false}}
            }
        }
        if($usable){$active++}
        $details.Add(($parts -join '; '))
    }
    [pscustomobject]@{Configured=($triggers.Count -gt 0);Enabled=($active -gt 0);Unknown=$unknown;Details=($details -join ' | ')}
}

function New-PaymentRestartTaskDefinition {
    param($ServiceObj, [string]$ServiceName)
    $definition = $ServiceObj.NewTask(0)
    $definition.RegistrationInfo.Description = "Restart $ServiceName daily at 04:15 AM."
    $definition.Principal.UserId = 'NT AUTHORITY\SYSTEM'
    $definition.Principal.LogonType = 5
    $definition.Principal.RunLevel = 1
    $trigger = $definition.Triggers.Create(2)
    $trigger.StartBoundary = (Get-Date -Hour 4 -Minute 15 -Second 0).ToString("yyyy-MM-dd'T'HH:mm:ss")
    $trigger.DaysInterval = 1
    $trigger.Enabled = $true
    $action = $definition.Actions.Create(0)
    $action.Path = 'powershell.exe'
    $action.Arguments = '-NoProfile -ExecutionPolicy Bypass -Command "Restart-Service -Name ''' + $ServiceName + ''' -Force"'
    $definition.Settings.Enabled = $true
    $definition.Settings.StartWhenAvailable = $true
    $definition.Settings.DisallowStartIfOnBatteries = $false
    $definition.Settings.StopIfGoingOnBatteries = $false
    $definition.Settings.ExecutionTimeLimit = 'PT10M'
    return $definition
}

function Register-MissingPaymentRestartTask {
    param([string]$ServiceName)
    if (-not (Test-CanApply)) { throw 'Task creation requires approved Apply mode.' }
    if ([string]::IsNullOrWhiteSpace($ServiceName)) { throw 'Selected Payment Service name is unavailable.' }
    $taskName = "Restart $ServiceName"
    $serviceObj = New-Object -ComObject 'Schedule.Service'
    $serviceObj.Connect()
    $rootFolder = $serviceObj.GetFolder('\')
    $definition = New-PaymentRestartTaskDefinition $serviceObj $ServiceName
    [void]$rootFolder.RegisterTaskDefinition($taskName, $definition, 6, $null, $null, 5, $null)
}

function Get-PaymentRestartTaskRecords {
    param([string]$ServiceName)
    $tasks = @(Get-ScheduledTask -ErrorAction Stop)
    $records = New-Object 'Collections.Generic.List[object]'
    foreach($task in $tasks){
        $name=[string](Get-ThoroughPaymentConfigValue $task 'TaskName')
        $path=[string](Get-ThoroughPaymentConfigValue $task 'TaskPath')
        $actions=@(Get-ThoroughPaymentConfigValue $task 'Actions' | Where-Object {$null -ne $_})
        $summaries=New-Object 'Collections.Generic.List[string]'
        $operations=New-Object 'Collections.Generic.List[object]'
        $actionVerified=$actions.Count -gt 0
        $nameHint=$name -match '(?i)restart' -and ($name -match '(?i)payment' -or $name.IndexOf($ServiceName,[StringComparison]::OrdinalIgnoreCase) -ge 0)
        $referencesService=$false
        foreach($action in $actions){
            $evidence=Get-PaymentRestartTaskAction $action $ServiceName
            $summaries.Add($evidence.Summary)
            if(-not $evidence.Verified){$actionVerified=$false}
            if($evidence.ReferencesService){$referencesService=$true}
            foreach($operation in $evidence.Operations){$operations.Add($operation)}
        }
        $restartTargets=@{};$stopped=@{}
        foreach($operation in $operations){
            if($operation.Operation -eq 'restart' -or ($operation.Operation -eq 'start' -and $stopped.ContainsKey($operation.Target))){$restartTargets[$operation.Target]=$true;[void]$stopped.Remove($operation.Target)}
            if($operation.Operation -eq 'stop'){$stopped[$operation.Target]=$true;[void]$restartTargets.Remove($operation.Target)}
        }
        $restarts=@($restartTargets.Keys)
        $targetVerified=$actionVerified -and $restarts -icontains $ServiceName
        $related=$nameHint -or (-not $actionVerified -and $referencesService)
        if(-not $targetVerified -and -not $related){continue}
        $enabled=Get-ThoroughPaymentConfigValue (Get-ThoroughPaymentConfigValue $task 'Settings') 'Enabled'
        $state=[string](Get-ThoroughPaymentConfigValue $task 'State')
        $enabledKnown=$enabled -is [bool] -and $state -in @('Ready','Running','Queued','Disabled')
        $taskEnabled=$enabledKnown -and $enabled -and $state -ne 'Disabled'
        $schedule=Get-PaymentRestartTaskSchedule $task
        $fields=[ordered]@{'Task Name'=$name;'Task Location'=$path;'Task'='Available';'Task State'=$state;'Task Enabled'=$(if(-not $enabledKnown){'Not verified'}elseif($taskEnabled){'Yes'}else{'No'});'Restart Target'=$(if($targetVerified){$ServiceName}elseif($actionVerified -and $restarts.Count){$restarts -join ', '}else{'Not verified. Please check manually.'});'Schedule'=$(if($schedule.Configured){'Configured'}else{'Missing'});'Schedule Enabled'=$(if($schedule.Unknown){'Not verified'}elseif($schedule.Enabled){'Yes'}else{'No'});'Trigger Details'=$(if($schedule.Details){$schedule.Details}else{'No trigger configured'});'Action'=($summaries -join ' | ')}
        $historyVerified=$true
        try{
            $info=Get-ScheduledTaskInfo -TaskName $name -TaskPath $path -ErrorAction Stop
            foreach($field in @('LastRunTime','NextRunTime','LastTaskResult')){
                $value=Get-ThoroughPaymentConfigValue $info $field
                $label=switch($field){'LastRunTime'{'Last Run'};'NextRunTime'{'Next Run'};default{'Last Result'}}
                $fields[$label]=if($null -eq $value){'Not recorded'}elseif($value -is [datetime] -and $value.Year -le 1900){'Not recorded'}elseif($value -is [datetime]){$value.ToString('dd-MMM-yyyy HH:mm:ss',[Globalization.CultureInfo]::InvariantCulture)}else{[string]$value}
            }
        }catch{$historyVerified=$false;$fields['Run History']='Not verified. Please check Task Scheduler manually.'}
        $records.Add([pscustomobject]@{Html=(ConvertTo-ReportDefinitionHtml $fields);Passed=($targetVerified -and $taskEnabled -and $schedule.Configured -and $schedule.Enabled -and -not $schedule.Unknown -and $historyVerified)})
    }
    return $records
}

function Invoke-PaymentRestartTaskCheck {
    param([string]$PaymentProvider,[string]$ServiceName)
    if(([string]$PaymentProvider).Trim().ToUpperInvariant() -notin @('NETS','NEXIDE')){return}
    $expected=ConvertTo-ReportDefinitionHtml ([ordered]@{'Task'='Available';'Task Enabled'='Yes';'Restart Target'=$ServiceName;'Schedule'='Configured';'Schedule Enabled'='Yes'})
    $status='Fail';$note='Task not verified. Please check Task Scheduler manually.'
    $parts=New-Object 'Collections.Generic.List[string]'
    $created=$false;$creationFailure=$null
    try{
        if([string]::IsNullOrWhiteSpace($ServiceName)){throw 'Selected Payment Service name is unavailable.'}
        $records = @(Get-PaymentRestartTaskRecords $ServiceName)
        if($records.Count -eq 0 -and (Test-CanApply)){
            try {
                Register-MissingPaymentRestartTask -ServiceName $ServiceName
                $created = $true
                $records = @(Get-PaymentRestartTaskRecords $ServiceName)
            } catch {
                $creationFailure = $_.Exception.Message
            }
        }
        if($records.Count -eq 0){
            $parts.Add((ConvertTo-ReportDefinitionHtml ([ordered]@{'Task'='Not found';'Restart Target'=$ServiceName;'Verification'='No verified restart task found. Please check Task Scheduler manually.'})))
            $note = if ($creationFailure) { 'Task creation failed: ' + $creationFailure + ' Manual action required.' } else { 'Restart task not found. Please configure or verify it manually.' }
        }else{
            for($index=0;$index -lt $records.Count;$index++){
                if($records.Count -gt 1){$parts.Add('<div class="config-item-title">[Task '+($index+1)+']</div>')}
                $parts.Add($records[$index].Html)
            }
            if(@($records | Where-Object {-not $_.Passed}).Count -eq 0){
                $status = if ($created) { 'Remediated' } else { 'Pass' }
                $note = if ($created) { 'Created missing Payment Service restart task; readback verified. Daily schedule at 04:15 AM configured. The task was not executed.' } else { 'Existing restart task and schedule verified. No task was changed or executed.' }
            }
        }
    }catch{
        $parts.Add((ConvertTo-ReportDefinitionHtml ([ordered]@{'Task'='Not verified. Please check Task Scheduler manually.';'Restart Target'=$ServiceName})))
        $note='Task Scheduler check not verified: '+$_.Exception.Message
    }
    $itemSub = if ($created -or (Test-CanApply)) { 'Type: Missing-only scheduled task repair' } else { 'Type: Read-only Scheduled Task Verification' }
    Add-AuditEntry -SectionNumber 3 -SectionTitle 'Core Background Services' -ItemTitle 'Payment Service Restart Task' -ItemSub $itemSub -Shortcut (New-ReportCommand @('taskschd.msc')) -FoundStateHtml ($parts -join '') -Status $status -ActionTaken ([Net.WebUtility]::HtmlEncode($note))
    $auditRows[$auditRows.Count-1] | Add-Member -NotePropertyName ExpectedHtml -NotePropertyValue $expected
}

function Get-ZabbixConfiguredHostname {
    param ([string]$CommandLine, [string]$DefaultConfigurationPath = (Join-Path $env:ProgramFiles 'Zabbix Agent 2\zabbix_agent2.conf'))
    $configMatch = [regex]::Match($CommandLine, '(?:^|\s)(?:-c|--config)(?:\s+|=)(?:"([^"]+)"|(\S+))')
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return 'Not verified (service path unavailable)' }
    if (-not $configMatch.Success) {
        if (-not (Test-Path -LiteralPath $DefaultConfigurationPath -PathType Leaf)) { return 'Not verified (service config path not specified; default file missing)' }
        $path=$DefaultConfigurationPath
    } else { $path = if ($configMatch.Groups[1].Success) { $configMatch.Groups[1].Value } else { $configMatch.Groups[2].Value } }
    $path = [Environment]::ExpandEnvironmentVariables($path)
    if (-not [IO.Path]::IsPathRooted($path)) { return 'Not verified (relative service config path)' }
    $pending = [Collections.Generic.Queue[string]]::new()
    $pending.Enqueue($path)
    $visited = @{}
    $hostnames = [Collections.Generic.List[string]]::new()
    $items = [Collections.Generic.List[string]]::new()
    while ($pending.Count) {
        $file = $pending.Dequeue()
        if ($visited.ContainsKey($file)) { continue }
        if ($visited.Count -ge 100) { throw 'Too many Zabbix include files.' }
        $visited[$file] = $true
        foreach ($line in (Get-Content -LiteralPath $file -ErrorAction Stop)) {
            if ($line -match '^\s*Hostname\s*=\s*(.*?)\s*$') { $hostnames.Add($Matches[1]) }
            elseif ($line -match '^\s*HostnameItem\s*=\s*(.*?)\s*$' -and $Matches[1]) { $items.Add($Matches[1]) }
            elseif ($line -match '^\s*Include\s*=\s*(.*?)\s*$' -and $Matches[1]) {
                $include = $Matches[1]
                if (-not [IO.Path]::IsPathRooted($include)) { $include = Join-Path (Split-Path $path -Parent) $include }
                foreach ($entry in (Get-ChildItem -Path $include -File -ErrorAction Stop)) { $pending.Enqueue($entry.FullName) }
            }
        }
    }
    if ($hostnames.Count -eq 1 -and -not [string]::IsNullOrWhiteSpace($hostnames[0])) { return $hostnames[0] }
    if ($hostnames.Count -eq 1) { return 'Not verified (empty Hostname setting)' }
    if ($hostnames.Count -gt 1) { return 'Not verified (multiple Hostname settings)' }
    if ($items.Count) { return 'Dynamic / not verified (HostnameItem=' + ($items -join ', ') + ')' }
    return 'Dynamic / not verified (default system.hostname)'
}

function New-ZabbixInstallCommand {
    param([Parameter(Mandatory=$true)][string]$Hostname)
    if ([string]::IsNullOrWhiteSpace($Hostname) -or $Hostname -in @('Not detected','Not verified') -or $Hostname -match '["\x00\r\n]') {
        throw 'Zabbix hostname is unavailable or invalid. Installation was not started.'
    }
    $hostnameData=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Hostname))
    $template=@'
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.ServiceProcess
$stage=$null
try {
    $hostname=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__HOSTNAME_DATA__'))
    $temporaryRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    $stage=Join-Path $temporaryRoot ('ThoroughCheck-Zabbix-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($stage)
    $zipPath=Join-Path $stage 'zabbix.zip'
    $packageRoot=Join-Path $stage 'package'
    Invoke-WebRequest -UseBasicParsing -Uri 'https://cdn-ito.selisesme.com/omk/zabbix/zabbix.zip' -OutFile $zipPath -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive=[IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $destination=[IO.Path]::GetFullPath($packageRoot).TrimEnd('\')+'\'
        foreach ($entry in $archive.Entries) {
            $target=[IO.Path]::GetFullPath((Join-Path $packageRoot $entry.FullName))
            if (-not $target.StartsWith($destination,[StringComparison]::OrdinalIgnoreCase)) {throw 'Installer archive contains a path outside its package folder.'}
        }
    } finally {$archive.Dispose()}
    Expand-Archive -LiteralPath $zipPath -DestinationPath $packageRoot -ErrorAction Stop
    $installers=@(Get-ChildItem -LiteralPath $packageRoot -Filter 'zabbix-msi-install.ps1' -File -Recurse -ErrorAction Stop)
    if ($installers.Count -ne 1) {throw 'A single Zabbix PowerShell installer could not be identified.'}
    $installer=$installers[0].FullName
    $msi=Join-Path $installers[0].DirectoryName 'zabbix.msi'
    $monitoring=Join-Path $installers[0].DirectoryName 'omk-monitoring.conf'
    foreach ($file in @($msi,$monitoring)) {if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {throw ('Installer file missing: '+$file)}}
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($installer,[ref]$tokens,[ref]$errors)
    if ($errors.Count -or 'Hostname' -notin @($ast.ParamBlock.Parameters | ForEach-Object {$_.Name.VariablePath.UserPath})) {throw 'Installer does not support the required Hostname parameter.'}
    $global:LASTEXITCODE=0
    & $installer -MsiPath $msi -Hostname $hostname -ScriptSource $monitoring -LogPath (Join-Path $stage 'install.log')
    if ($LASTEXITCODE -ne 0) {throw ('Zabbix installer returned exit code '+$LASTEXITCODE)}
    $service=Get-Service -Name 'Zabbix Agent 2' -ErrorAction Stop
    # The MSI starts the agent before its monitoring include file is copied.
    # Restart only this newly installed agent so that it loads that file.
    if ($service.Status -eq 'Running') {Restart-Service -Name 'Zabbix Agent 2' -ErrorAction Stop}
    else {Start-Service -Name 'Zabbix Agent 2' -ErrorAction Stop}
    (Get-Service -Name 'Zabbix Agent 2' -ErrorAction Stop).WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running,[TimeSpan]::FromSeconds(30))
    $resolvedStage=[IO.Path]::GetFullPath($stage)
    if (-not $resolvedStage.StartsWith($temporaryRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolvedStage) -notmatch '^ThoroughCheck-Zabbix-[0-9a-f]{32}$') {throw 'Temporary installer cleanup target could not be verified.'}
    Remove-Item -LiteralPath $resolvedStage -Recurse -Force -ErrorAction Stop
    exit 0
} catch {
    [Console]::Error.WriteLine(('Zabbix installation failed: '+$_.Exception.Message+'. Installer files/log retained at: '+$stage))
    exit 1
}
'@
    return $template.Replace('__HOSTNAME_DATA__',$hostnameData)
}

function Invoke-ZabbixAgentInstall {
    param([Parameter(Mandatory=$true)][string]$Hostname)
    if (-not (Test-CanApply)) {throw 'Zabbix installation is disabled in Audit mode.'}
    $command=New-ZabbixInstallCommand -Hostname $Hostname
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $process=Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded" -Wait -NoNewWindow -PassThru -ErrorAction Stop
    if ($process.ExitCode -ne 0) {throw ('Zabbix installer failed (exit code '+$process.ExitCode+'). Review installer output.')}
}

function Test-FirewallPortMatch {
    param ($Ports, [int]$Port)
    foreach ($entry in @($Ports)) {
        foreach ($piece in ([string]$entry -split ',')) {
            $piece = $piece.Trim()
            # Broad application rules do not satisfy an explicit required port.
            if ($piece -eq [string]$Port) { return $true }
            if ($piece -match '^(\d+)\s*-\s*(\d+)$' -and $Port -ge [int]$matches[1] -and $Port -le [int]$matches[2]) { return $true }
        }
    }
    return $false
}

function Test-FirewallAny {
    param ($Value, [switch]$AllowEmpty)
    $items = @($Value)
    if ($items.Count -eq 0 -or [string]::IsNullOrWhiteSpace(($items -join ''))) { return [bool]$AllowEmpty }
    return ($items.Count -eq 1 -and ([string]$items[0]).Trim() -in @('Any', '*'))
}

function Get-KioskFirewallState {
    param ([int]$Port = 5009)
    # Presence check only: enabled inbound TCP Allow with an explicit port/range.
    # Any-port rules are ignored, including those restricted to unrelated apps.
    # No connectivity, profile, address-scope or block-rule audit is performed here.
    $filters = @(Get-NetFirewallPortFilter -PolicyStore ActiveStore -ErrorAction Stop | Where-Object {
        [string]$_.Protocol -in @('TCP', '6') -and (Test-FirewallPortMatch -Ports $_.LocalPort -Port $Port)
    })
    $observations=New-Object 'Collections.Generic.List[object]'
    $allowObserved=[Collections.Generic.List[object]]::new()
    foreach ($filter in $filters) {
        $rules = @(Get-NetFirewallRule -AssociatedNetFirewallPortFilter $filter -PolicyStore ActiveStore -ErrorAction Stop)
        $allowRules=@($rules | Where-Object {
            [string]$_.Enabled -eq 'True' -and [string]$_.Direction -eq 'Inbound' -and [string]$_.Action -eq 'Allow'
        })
        if ($allowRules.Count -gt 0) {
            $matching=@($allowRules | ForEach-Object { ConvertTo-FirewallRuleObservation -Filter $filter -Rule $_ })
            foreach($entry in $matching){$allowObserved.Add($entry)}
            continue
        }
        foreach($rule in $rules){$observations.Add((ConvertTo-FirewallRuleObservation -Filter $filter -Rule $rule))}
    }
    if($allowObserved.Count){
        $specific=@($allowObserved|Where-Object {-not (Test-FirewallAny $_.Ports)})
        $selected=if($specific.Count){$specific}else{$allowObserved.ToArray()}
        return [pscustomobject]@{Verified=$true;HasAllow=$true;Details='Available';Observations=@($selected)}
    }
    [pscustomobject]@{ Verified = $false; HasAllow = $false; Details = 'Missing'; Observations=$observations.ToArray() }
}

function Invoke-KioskFirewallPortCheck {
    param ([Parameter(Mandatory = $true)][int]$Port, [Parameter(Mandatory = $true)][string]$RulePurpose)
    $fwStatus = 'Fail'
    $fwFound = 'Not verified'
    $fwAction = 'Firewall state was not verified'
    $firewallState = $null
    try {
        $firewallState = Get-KioskFirewallState -Port $Port
        $fwAction = 'Firewall rule verified; no changes needed'
        if (-not $firewallState.HasAllow) {
            if (Test-CanApply) {
                $managedRuleName = "SELISE-Kiosk-TCP-$Port-Inbound"
                $managedLookupErrors=@()
                $managedRule = @(Get-NetFirewallRule -Name $managedRuleName -PolicyStore PersistentStore -ErrorAction SilentlyContinue -ErrorVariable managedLookupErrors)
                if(@($managedLookupErrors | Where-Object {$_.CategoryInfo.Category -ne [Management.Automation.ErrorCategory]::ObjectNotFound}).Count){throw 'Managed firewall rule lookup could not be verified; no changes were made.'}
                if ($managedRule.Count -eq 0) {
                    New-NetFirewallRule -Name $managedRuleName -DisplayName "Allow Port $Port Inbound ($RulePurpose)" -PolicyStore PersistentStore -Direction Inbound -LocalPort $Port -Protocol TCP -Action Allow -Enabled True -Profile Any -ErrorAction Stop | Out-Null
                    $fwAction = "Created inbound TCP $Port rule"
                } else {
                    if($managedRule.Count -ne 1){throw 'The managed firewall rule is ambiguous; no repair was started.'}
                    $managedFilter=@(Get-NetFirewallPortFilter -AssociatedNetFirewallRule $managedRule[0] -ErrorAction Stop)
                    if($managedFilter.Count -ne 1){throw 'The managed firewall port filter is ambiguous; no repair was started.'}
                    $before=[pscustomobject]@{Direction=$managedRule[0].Direction;Action=$managedRule[0].Action;Enabled=$managedRule[0].Enabled;Profile=$managedRule[0].Profile;Protocol=$managedFilter[0].Protocol;Ports=@($managedFilter[0].LocalPort)}
                    if(@('Direction','Action','Enabled','Profile','Protocol' | Where-Object {[string]::IsNullOrWhiteSpace([string]$before.$_)}).Count -or [string]::IsNullOrWhiteSpace(($before.Ports -join ','))){throw 'The managed firewall rule could not be snapshotted; no repair was started.'}
                    try {
                        # Narrow the port before enabling an Allow rule.
                        $managedFilter[0] | Set-NetFirewallPortFilter -Protocol TCP -LocalPort $Port -ErrorAction Stop | Out-Null
                        Set-NetFirewallRule -Name $managedRuleName -PolicyStore PersistentStore -Direction Inbound -Action Allow -Enabled True -Profile Any -ErrorAction Stop | Out-Null
                        $firewallState=Get-KioskFirewallState -Port $Port
                        if(-not $firewallState.Verified){throw 'The repaired explicit port rule was not verified in the effective firewall policy.'}
                        $fwAction = "Updated inbound TCP $Port rule"
                    } catch {
                        $reason=$_.Exception.Message
                        try {
                            # Keep it disabled while restoring its original port scope.
                            Set-NetFirewallRule -Name $managedRuleName -PolicyStore PersistentStore -Enabled False -ErrorAction Stop | Out-Null
                            $restoreRule=Get-NetFirewallRule -Name $managedRuleName -PolicyStore PersistentStore -ErrorAction Stop
                            Get-NetFirewallPortFilter -AssociatedNetFirewallRule $restoreRule -ErrorAction Stop |
                                Set-NetFirewallPortFilter -Protocol $before.Protocol -LocalPort $before.Ports -ErrorAction Stop | Out-Null
                            Set-NetFirewallRule -Name $managedRuleName -PolicyStore PersistentStore -Direction $before.Direction -Action $before.Action -Enabled $before.Enabled -Profile $before.Profile -ErrorAction Stop | Out-Null
                            $restored=@(Get-NetFirewallRule -Name $managedRuleName -PolicyStore PersistentStore -ErrorAction Stop)
                            if($restored.Count -ne 1){throw 'Managed firewall rollback rule identity could not be verified.'}
                            $restoredFilter=@(Get-NetFirewallPortFilter -AssociatedNetFirewallRule $restored[0] -ErrorAction Stop)
                            if($restored.Count -ne 1 -or $restoredFilter.Count -ne 1 -or [string]$restored[0].Direction -ne [string]$before.Direction -or [string]$restored[0].Action -ne [string]$before.Action -or [string]$restored[0].Enabled -ne [string]$before.Enabled -or [string]$restored[0].Profile -ne [string]$before.Profile -or [string]$restoredFilter[0].Protocol -ne [string]$before.Protocol -or (@($restoredFilter[0].LocalPort | Sort-Object) -join ',') -ne (@($before.Ports | Sort-Object) -join ',')){throw 'Managed firewall rollback readback failed.'}
                            $reason+=' Original managed firewall rule restored.'
                        } catch {$reason+=' Managed firewall restoration requires manual verification.'}
                        throw $reason
                    }
                }
                $firewallState = Get-KioskFirewallState -Port $Port
                if ($firewallState.Verified) { $fwAction += '; readback verified' }
            } else {
                $fwAction = "Audit only: an inbound TCP $Port allow rule is required"
            }
        }
        $fwFound = if ($firewallState.HasAllow) { 'Available' } else { 'Missing' }
        if ($firewallState.Verified) { $fwStatus = 'Pass' }
        elseif (Test-CanApply) { $fwAction = "TCP $Port Allow rule could not be verified after configuration." }
    } catch { $fwAction = "Firewall verification or creation failed: $($_.Exception.Message)" }
    $entryCount=if($null -ne $auditRows){$auditRows.Count}else{-1}
    Add-AuditEntry -SectionNumber $sec4Num -SectionTitle $sec4Title -ItemTitle "Inbound TCP $Port Rule" -ItemSub 'Type: Firewall Rule Presence' -Shortcut '<code>wf.msc</code>' -FoundStateHtml ([System.Net.WebUtility]::HtmlEncode($fwFound)) -Status $fwStatus -ActionTaken ([System.Net.WebUtility]::HtmlEncode($fwAction))
    if($null -ne $auditRows -and $auditRows.Count -eq $entryCount+1){
        $row=$auditRows[$auditRows.Count-1]
        $readVerified=$null -ne $firewallState -and $fwFound -ne 'Not verified'
        $snapshot=if($readVerified -and $firewallState.PSObject.Properties['Observations']){@($firewallState.Observations)}else{@()}
        $row | Add-Member -NotePropertyName FirewallPort -NotePropertyValue $Port
        $row | Add-Member -NotePropertyName FirewallReadVerified -NotePropertyValue $readVerified
        $row | Add-Member -NotePropertyName FirewallObservations -NotePropertyValue $snapshot
    }
}

function Get-NmapExecutable {
    $command = Get-Command -Name nmap.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command -and (Test-Path -LiteralPath $command.Source -PathType Leaf)) { return $command.Source }
    foreach ($location in @('C:\Program Files (x86)\Nmap\nmap.exe', 'C:\Program Files\Nmap\nmap.exe')) {
        if (Test-Path -LiteralPath $location -PathType Leaf) { return $location }
    }
    # Honor a custom destination without reinstalling an existing installation.
    foreach ($keyPath in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Nmap', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Nmap')) {
        if (Test-Path -LiteralPath $keyPath) {
            $entry = Get-ItemProperty -LiteralPath $keyPath -ErrorAction Stop
            if ($entry.InstallLocation) {
                $location = Join-Path $entry.InstallLocation 'nmap.exe'
                if (Test-Path -LiteralPath $location -PathType Leaf) { return $location }
            }
        }
    }
    return $null
}

function Get-NmapVersion {
    param ([Parameter(Mandatory)][string]$Path)
    # --version has no scan targets and makes no network scan requests.
    $versionOutput = (& $Path --version 2>&1 | Out-String).Trim()
    $versionExitCode = $LASTEXITCODE
    if ($versionExitCode -ne 0) { throw "Nmap --version failed with exit code $versionExitCode." }
    if ($versionOutput -notmatch '(?m)^Nmap version\s+(\S+)') { throw 'Nmap returned no recognizable version information.' }
    [PSCustomObject]@{ Version = $matches[1]; Output = $versionOutput }
}

function Get-LocalNmapInstaller {
    param ([Parameter(Mandatory)][AllowEmptyString()][string]$ScriptDirectory)
    if ([string]::IsNullOrWhiteSpace($ScriptDirectory)) { throw 'Cannot resolve the script directory for the local Nmap package.' }
    $packageDirectory = Join-Path $ScriptDirectory 'Packages\Nmap'
    $manifestPath = Join-Path $packageDirectory 'NmapPackage.psd1'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Local Nmap package is missing. Run Save-NmapPackage.ps1 in '$packageDirectory' on the preparation PC, then copy that folder with the scripts."
    }
    $package = Import-PowerShellDataFile -LiteralPath $manifestPath -ErrorAction Stop
    if ($package.Version -notmatch '^\d+(\.\d+)+$' -or $package.FileName -cne ('nmap-{0}-setup.exe' -f $package.Version) -or $package.SHA256 -notmatch '^[A-Fa-f0-9]{64}$') {
        throw 'The local Nmap package manifest is invalid; prepare the package again.'
    }
    $installerPath = Join-Path $packageDirectory $package.FileName
    if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) { throw "Local Nmap installer is missing: $installerPath" }
    $actualHash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256 -ErrorAction Stop).Hash
    if ($actualHash -ne $package.SHA256) { throw 'Local Nmap installer checksum mismatch; installation was not started. Prepare the package again.' }
    return $installerPath
}
