# Shared kiosk accounts functions. Dot-sourced into the engine's scope.

function Get-ThoroughFinalKioskAccountRow {
    param($Row,[string]$ConfirmedUser)
    if($Row.ItemTitle -ne 'KIOSK Account'){return $Row}
    Get-ThoroughFinalAccountRow -Row $Row -ConfirmedUser $ConfirmedUser -UnverifiedLabel 'Kiosk user not verified'
}

function Get-ThoroughFinalAccountRow {
    param($Row,[string]$ConfirmedUser,[string]$UnverifiedLabel)
    # Project recorded data only. Do not select users, query Windows or change
    # the original account observations used by Audit and Fix.
    $copy=$Row | Select-Object *
    $view=Get-AccountReportView $Row
    $selected=@()
    if(-not [string]::IsNullOrWhiteSpace($ConfirmedUser) -and $ConfirmedUser -notin @('Not provided','Not verified','Not detected')){
        $selected=@($view.Records | Where-Object {$_.AccountName -ieq $ConfirmedUser})
    }
    $metadata=@()
    if($selected.Count -eq 1){
        $copy.FoundStateHtml=$selected[0].FindingsHtml
        if($Row.PSObject.Properties['AccountResults']){$metadata=@($Row.AccountResults | Where-Object {$null -ne $_ -and $_.PSObject.Properties['AccountName'] -and $_.AccountName -ieq $selected[0].AccountName})}
        if($metadata.Count -eq 1){
            $own=$metadata[0] | Select-Object *
            if(-not $own.PSObject.Properties['Action']){$own | Add-Member NoteProperty Action 'Account-specific results are unavailable.'}
            $copy.Status=if($own.PSObject.Properties['Status']){[string]$own.Status}else{'Fail'}
            $copy.ActionTaken=[Net.WebUtility]::HtmlEncode([string]$own.Action)
            $metadata=@($own)
        }else{
            $copy.ActionTaken='Account-specific results are unavailable.'
        }
    }else{
        $copy.Status='Fail'
        $copy.ActionTaken=[Net.WebUtility]::HtmlEncode($UnverifiedLabel+'. A single confirmed account is required.')
        $unknown=[ordered]@{'Account Name'=$UnverifiedLabel;'Account Privilege'='Not verified';'Account Status'='Not verified';'Password Never Expires'='Not verified'}
        if($Row.ItemTitle -notmatch '^Administrative Account'){$unknown['User Cannot Change Password']='Not verified'}
        $copy.FoundStateHtml=ConvertTo-ReportDefinitionHtml $unknown
    }
    $copy | Add-Member NoteProperty AccountResults @($metadata) -Force
    return $copy
}

function Test-ThoroughFinalAccountReadback {
    param($Row,[string]$Name)
    if(-not $Row.PSObject.Properties['AccountResults']){return $false}
    $own=@($Row.AccountResults | Where-Object {$null -ne $_ -and $_.PSObject.Properties['AccountName'] -and $_.AccountName -ieq $Name})
    if($own.Count -ne 1 -or -not $own[0].PSObject.Properties['Status'] -or [string]::IsNullOrWhiteSpace([string]$own[0].Status) -or $own[0].Status -in @('Unknown','Bypass') -or -not $own[0].PSObject.Properties['Action']){return $false}
    $note=[string]$own[0].Action
    if([string]::IsNullOrWhiteSpace($note) -or $note -match '(?i)\breadback\b[^.;]*(?:fail|could not|not verified|unavailable)|(?:fail|could not)[^.;]*\breadback\b|\bnot reverified\b|account-specific results are unavailable'){return $false}
    if($own[0].Status -notin @('Pass','Online','Remediated') -and $note -match '(?i)reject|exception|could not|failed|not verified'){return $false}
    return $true
}

