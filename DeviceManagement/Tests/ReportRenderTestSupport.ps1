# Presentation tests inspect the active standalone document. Combined-file I/O,
# snapshot preservation and print/export are exercised by the combined-report tests.
function Save-ThoroughReportBundle {
    param($Path,$ClientType,$ComputerName,[object[]]$Snapshots,$PreferredMode)
    $snapshot=@($Snapshots | Where-Object Mode -eq $PreferredMode)
    if($snapshot.Count -ne 1){throw 'The renderer did not produce exactly one active report snapshot.'}
    $html=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($snapshot[0].HtmlBase64))
    [IO.File]::WriteAllText($Path,$html,(New-Object Text.UTF8Encoding($false)))
    $Path
}
