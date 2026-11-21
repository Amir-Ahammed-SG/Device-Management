# A dedicated hidden browser/profile, independent of the user's browser session.
function Invoke-KioskBrowserTest {
    param([Parameter(Mandatory=$true)][string]$ScriptPath)
    $ErrorActionPreference='Stop'
    $root=Split-Path $PSScriptRoot -Parent
    $edge=@((Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),(Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')) | Where-Object {Test-Path -LiteralPath $_ -PathType Leaf} | Select-Object -First 1
    if(-not $edge -or -not (Get-Command node -ErrorAction SilentlyContinue)){throw 'Browser tests require Microsoft Edge and Node.js with WebSocket support.'}
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    $listener.Start();$port=$listener.LocalEndpoint.Port;$listener.Stop()
    $fixture=Join-Path $root ('output\browser-tests\'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($fixture)
    $profile=Join-Path $fixture 'profile'
    $arguments=@('--headless=new','--disable-gpu','--in-process-gpu','--disable-software-rasterizer','--disable-extensions','--disable-background-networking','--disable-component-update','--disable-sync','--hide-scrollbars','--no-first-run','--no-default-browser-check','--remote-debugging-address=127.0.0.1',('--remote-debugging-port='+$port),('--user-data-dir="'+$profile+'"'),'about:blank')
    $browser=Start-Process -FilePath $edge -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardError (Join-Path $fixture 'browser.log')
    try{
        & node $ScriptPath $port
        if($LASTEXITCODE -ne 0){throw ('Browser regression failed: '+[IO.Path]::GetFileName($ScriptPath))}
    }finally{
        $browser.Refresh()
        if(-not $browser.HasExited){Stop-Process -Id $browser.Id -ErrorAction SilentlyContinue}
    }
}