function Get-ThoroughFinalAdministrativeAccountRow {
    param($Row,[bool]$AfterApply)
    $view=Get-AccountReportView $Row
    $eligible=@(foreach($record in $view.Records){
        $values=Get-ThoroughReportHighlightFields $record.FindingsHtml
        if($values['Account Status'] -ne 'Active' -or $values['Account Privilege'] -ne 'Administrator'){continue}
        if(@($view.Records | Where-Object {$_.AccountName -ieq $record.AccountName}).Count -ne 1){continue}
        if($AfterApply -and -not (Test-ThoroughFinalAccountReadback -Row $Row -Name $record.AccountName)){continue}
        $record
    })
    $selected=@($eligible | Sort-Object @{Expression={switch($_.AccountName){'Admin'{0};'Administrator'{1};default{2}}}},AccountName | Select-Object -First 1)
    $name=if($selected.Count){$selected[0].AccountName}else{''}
    Get-ThoroughFinalAccountRow -Row $Row -ConfirmedUser $name -UnverifiedLabel 'Administrative account not verified'
}

function Get-ThoroughFixAccountBeforeView {
    param($Row,$BeforeView,$AfterView,[string]$RequirementHtml)
    if(-not $BeforeView -or -not @($BeforeView.Records).Count){return $null}
    $records=[Collections.Generic.List[object]]::new()
    foreach($record in $BeforeView.Records){$records.Add($record)}
    if($AfterView){
        foreach($record in $AfterView.Records){
            if(-not @($records|Where-Object {$_.AccountName -ieq $record.AccountName}).Count){$records.Add($record)}
        }
    }
    $metadata=if($Row.PSObject.Properties['AccountResults']){@($Row.AccountResults)}else{@()}
    $findings=[Collections.Generic.List[string]]::new()
    $applied=[Collections.Generic.List[string]]::new()
    $names=[Collections.Generic.List[string]]::new()
    for($index=0;$index -lt $records.Count;$index++){
        $account=$records[$index]
        $own=@($metadata|Where-Object {$_ -and $_.PSObject.Properties['AccountName'] -and $_.AccountName -ieq $account.AccountName})
        $result=$Row|Select-Object *
        $uncertain=$own.Count -ne 1 -or -not $own[0].PSObject.Properties['Status'] -or [string]::IsNullOrWhiteSpace([string]$own[0].Status)
        if($uncertain){$result.Status='Unknown';$result.ActionTaken='Account-specific results were not verified. Manual action required.'}
        else {$result.Status=[string]$own[0].Status;$result.ActionTaken=[Net.WebUtility]::HtmlEncode([string]$own[0].Action)}
        $state=Format-ThoroughReportFieldLabels ([string]$account.FindingsHtml)
        $state=Format-ThoroughReportFindingHighlights -Row $Row -FindingsHtml $state -RequirementHtml $RequirementHtml
        $action=Get-ThoroughReportAppliedHtml -Row $result -FindingsHtml $state
        $keep=Test-ThoroughFixReportRow -Row $result -FindingsHtml $state -AppliedHtml $action -AfterApply $true
        if(-not $uncertain -and $own[0].PSObject.Properties['AccountPolicyChanged'] -and $own[0].AccountPolicyChanged -eq $true){$keep=$true}
        if(-not $keep){continue}
        $findingRecord=$result|Select-Object *
        $findingRecord.Status=if($state -match 'finding-(?:mismatch|unverified)'){'Fail'}else{'Pass'}
        $findingRecord.ActionTaken=''
        $body=Format-ThoroughFixFindings -Row $findingRecord -FindingsHtml $state -RequirementHtml $RequirementHtml -AfterApply $false -RecordScope $true
        $heading=Format-ThoroughReportFieldLabels ([string]$account.HeadingHtml)
        if(-not $heading -and $records.Count -gt 1){$heading='<div class="config-item-title">Account '+($index+1).ToString('D2')+'</div>'}
        if($uncertain){$action='<div class="applied-result"><strong>Not Verified</strong><div>Account-specific results are unavailable. Please check manually.</div></div>'}
        $findings.Add($heading+$body);$applied.Add($heading+$action);$names.Add([string]$account.AccountName)
    }
    [pscustomobject]@{RetainedCount=$findings.Count;FindingsHtml=($findings -join '<hr class="block-divider">');AppliedHtml=($applied -join '<hr class="block-divider">');CommandHtml=(ConvertTo-ReportCommandBoxes (New-AccountReportCommand -AccountNames $names.ToArray()))}
}

