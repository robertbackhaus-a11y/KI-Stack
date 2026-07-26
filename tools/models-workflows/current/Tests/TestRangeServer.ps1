param(
    [Parameter(Mandatory)][int]$Port,
    [Parameter(Mandatory)][string]$ArtifactPath,
    [Parameter(Mandatory)][string]$ReadyPath
)
$ErrorActionPreference = 'Stop'
$bytes = [IO.File]::ReadAllBytes($ArtifactPath)
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$Port)
$listener.Start()
[IO.File]::WriteAllText($ReadyPath,'ready')
try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $reader = [IO.StreamReader]::new($stream,[Text.Encoding]::ASCII,$false,1024,$true)
            $requestLine = $reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($requestLine)) { continue }
            $headers = @{}
            while ($true) {
                $line = $reader.ReadLine()
                if ([string]::IsNullOrEmpty($line)) { break }
                $split = $line.IndexOf(':')
                if ($split -gt 0) { $headers[$line.Substring(0,$split).Trim().ToLowerInvariant()] = $line.Substring($split+1).Trim() }
            }
            $path = ($requestLine -split ' ')[1]
            $body = $bytes
            if ($path -eq '/short') { $body = $bytes[0..($bytes.Length-2)] }
            elseif ($path -eq '/bad-hash') {
                $body = [byte[]]::new($bytes.Length)
                [Array]::Copy($bytes,$body,$bytes.Length)
                $body[0] = $body[0] -bxor 0xff
            }
            $start = 0
            $status = '200 OK'
            if ($headers.ContainsKey('range') -and $headers.range -match '^bytes=(\d+)-$') {
                $start = [int]$Matches[1]
                $status = '206 Partial Content'
            }
            $count = $body.Length - $start
            $writeCount = $count
            if($path-eq'/interrupt'-and$start-eq0){$writeCount=[Math]::Floor($count/2)}
            $responseHeaders = "HTTP/1.1 $status`r`nContent-Length: $count`r`nAccept-Ranges: bytes`r`nConnection: close`r`n"
            if ($status -like '206*') { $responseHeaders += "Content-Range: bytes $start-$($body.Length-1)/$($body.Length)`r`n" }
            $headerBytes = [Text.Encoding]::ASCII.GetBytes($responseHeaders + "`r`n")
            $stream.Write($headerBytes,0,$headerBytes.Length)
            $stream.Write($body,$start,$writeCount)
            $stream.Flush()
        }
        finally { $client.Dispose() }
    }
}
finally { $listener.Stop() }
