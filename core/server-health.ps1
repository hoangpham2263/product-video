# A matching /api/root alone is insufficient: old PowerShell web servers expose it but have no menu at /.
function Get-HubHttpText([string]$Uri) {
    $request=[Net.HttpWebRequest]::Create($Uri)
    $request.Timeout=2000;$request.ReadWriteTimeout=2000;$request.Proxy=$null
    $response=$null;$reader=$null
    try {
        $response=$request.GetResponse()
        $reader=New-Object IO.StreamReader($response.GetResponseStream(),[Text.Encoding]::UTF8)
        return $reader.ReadToEnd()
    } finally {if($reader){$reader.Dispose()};if($response){$response.Dispose()}}
}
function Test-HubServer {
    try {
        $answer=Get-HubHttpText "http://127.0.0.1:$port/api/root" | ConvertFrom-Json
        if(([string]$answer.root).TrimEnd('\').ToLowerInvariant() -ne $serverRoot.TrimEnd('\').ToLowerInvariant()){return $false}
        if($answer.service -ne $serverService -or $answer.protocol -ne 1){return $false}
        $html=Get-HubHttpText "http://127.0.0.1:$port/"
        return $html -match '(?i)<(?:!doctype\s+html|html\b)'
    } catch {return $false}
}
function Test-HubPortFree([int]$PortNumber) {
    $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,$PortNumber)
    try {$listener.Start();return $true} catch {return $false} finally {$listener.Stop()}
}
function Select-HubServerPort([int]$BasePort,[string]$AddressFile) {
    try {
        $saved=Get-Content -LiteralPath $AddressFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if($saved.root -eq $serverRoot -and $saved.service -eq $serverService -and $saved.port -ge $BasePort -and $saved.port -le ($BasePort+20)){
            $port=[int]$saved.port
            if(Test-HubServer){return $port}
        }
    } catch {}
    $firstFree=0
    for($candidate=$BasePort;$candidate -le ($BasePort+20);$candidate++){
        $port=$candidate
        if(Test-HubPortFree $candidate){if(-not $firstFree){$firstFree=$candidate};continue}
        if(Test-HubServer){return $candidate}
    }
    if($firstFree){return $firstFree}
    throw 'Không tìm được cổng trống cho Product Review. Đóng các phiên cũ rồi mở lại.'
}