function Get-LocalAccount {
    param ([string]$UserName)
    # Enumerate with terminating errors: access/command errors must not look like a missing account.
    @(Get-LocalUser -ErrorAction Stop) | Where-Object { $_.Name -ieq $UserName } | Select-Object -First 1
}

function Get-LocalAccountProperties {
    param ([Parameter(Mandatory = $true)][string]$UserName)
    $entry = Open-ThoroughLocalAccount $UserName
    $rawFlags = $entry.InvokeGet('UserFlags')
    $expired = $entry.InvokeGet('PasswordExpired')
    $locked = $entry.InvokeGet('IsAccountLocked')
    if ($null -eq $rawFlags -or $null -eq $expired -or $null -eq $locked) {
        throw "Account properties could not all be read for $UserName."
    }
    $flags = [int]$rawFlags
    [pscustomobject]@{
        PasswordNeverExpires = [bool]($flags -band 0x10000)
        UserCannotChangePassword = [bool]($flags -band 0x40)
        MustChangePassword = [bool]$expired
        Disabled = [bool]($flags -band 0x2)
        LockedOut = [bool]$locked
    }
}

function Get-LocalAdministratorSidSet {
    $administrators = Get-LocalGroup -SID 'S-1-5-32-544' -ErrorAction Stop
    $set = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($member in @(Get-LocalGroupMember -Group $administrators -ErrorAction Stop)) {
        if ($member.SID) { [void]$set.Add([string]$member.SID.Value) }
    }
    return ,$set
}

function Get-LocalAccountPrivilege {
    param ([Parameter(Mandatory = $true)]$Account, [Parameter(Mandatory = $true)]$AdministratorSids)
    if ($AdministratorSids.Contains([string]$Account.SID.Value)) { return 'Local Administrator' }
    return 'Standard Local User'
}

function Get-AdministrativeLocalAccounts {
    $administratorSids = Get-LocalAdministratorSidSet
    $accounts = @(Get-LocalUser -ErrorAction Stop | Where-Object {
        $_.Name -ieq 'Admin' -or $_.Name -ieq 'Administrator' -or ($_.Enabled -and $administratorSids.Contains([string]$_.SID.Value))
    } | Sort-Object -Property @{Expression={if ($_.Name -ieq 'Admin') {0} elseif ($_.Name -ieq 'Administrator') {1} else {2}}},Name)
    $activeAccounts=@($accounts | Where-Object { $_.Enabled })
    if ($activeAccounts.Count) { $accounts=$activeAccounts }
    [pscustomobject]@{ Accounts = $accounts; AdministratorSids = $administratorSids }
}

function New-MissingAccountResult {
    param ([Parameter(Mandatory = $true)][string]$RequestedName, [string]$Privilege = 'Not available', [switch]$Administrative)
    $result = New-CheckResult 'Fail' "Account Missing. Please create manually: $RequestedName. No account was created." 'Account missing'
    $result | Add-Member -NotePropertyName AccountName -NotePropertyValue $RequestedName
    $result | Add-Member -NotePropertyName DetectedAccountNames -NotePropertyValue ([string[]]@())
    $result | Add-Member -NotePropertyName Shortcut -NotePropertyValue (New-AccountReportCommand -AccountNames @())
    $state=[ordered]@{'Account Name'=$RequestedName;'Account Privilege'=$Privilege;'Account Status'='Missing';'Password Never Expires'='Not applicable'}
    if(-not $Administrative){$state['User Cannot Change Password']='Not applicable'}
    $result | Add-Member -NotePropertyName StateHtml -NotePropertyValue (ConvertTo-ReportDefinitionHtml $state)
    return $result
}

function Open-ThoroughLocalAccount {
    param([Parameter(Mandatory=$true)][string]$UserName)
    $entry=[ADSI]('WinNT://{0}/{1},user' -f $env:COMPUTERNAME,$UserName)
    return ,$entry
}

