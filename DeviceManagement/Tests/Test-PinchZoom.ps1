# Isolated launcher files and registry fixtures. Never run a launcher or browser.
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$sourceRoot=Split-Path $projectRoot -Parent
$fixtureRoot=Join-Path $projectRoot ('output\pinch-zoom\fixtures-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureRoot)
function Assert-Pinch {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}
function New-PinchFixture {
    param([string]$Arguments,[string]$Format='literal',[Text.Encoding]$Encoding=([Text.UTF8Encoding]::new($false)))
    $script:profile=Join-Path $fixtureRoot ('Kiosk & Branch-'+[guid]::NewGuid().ToString('N'))
    $script:launch=Join-Path $script:profile 'Scripts\LaunchKiosk.ps1'
    $script:batch=Join-Path $script:profile 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\LaunchKiosk.bat'
    [void][IO.Directory]::CreateDirectory((Split-Path $script:launch -Parent))
    [void][IO.Directory]::CreateDirectory((Split-Path $script:batch -Parent))
    $prefix='# Customer settings '+[char]0x00E9+[char]0x6587+"`r`n"+'$unrelated = ''Preserve exactly'''+"`r`n"
    $script:template=$prefix+'Start-Process -FilePath ''C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'' -ArgumentList ''{ARGS}'' -WindowStyle Maximized'+"`r`n"
    switch($Format){
        'positional' {$script:template=$prefix+'Start-Process msedge.exe -ArgumentList ''{ARGS}'''+"`r`n"}
        'module' {$script:template=$prefix+'Microsoft.PowerShell.Management\Start-Process -FilePath msedge.exe -ArgumentList ''{ARGS}'''+"`r`n"}
        'comment' {$script:template='# --disable-pinch is a comment only'+"`r`n"+$script:template}
        'unused' {$script:template='$unused = ''--disable-pinch'''+"`r`n"+$script:template}
        'double' {$script:template=$prefix+'Start-Process -FilePath msedge.exe -ArgumentList "{ARGS}"'+"`r`n"}
        'dynamic' {$script:template=$prefix+'$arguments = ''{ARGS}'''+"`r`n"+'Start-Process msedge.exe -ArgumentList $arguments'}
        'multiple' {$script:template+= $script:template}
        'conditional' {$script:template='if ($false) {'+"`r`n"+$script:template+"`r`n"+'}'}
        'signed' {$script:template+='# SIG # Begin signature block'+"`r`n"+'# Sample signature marker only'}
        'not-edge' {$script:template=$script:template.Replace('msedge.exe','notepad.exe')}
        'array' {$script:template=$prefix+'Start-Process msedge.exe -ArgumentList @(''{ARGS}'')'}
        'splat' {$script:template=$script:template.TrimEnd()+' @extraArguments'}
        'extra-positional' {$script:template=$script:template.TrimEnd()+' $extraArguments'}
        'whatif' {$script:template=$script:template.TrimEnd()+' -WhatIf'}
        'dynamic-file' {$script:template=$prefix+'$browser = ''msedge.exe'''+"`r`n"+'Start-Process -FilePath $browser -ArgumentList ''{ARGS}'''}
        'syntax' {$script:template='function Broken {'}
    }
    $script:text=$script:template.Replace('{ARGS}',$Arguments)
    [IO.File]::WriteAllText($script:launch,$script:text,$Encoding)
    [IO.File]::WriteAllText($script:batch,('@echo off'+"`r`n"+'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\Scripts\LaunchKiosk.ps1"'))
    $script:original=[IO.File]::ReadAllBytes($script:launch)
    $script:profileMissing=$false
}
function Assert-PinchBytes {param([byte[]]$Expected) Assert-Pinch ([Convert]::ToBase64String([IO.File]::ReadAllBytes($script:launch)) -ceq [Convert]::ToBase64String($Expected)) 'Unexpected launcher bytes'}
function Assert-PinchFiles {Assert-Pinch (@(Get-ChildItem -LiteralPath $script:profile -Recurse -File).Count -eq 2) 'A backup, temporary or additional file was created'}
$caseCount=0
foreach($sourceName in @('SaaSKioskThoroughCheckScript.ps1','SubwayKioskThoroughCheck.ps1')){
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $sourceRoot $sourceName),[ref]$tokens,[ref]$errors)
    Assert-Pinch ($errors.Count -eq 0) 'Client source parser errors'
    . ([scriptblock]::Create(($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true) | ForEach-Object {$_.Extent.Text}) -join "`r`n"))
    $realWrite=${function:Write-KioskPinchStream};$realRead=${function:Read-KioskPinchStream};$realBatch=${function:Test-KioskStartupBatch}
    $script:origin=if($sourceName -like 'Subway*'){'https://kiosk.subway.ch'}else{'https://kiosk.ordermonkey.com'}
    $url=$script:origin+'/#/onboarding/login?restaurantId=Keep%2fR&kioskId=Kiosk-2&host=HOST-02&custom=Preserve%20Me'
    $baseArguments='--kiosk "'+$url+'" --edge-kiosk-type=fullscreen --no-first-run'
    $requirement=Get-ReportRequirement ([pscustomobject]@{ItemTitle='System & Browser Policies'})
    Assert-Pinch ($requirement.Contains('Pinch-to-Zoom:</span> Disabled') -and $requirement -notmatch 'Obsolete allowlist entry') 'Policy reference is incorrect'
    function Get-KioskProfilePath {param($UserName) Assert-Pinch ($UserName -ceq 'Custom Kiosk') 'Selected kiosk account was lost'; if($script:profileMissing){return $null}; return $script:profile}
    function Start-Process {throw 'Launcher/browser execution is forbidden'}
    function Read-Host {throw 'Zoom checks must not request unrelated values'}
    function Copy-Item {throw 'Backup files are forbidden'}
    function Set-ItemProperty {throw 'Existing registry values must not be overwritten'}
    function New-ItemProperty {throw 'Compliant policy fixture must not be changed'}
    function Test-Path {
        [CmdletBinding()]param($LiteralPath,$PathType)
        if($LiteralPath -like 'HKLM:*'){return $script:keys.ContainsKey($LiteralPath)}
        Assert-Pinch ($LiteralPath.StartsWith($fixtureRoot,[StringComparison]::OrdinalIgnoreCase)) 'Path escaped fixture root'
        if($PathType -eq 'Leaf'){return [IO.File]::Exists($LiteralPath)}
        if($PathType -eq 'Container'){return [IO.Directory]::Exists($LiteralPath)}
        return [IO.File]::Exists($LiteralPath) -or [IO.Directory]::Exists($LiteralPath)
    }
    function Get-Item {[CmdletBinding()]param($LiteralPath) Assert-Pinch ($script:keys.ContainsKey($LiteralPath)) 'Unexpected registry read'; return $script:keys[$LiteralPath]}
    $edge='HKLM:\SOFTWARE\Policies\Microsoft\Edge'
    $script:keys=@{}
    foreach($spec in @(@($edge,@{TranslateEnabled=0;VisualSearchEnabled=0},@{TranslateEnabled='DWord';VisualSearchEnabled='DWord'}),@(($edge+'\LocalNetworkAccessAllowedForUrls'),@{'1'=$script:origin},@{'1'='String'}),@('HKLM:\SOFTWARE\Policies\Microsoft\Windows\EdgeUI',@{AllowEdgeSwipe=0},@{AllowEdgeSwipe='DWord'}))){
        $key=[pscustomobject]@{Values=$spec[1];Kinds=$spec[2]}
        $key | Add-Member ScriptMethod GetValueNames {return @($this.Values.Keys)}
        $key | Add-Member ScriptMethod GetValue {param($Name) return $this.Values[$Name]}
        $key | Add-Member ScriptMethod GetValueKind {param($Name) return $this.Kinds[$Name]}
        $script:keys[$spec[0]]=$key
    }
    foreach($isApply in @($false,$true)){
        $script:ApplyChanges=$isApply
        foreach($format in @('literal','positional','module','comment','unused','double')){
            foreach($encoding in @([Text.UTF8Encoding]::new($false),[Text.UTF8Encoding]::new($true),[Text.Encoding]::Unicode,[Text.Encoding]::BigEndianUnicode,[Text.Encoding]::UTF32,[Text.UTF32Encoding]::new($true,$true))){
                $arguments=if($format -eq 'double'){$baseArguments.Replace('"','`"')}else{$baseArguments}
                New-PinchFixture $arguments $format $encoding
                $result=Invoke-KioskPinchZoomCheck -UserName 'Custom Kiosk'
                Assert-Pinch (($result.Status -eq 'Pass') -eq $isApply) ('Missing-argument result incorrect: '+$format+' '+$encoding.WebName+' '+$result.Action)
                $expected=if($isApply){$script:template.Replace('{ARGS}',($arguments+' --disable-pinch'))}else{$script:text}
                Assert-Pinch ([IO.File]::ReadAllText($script:launch) -ceq $expected) 'More than the authorized argument changed'
                if(-not $isApply){Assert-PinchBytes $script:original}
                else{
                    $expectedBody=$encoding.GetBytes($expected);$preamble=$encoding.GetPreamble()
                    $expectedBytes=[byte[]]::new($preamble.Length+$expectedBody.Length)
                    [Buffer]::BlockCopy($preamble,0,$expectedBytes,0,$preamble.Length);[Buffer]::BlockCopy($expectedBody,0,$expectedBytes,$preamble.Length,$expectedBody.Length)
                    Assert-PinchBytes $expectedBytes
                    $repeat=Invoke-KioskPinchZoomCheck -UserName 'Custom Kiosk'
                    Assert-Pinch ($repeat.Status -eq 'Pass' -and $repeat.State -ceq 'Disabled') 'Repeated Apply was not idempotent'
                    Assert-PinchBytes $expectedBytes
                }
                Assert-PinchFiles;$caseCount++
            }
        }
        foreach($suffix in @(' --disable-pinch',' --user-agent="text --disable-pinch example"',' -- --disable-pinch',' --disable-pinch=false',' --enable-pinch',' --disable-pinch --disable-pinch',' --user-agent="unmatched')){
            New-PinchFixture ($baseArguments+$suffix)
            $result=Invoke-KioskPinchZoomCheck -UserName 'Custom Kiosk'
            $safe=$suffix -in @(' --disable-pinch',' --user-agent="text --disable-pinch example"')
            $pass=$suffix -eq ' --disable-pinch' -or ($isApply -and $safe)
            Assert-Pinch (($result.Status -eq 'Pass') -eq $pass) ('Switch token handling is incorrect: '+$suffix)
            if(-not $pass -or $suffix -eq ' --disable-pinch'){Assert-PinchBytes $script:original}
            Assert-PinchFiles;$caseCount++
        }
        foreach($problem in @('dynamic','multiple','conditional','not-edge','array','splat','extra-positional','whatif','dynamic-file','syntax','signed','missing-bat','wrong-bat','missing-profile','missing-script')){
            New-PinchFixture $baseArguments $problem
            switch($problem){
                'missing-bat' {[IO.File]::Delete($script:batch)}
                'wrong-bat' {[IO.File]::WriteAllText($script:batch,'powershell.exe -File "C:\Other\LaunchKiosk.ps1"')}
                'missing-profile' {$script:profileMissing=$true}
                'missing-script' {[IO.File]::Delete($script:launch)}
            }
            $result=Invoke-KioskPinchZoomCheck -UserName 'Custom Kiosk'
            Assert-Pinch ($result.Status -eq 'Fail') ('Unsafe launcher passed: '+$problem)
            if($problem -ne 'missing-script'){Assert-PinchBytes $script:original}else{Assert-Pinch (-not [IO.File]::Exists($script:launch)) 'Missing script was created'}
            $caseCount++
        }
        foreach($present in @($false,$true)){
            New-PinchFixture ($baseArguments+$(if($present){' --disable-pinch'}else{''}))
            $result=Invoke-BrowserPolicyCheck -UserName 'Custom Kiosk'
            Assert-Pinch (($result.Status -eq 'Pass') -eq ($present -or $isApply)) 'Combined policy result ignored pinch configuration'
            Assert-Pinch ($result.StateHtml.Contains(('Pinch-to-Zoom: '+$(if($present -or $isApply){'Disabled'}else{'Not configured'})))) 'Policy Findings lost the pinch state'
            $caseCount++
        }
    }
    $script:ApplyChanges=$true
    foreach($fault in @('partial-write','no-effect','readback')){
        New-PinchFixture $baseArguments
        $script:readCalls=0;$script:fault=$fault
        function Write-KioskPinchStream {
            param([IO.FileStream]$Stream,[byte[]]$Bytes)
            if($script:fault -eq 'partial-write'){$Stream.Position=0;$Stream.WriteByte(35);$Stream.SetLength(5);$Stream.Flush();throw 'Injected partial write'}
            if($script:fault -eq 'no-effect'){return}
            & $realWrite -Stream $Stream -Bytes $Bytes
        }
        function Read-KioskPinchStream {
            param([IO.Stream]$Stream)
            $script:readCalls++
            if($script:fault -eq 'readback' -and $script:readCalls -eq 2){return ,[byte[]]@(0)}
            return ,(& $realRead -Stream $Stream)
        }
        $result=Invoke-KioskPinchZoomCheck -UserName 'Custom Kiosk'
        Assert-Pinch ($result.Status -eq 'Fail' -and $result.Action -match 'Previous launcher bytes restored') ('Failed mutation was not rolled back: '+$fault+' '+$result.Action)
        Assert-PinchBytes $script:original;Assert-PinchFiles;$caseCount++
        Set-Item Function:\Write-KioskPinchStream $realWrite
        Set-Item Function:\Read-KioskPinchStream $realRead
    }
    New-PinchFixture $baseArguments
    $lock=[IO.File]::Open($script:launch,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
    try{$result=Invoke-KioskPinchZoomCheck -UserName 'Custom Kiosk';Assert-Pinch ($result.Status -eq 'Fail') 'Locked launcher was reported as verified'}finally{$lock.Dispose()}
    Assert-PinchBytes $script:original;Assert-PinchFiles;$caseCount++
    New-PinchFixture $baseArguments
    $script:concurrentText=$script:text+"`r`n"+'# Concurrent operator change'
    function Test-KioskStartupBatch {param($Batch,$LaunchPath) [IO.File]::WriteAllText($script:launch,$script:concurrentText,[Text.UTF8Encoding]::new($false));return $true}
    $result=Invoke-KioskPinchZoomCheck -UserName 'Custom Kiosk'
    Assert-Pinch ($result.Status -eq 'Fail' -and [IO.File]::ReadAllText($script:launch) -ceq $script:concurrentText) 'Concurrent content was overwritten'
    Set-Item Function:\Test-KioskStartupBatch $realBatch
    Assert-PinchFiles;$caseCount++
    Remove-Item Function:\Test-Path
    Write-Output ("PASS: $sourceName pinch-only Audit/Apply, exact content and encoding preservation, unsupported inputs, policy integration, idempotence, exclusive access, write/readback rollback and concurrent-change protection")
}
Write-Output ("PASS: $caseCount isolated pinch cases. No device profile, browser, real registry or launcher execution was used.")
