# Start a dedicated hidden browser. Browser test doubles leave the OS clipboard untouched.
$ErrorActionPreference='Stop'
$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
$listener.Start()
$port=$listener.LocalEndpoint.Port
$listener.Stop()
$profile=Join-Path $env:TEMP ('report-clipboard-test-'+[guid]::NewGuid().ToString('N'))
$edge='C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
$arguments=@('--headless','--disable-gpu','--hide-scrollbars','--no-first-run','--no-default-browser-check','--remote-debugging-address=127.0.0.1',('--remote-debugging-port='+$port),('--user-data-dir="'+$profile+'"'),'about:blank')
$browser=Start-Process -FilePath $edge -ArgumentList $arguments -WindowStyle Hidden -PassThru
try {
    & node (Join-Path $PSScriptRoot 'Test-ReportClipboard.mjs') $port
    if ($LASTEXITCODE -ne 0) { throw 'Browser clipboard interaction checks failed' }
} finally {
    if (-not $browser.HasExited) { Stop-Process -Id $browser.Id -ErrorAction SilentlyContinue }
}