function Enable-LocalAccountPasswordFlags {
    param([Parameter(Mandatory=$true)][string]$UserName,[bool]$PasswordNeverExpires,[bool]$UserCannotChangePassword,[switch]$AllowPasswordChange)
    if(-not (Test-CanApply)){throw 'Account changes are disabled outside Apply Fix.'}
    if($UserCannotChangePassword -and $AllowPasswordChange){throw 'Conflicting password-change settings were requested.'}
    # Change only approved UserFlags bits; keep identity, activation and unrelated flags intact.
    # https://learn.microsoft.com/windows/win32/adsi/modifying-user-cannot-change-password-winnt-provider
    $entry=Open-ThoroughLocalAccount $UserName
    $raw=$entry.InvokeGet('UserFlags')
    if($null -eq $raw){throw 'The existing account flags could not be read; nothing was changed.'}
    $before=[int]$raw;$setMask=0;$clearMask=0
    if($PasswordNeverExpires){$setMask=$setMask -bor 0x10000}
    if($UserCannotChangePassword){$setMask=$setMask -bor 0x40}
    if($AllowPasswordChange){$clearMask=0x40}
    $managedMask=$setMask -bor $clearMask
    $target=($before -bor $setMask) -band (-bnot $clearMask)
    if($target -eq $before){return [pscustomobject]@{Changed=$false;BeforeFlags=$before;AfterFlags=$before}}
    $entry.Put('UserFlags',$target)
    $entry.SetInfo()
    $entry.RefreshCache(@('UserFlags'))
    $readback=$entry.InvokeGet('UserFlags')
    if($null -eq $readback){throw 'The password settings could not be read back after update.'}
    $after=[int]$readback
    if(($after -band $setMask) -ne $setMask -or ($after -band $clearMask) -ne 0){throw 'The requested password settings were not verified after update.'}
    if(($after -band (-bnot $managedMask)) -ne ($before -band (-bnot $managedMask))){throw 'An unrelated account flag changed; manual verification is required.'}
    [pscustomobject]@{Changed=$true;BeforeFlags=$before;AfterFlags=$after}
}

function Invoke-ExistingAccountPolicy {
    param([Parameter(Mandatory=$true)]$Account,[Parameter(Mandatory=$true)]$AdministratorSids,[switch]$ReportPrivilegeOnly,[switch]$Administrative)
    $privilege=Get-LocalAccountPrivilege -Account $Account -AdministratorSids $AdministratorSids
    $administrativePolicy=$Administrative -or $privilege -eq 'Local Administrator' -or $Account.Name -in @('Admin','Administrator')
    $requireCannot=-not $administrativePolicy
    $properties=Get-LocalAccountProperties -UserName $Account.Name
    if($null -eq $properties -or $null -eq $properties.PasswordNeverExpires -or $null -eq $properties.UserCannotChangePassword){throw 'Required account properties could not be verified; no changes made.'}
    $beforeNever=[bool]$properties.PasswordNeverExpires
    $beforeCannot=[bool]$properties.UserCannotChangePassword
    $changes=[Collections.Generic.List[string]]::new()
    $failure=$null;$write=$null
    $needsPasswordChange=if($administrativePolicy){$beforeCannot}else{-not $beforeCannot}
    if($Account.Enabled -and (Test-CanApply) -and (-not $beforeNever -or $needsPasswordChange)){
        try {
            $write=Enable-LocalAccountPasswordFlags -UserName $Account.Name -PasswordNeverExpires:(-not $beforeNever) -UserCannotChangePassword:($requireCannot -and -not $beforeCannot) -AllowPasswordChange:$administrativePolicy
        } catch {$failure=$_.Exception.Message}
        try {$properties=Get-LocalAccountProperties -UserName $Account.Name}
        catch {
            $properties=[pscustomobject]@{PasswordNeverExpires=$null;UserCannotChangePassword=$null}
            $failure=(@($failure,'Password-setting readback could not be completed: '+$_.Exception.Message)|Where-Object {$_}) -join '; '
        }
        if(-not $beforeNever -and $properties.PasswordNeverExpires -eq $true){$changes.Add('Enabled Password Never Expires')}
        if($requireCannot -and -not $beforeCannot -and $properties.UserCannotChangePassword -eq $true){$changes.Add('Enabled User Cannot Change Password')}
        if($administrativePolicy -and $beforeCannot -and $properties.UserCannotChangePassword -eq $false){$changes.Add('Allowed password changes')}
    }
    $verified=$properties.PasswordNeverExpires -eq $true -and $(if($administrativePolicy){$properties.UserCannotChangePassword -eq $false}else{$properties.UserCannotChangePassword -eq $true})
    $status=if($verified -and -not $failure){'Pass'}else{'Fail'}
    if($failure){
        $action=(@(($changes -join '; '),('Password settings update could not be fully verified: '+$failure),'Manual action required')|Where-Object {$_}) -join '; '
    } elseif(-not $Account.Enabled -and -not $verified){$action='Disabled account; password properties inspected without changes. Required password properties are not enabled. Manual review required.'}
    elseif($changes.Count -and $verified){$action=($changes -join '; ')+'; readback verified'}
    elseif($verified){$action='Requested password settings are enabled; no changes needed'}
    elseif(Test-CanApply){$action='Required password settings were not verified after Apply; account identity, privilege and enabled state were preserved. Manual action required.'}
    elseif($requireCannot){$action='Audit only: Password Never Expires and User Cannot Change Password must both be enabled'}
    else {$action='Audit only: Password Never Expires must be enabled and password changes must be allowed'}
    $never=if($null -eq $properties.PasswordNeverExpires){'Not verified'}elseif($properties.PasswordNeverExpires){'Enabled'}else{'Disabled'}
    $state=[ordered]@{
        'Account Name'=[string]$Account.Name;'Account Privilege'=$privilege
        'Account Status'=$(if($Account.Enabled){'Enabled'}else{'Disabled'})
        'Password Never Expires'=$never
    }
    if($requireCannot){
        $state['User Cannot Change Password']=if($null -eq $properties.UserCannotChangePassword){'Not verified'}elseif($properties.UserCannotChangePassword){'Enabled'}else{'Disabled'}
    }
    $result=New-CheckResult $status $action 'Account present'
    $result|Add-Member NoteProperty AccountName ([string]$Account.Name)
    $result|Add-Member NoteProperty AccountPolicyChanged ([bool]($changes.Count -or ($write -and $write.Changed)))
    $result|Add-Member NoteProperty DetectedAccountNames @([string]$Account.Name)
    $result|Add-Member NoteProperty StateHtml (ConvertTo-ReportDefinitionHtml $state)
    return $result
}

