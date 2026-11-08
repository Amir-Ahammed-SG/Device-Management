# Isolated hidden browser; no real clipboard updates or interactive print dialogs.
$ErrorActionPreference='Stop'
$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$listener.Start();$port=$listener.LocalEndpoint.Port;$listener.Stop()
$profile=Join-Path $env:TEMP ('combined-report-browser-'+[guid]::NewGuid().ToString('N'))
$arguments=@('--headless','--disable-gpu','--hide-scrollbars','--no-first-run','--no-default-browser-check','--remote-debugging-address=127.0.0.1',('--remote-debugging-port='+$port),('--user-data-dir="'+$profile+'"'),'about:blank')
$browser=Start-Process -FilePath 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe' -ArgumentList $arguments -WindowStyle Hidden -PassThru
try{& node (Join-Path $PSScriptRoot 'Test-CombinedReportBrowser.mjs') $port;if($LASTEXITCODE -ne 0){throw 'Combined report browser checks failed.'}}
finally{if(-not $browser.HasExited){Stop-Process -Id $browser.Id -ErrorAction SilentlyContinue}}
