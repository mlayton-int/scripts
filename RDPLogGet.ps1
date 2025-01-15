$EventID = "21"
$HistLength = -30
$OutPath = "C:\INS-Temp\RDPLog\RDPLog.txt"
$MachineName = [system.net.dns]::gethostname()

# Get event log entries 
$Events = Get-WinEvent -FilterHashtable @{LogName="Microsoft-Windows-TerminalServices-LocalSessionManager/Operational"; ID=$EventID; StartTime=(Get-Date).AddDays($HistLength)}

# Return how many events were found and the date range
$DateRange = "Found $($Events.length) connections between $($(Get-Date -UFormat "%D")) and $($((Get-Date).AddDays(-30).ToString("MM/dd/yy")))"

# For each event log entry separate out the line containing the username, then remove duplicates
$Users = $Events | ForEach-Object {($_.message -split "`n")[2]} | Select-Object -Unique
# Remove leading text before username
$Users = $Users | ForEach-Object {($_ -split " ")[1]}

$Results = "Machine Name: $($MachineName)`n$($DateRange) `n`n$($Users)"

Out-File -InputObject $Results -FilePath $OutPath