function Get-TargetLocalAccounts {
    param ([Parameter(Mandatory = $true)][string[]]$Names)
    $allAccounts = @(Get-LocalUser -ErrorAction Stop)
    foreach ($name in $Names) {
        $account = @($allAccounts | Where-Object { $_.Name -ieq $name }) | Select-Object -First 1
        [pscustomobject]@{ RequestedName = $name; Account = $account }
    }
}

function Join-AccountCheckResults {
    param ([object[]]$Results, [string]$MissingName)
    if (@($Results).Count -eq 0) { return New-MissingAccountResult -RequestedName $MissingName }
    $status = if (@($Results | Where-Object { $_.Status -ne 'Pass' }).Count) { 'Fail' } else { 'Pass' }
    $result = New-CheckResult $status '' 'Account properties recorded'
    $states = foreach ($entry in $Results) {
        if ($entry.PSObject.Properties['StateHtml']) { $entry.StateHtml }
        else { '<div>' + [Net.WebUtility]::HtmlEncode($entry.State) + '</div>' }
    }
    $actions = foreach ($entry in $Results) {
        $name = if ($entry.PSObject.Properties['AccountName']) { $entry.AccountName } else { 'Account' }
        $name + ': ' + $entry.Action
    }
    $result.Action = $actions -join '; '
    $result | Add-Member -NotePropertyName StateHtml -NotePropertyValue ('<div class="account-stack">' + ($states -join '<hr>') + '</div>')
    $detectedNames=@(foreach ($entry in $Results) {
        if ($entry.PSObject.Properties['DetectedAccountNames']) { $entry.DetectedAccountNames }
        elseif ($entry.PSObject.Properties['AccountName']) { [string]$entry.AccountName }
    })
    $result | Add-Member -NotePropertyName DetectedAccountNames -NotePropertyValue $detectedNames
    $result | Add-Member -NotePropertyName Shortcut -NotePropertyValue (New-AccountReportCommand -AccountNames $detectedNames)
    # Preserve each account result for report projections; aggregate outcomes are unchanged.
    $result | Add-Member -NotePropertyName AccountResults -NotePropertyValue @($Results)
    return $result
}

function Get-KioskAutoLoginUserName {
    $path='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $key=Get-Item -LiteralPath $path -ErrorAction Stop
    $domain=[string]$key.GetValue('DefaultDomainName')
    if ($key.GetValue('AutoAdminLogon') -eq '1' -and ([string]::IsNullOrWhiteSpace($domain) -or $domain -eq '.' -or $domain -ieq $env:COMPUTERNAME)) { return [string]$key.GetValue('DefaultUserName') }
    return $null
}

function Get-KioskAccountCheck {
    # Discover existing kiosk users; Apply changes only the two required password properties.
    $users=@(Get-LocalUser -ErrorAction Stop)
    $autoLoginUser=try {Get-KioskAutoLoginUserName} catch {$null}
    $candidates=@(foreach ($user in $users) {
        $known=$user.Name -in @('SELISE','SELISE-KIOSK')
        $profile=$null; $hasLauncher=$false
        try {
            $profile=Get-KioskProfilePath -UserName $user.Name
            if ($profile) { $hasLauncher=Test-Path -LiteralPath (Join-Path $profile 'Scripts\LaunchKiosk.ps1') -PathType Leaf }
        } catch { if (-not $known -and $user.Name -ine $autoLoginUser) { continue } }
        if ($known -or $hasLauncher -or $user.Name -ieq $autoLoginUser) { [pscustomobject]@{Account=$user;HasLauncher=$hasLauncher} }
    })
    $activeCandidates=@($candidates | Where-Object { $_.Account.Enabled })
    if ($activeCandidates.Count) { $candidates=$activeCandidates }
    if (-not $candidates.Count) {
        $message=if (-not $users.Count) {'Account Missing. Please create manually.'} else {'Not verified. Kiosk account could not be identified from the existing setup. Please check manually.'}
        $result=New-CheckResult 'Fail' $message $message
        $result | Add-Member NoteProperty StateHtml $message
        $result | Add-Member NoteProperty DetectedAccountNames ([string[]]@())
        $result | Add-Member NoteProperty Shortcut (New-AccountReportCommand -AccountNames @())
        return [pscustomobject]@{Account=$null;Result=$result}
    }
    $selected=@($candidates | Where-Object {$_.Account.Name -ieq $autoLoginUser})
    if ($selected.Count -ne 1) {
        $withLauncher=@($candidates | Where-Object {$_.HasLauncher})
        if ($withLauncher.Count -eq 1) { $selected=$withLauncher }
        elseif ($withLauncher.Count -gt 1) {
            $result=New-CheckResult 'Fail' 'Multiple kiosk profiles contain launcher scripts; selection requires manual review.' 'Not verified. Multiple kiosk launcher profiles found. Please check manually.'
            $result | Add-Member NoteProperty StateHtml $result.State
            $result | Add-Member NoteProperty DetectedAccountNames ([string[]]@($withLauncher | ForEach-Object {$_.Account.Name}))
            $result | Add-Member NoteProperty Shortcut (New-AccountReportCommand -AccountNames $result.DetectedAccountNames)
            return [pscustomobject]@{Account=$null;Result=$result}
        } else {
            $selected=@($candidates | Where-Object {$_.Account.Name -ieq 'SELISE-KIOSK'})
            if (-not $selected.Count) { $selected=@($candidates | Select-Object -First 1) }
        }
    }
    $administratorSids=Get-LocalAdministratorSidSet
    $results=@(foreach ($candidate in $candidates) {
        $account=$candidate.Account
        $privilege=Get-LocalAccountPrivilege -Account $account -AdministratorSids $administratorSids
        try {
            $entry=Invoke-ExistingAccountPolicy -Account $account -AdministratorSids $administratorSids -ReportPrivilegeOnly
        } catch {
            $entry=New-CheckResult 'Fail' $_.Exception.Message 'Account present; required properties not verified'
            $entry | Add-Member NoteProperty AccountName ([string]$account.Name)
            $entry | Add-Member NoteProperty DetectedAccountNames @([string]$account.Name)
            $entry | Add-Member NoteProperty StateHtml (ConvertTo-ReportDefinitionHtml ([ordered]@{'Account Name'=$account.Name;'Account Privilege'=$privilege;'Account Status'=$(if ($account.Enabled) {'Enabled'} else {'Disabled'});'Password Never Expires'='Not verified';'User Cannot Change Password'='Not verified'}))
        }
        $entry
    })
    [pscustomobject]@{Account=$selected[0].Account;Result=(Join-AccountCheckResults -Results $results -MissingName 'Existing kiosk account')}
}

function Get-AdministrativeAccountCheck {
    $discovered = Get-AdministrativeLocalAccounts
    $results = @(foreach ($account in $discovered.Accounts) {
        try { Invoke-ExistingAccountPolicy -Account $account -AdministratorSids $discovered.AdministratorSids -Administrative }
        catch {
            $failed = New-CheckResult 'Fail' $_.Exception.Message ('Account properties could not be read: ' + $account.Name)
            $failed | Add-Member -NotePropertyName AccountName -NotePropertyValue $account.Name
            $failed | Add-Member -NotePropertyName StateHtml -NotePropertyValue (ConvertTo-ReportDefinitionHtml ([ordered]@{
                'Account Name'=$account.Name
                'Account Privilege'=(Get-LocalAccountPrivilege -Account $account -AdministratorSids $discovered.AdministratorSids)
                'Account Status'=$(if ($account.Enabled) {'Enabled'} else {'Disabled'})
                'Password Never Expires'='Not verified'
            }))
            $failed
        }
    })
    if(-not $results.Count){return New-MissingAccountResult -RequestedName 'Admin, Administrator' -Administrative}
    Join-AccountCheckResults -Results $results -MissingName 'Admin, Administrator'
}

function Get-KioskProfilePath {
    param ([string]$UserName)
    $account = Get-LocalAccount $UserName
    if (-not $account) { return $null }
    $path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($account.SID.Value)"
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $profile = Get-ItemProperty -LiteralPath $path -ErrorAction Stop
    if ($profile.ProfileImagePath) { return [Environment]::ExpandEnvironmentVariables($profile.ProfileImagePath) }
}

function Initialize-KioskProfile {
    param ([string]$UserName)
    # Thorough Check may inspect an existing profile, never create one.
    $path = Get-KioskProfilePath $UserName
    if (-not $path) { throw "Windows profile for '$UserName' is missing; no profile or launcher files were created." }
    return $path
}

function Test-KioskAutoLogin {
    param([string]$UserName)
    $account=Get-LocalAccount $UserName
    if (-not $account) {throw 'Kiosk account is unavailable; auto-login cannot be verified.'}
    $path='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $key=Get-Item -LiteralPath $path -ErrorAction Stop
    $domain=[string]$key.GetValue('DefaultDomainName')
    $localDomain=[string]::IsNullOrWhiteSpace($domain) -or $domain -eq '.' -or $domain -ieq $env:COMPUTERNAME
    $count=$key.GetValue('AutoLogonCount')
    $unlimited=$null -eq $count -or ($count -is [string] -and $count.Length -eq 0)
    $user=[string]$key.GetValue('DefaultUserName')
    $enabled=$key.GetValue('AutoAdminLogon') -eq '1'
    $configured=$account.Enabled -and $enabled -and $user -ieq $UserName -and $localDomain -and $unlimited
    $result=New-CheckResult $(if ($configured) {'Pass'} else {'Fail'}) 'Existing auto-login settings recorded without changes; verify actual sign-in manually.' 'Auto-login inspected'
    $result | Add-Member NoteProperty StateHtml (ConvertTo-ReportDefinitionHtml ([ordered]@{'Automatic Sign-In'=$(if ($enabled) {'Enabled'} else {'Disabled'});'Default User'=$user;'Default Domain'=$(if ($localDomain) {'Local computer'} else {$domain});'Automatic Sign-In Limit'=$(if ($unlimited) {'Unlimited'} else {[string]$count})}))
    return $result
}
