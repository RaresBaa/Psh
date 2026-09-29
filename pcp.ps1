# Pcp - Portable Copy
# A dependency-free file transfer companion to Psh, for Windows (PowerShell).

$ErrorActionPreference = 'Stop'

$script:Enc = [System.Text.UTF8Encoding]::new($false)
$script:DefaultPort = 12322

function Write-PcpError([string]$Message) {
    [Console]::Error.WriteLine($Message)
}

function Show-Help {
    @'
Pcp - Portable Copy

A minimal file transfer tool, companion to Psh. Run it as a server on one
machine and connect to it from the other with a shared token.

USAGE
  pcp.ps1 --server [--token <token>] [--port <port>] [--dir <path>]
  pcp.ps1 --client --host <host> --token <token> [--port <port>] --send <file>
  pcp.ps1 --client --host <host> --token <token> [--port <port>] --get <name> [--out <path>]

OPTIONS
  -s, --server         Run as a server, listening for connections.
  -c, --client         Run as a client, connecting to a server.
  -H, --host <host>    Server hostname or IP to connect to (client mode).
  -t, --token <token>  Shared secret. Server generates a random one if omitted.
  -p, --port <port>    TCP port to use (default: 12322).
  -d, --dir <path>     Server-side directory to store uploads in and serve
                        downloads from (default: current directory).
  -u, --send <file>    Upload this local file to the server.
  -g, --get <name>     Download this file (by name) from the server.
  -o, --out <path>     Local destination path for --get (default: same name,
                        current directory).
  -h, --help           Show this help and exit.

EXAMPLES
  pcp.ps1 --server --token secret --dir C:\Shared
  pcp.ps1 --client --host 192.168.0.10 --token secret --send report.pdf
  pcp.ps1 --client --host 192.168.0.10 --token secret --get report.pdf --out C:\Downloads\report.pdf

Uploaded/downloaded files are always flat inside the server's --dir - any
directory components in a name are stripped, so a transfer can never read or
write outside it.
'@ | Write-Host
}

function New-RandomToken {
    $bytes = [byte[]]::new(9)
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $clean = ([Convert]::ToBase64String($bytes) -replace '[^a-zA-Z0-9]', '')
    while ($clean.Length -lt 12) { $clean += [Guid]::NewGuid().ToString('N') }
    return $clean.Substring(0, 12)
}

# Names and error reasons travel as hex on the wire (not raw text) so that
# spaces, unicode or other bytes can never be mistaken for protocol framing.
function ConvertTo-PcpHex([string]$Text) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    -join ($bytes | ForEach-Object { $_.ToString('x2') })
}

function ConvertFrom-PcpHex([string]$Hex) {
    if (-not $Hex) { return '' }
    $bytes = [byte[]]::new($Hex.Length / 2)
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $bytes[$i] = [Convert]::ToByte($Hex.Substring($i * 2, 2), 16)
    }
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

function Format-PcpFail([string]$Response) {
    if ($Response -and $Response.StartsWith('FAIL ')) {
        return ConvertFrom-PcpHex $Response.Substring(5)
    }
    return $Response
}

function New-LineWriter([System.IO.Stream]$Stream) {
    $writer = [System.IO.StreamWriter]::new($Stream, $script:Enc)
    $writer.NewLine = "`n"
    $writer.AutoFlush = $true
    return $writer
}

function New-LineReader([System.IO.Stream]$Stream) {
    return [System.IO.StreamReader]::new($Stream, $script:Enc)
}

function Show-TransferProgress([long]$Done, [long]$Total, [System.Diagnostics.Stopwatch]$Sw, [ref]$LastMs) {
    if ($Done -lt $Total -and ($Sw.ElapsedMilliseconds - $LastMs.Value) -lt 200) { return }
    $LastMs.Value = $Sw.ElapsedMilliseconds
    $pct = if ($Total -gt 0) { [Math]::Round(($Done / [double]$Total) * 100, 1) } else { 100 }
    $doneMb = [Math]::Round($Done / 1MB, 2)
    $totalMb = [Math]::Round($Total / 1MB, 2)
    Write-Host -NoNewline "`r  $pct % ($doneMb MB / $totalMb MB)   "
    if ($Done -ge $Total) { Write-Host '' }
}

function Copy-ToStreamWithProgress([System.IO.Stream]$Source, [System.IO.Stream]$Dest, [long]$Total) {
    $buffer = [byte[]]::new(65536)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $lastMs = 0
    $done = 0
    while ($true) {
        $read = $Source.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) { break }
        $Dest.Write($buffer, 0, $read)
        $done += $read
        Show-TransferProgress -Done $done -Total $Total -Sw $sw -LastMs ([ref]$lastMs)
    }
}

function Receive-ExactBytes([System.IO.Stream]$Source, [System.IO.Stream]$Dest, [long]$Count) {
    $buffer = [byte[]]::new(65536)
    $remaining = $Count
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $lastMs = 0
    while ($remaining -gt 0) {
        $toRead = [Math]::Min($buffer.Length, $remaining)
        $read = $Source.Read($buffer, 0, $toRead)
        if ($read -le 0) {
            throw "Connection closed early ($($Count - $remaining) of $Count bytes received)"
        }
        $Dest.Write($buffer, 0, $read)
        $remaining -= $read
        Show-TransferProgress -Done ($Count - $remaining) -Total $Count -Sw $sw -LastMs ([ref]$lastMs)
    }
}

function Receive-PcpSession($Client, [string]$Token, [string]$Dir) {
    $stream = $Client.GetStream()
    $reader = New-LineReader $stream
    $writer = New-LineWriter $stream

    $line = $reader.ReadLine()
    if (-not $line -or -not $line.StartsWith('PCP1 ')) { return }
    if ($line.Substring(5) -ne $Token) {
        $writer.WriteLine('FAIL')
        return
    }
    $writer.WriteLine('OK')

    $modeLine = $reader.ReadLine()
    if (-not $modeLine) { return }

    if ($modeLine.StartsWith('PUT ')) {
        $parts = $modeLine.Substring(4).Split(' ', 2)
        $name = [System.IO.Path]::GetFileName((ConvertFrom-PcpHex $parts[0]))
        $size = [long]$parts[1]
        if (-not $name) {
            $writer.WriteLine('FAIL ' + (ConvertTo-PcpHex 'invalid filename'))
            return
        }
        $dest = Join-Path $Dir $name

        $writer.WriteLine('READY')
        Write-Host "Receiving $name ($size bytes) ..."
        try {
            $fs = [System.IO.File]::Create($dest)
            try {
                Receive-ExactBytes -Source $stream -Dest $fs -Count $size
            } finally {
                $fs.Dispose()
            }
            $writer.WriteLine("DONE $size")
            Write-Host "Saved to $dest"
        } catch {
            Write-Warning "Upload failed: $($_.Exception.Message)"
            $writer.WriteLine('FAIL ' + (ConvertTo-PcpHex $_.Exception.Message))
        }
    } elseif ($modeLine.StartsWith('GET ')) {
        $name = [System.IO.Path]::GetFileName((ConvertFrom-PcpHex $modeLine.Substring(4)))
        $src = Join-Path $Dir $name
        if (-not $name -or -not (Test-Path -LiteralPath $src -PathType Leaf)) {
            $writer.WriteLine('FAIL ' + (ConvertTo-PcpHex 'file not found'))
            return
        }
        $size = (Get-Item -LiteralPath $src).Length
        $writer.WriteLine("READY $size")
        Write-Host "Sending $name ($size bytes) ..."
        $fs = [System.IO.File]::OpenRead($src)
        try {
            Copy-ToStreamWithProgress -Source $fs -Dest $stream -Total $size
        } finally {
            $fs.Dispose()
        }
        Write-Host "Sent."
    }
}

function Start-PcpServer([int]$Port, [string]$Token, [string]$Dir) {
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) {
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    }
    $Dir = (Resolve-Path -LiteralPath $Dir).Path

    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $Port)
    $listener.Start()

    Write-Host "Pcp server listening on port $Port"
    Write-Host "Token: $Token"
    Write-Host "Directory: $Dir"
    Write-Host "Press Ctrl+C to stop."

    try {
        while ($true) {
            $client = $listener.AcceptTcpClient()
            try {
                Receive-PcpSession -Client $client -Token $Token -Dir $Dir
            } catch {
                Write-Warning "Session error: $($_.Exception.Message)"
            } finally {
                $client.Close()
            }
        }
    } finally {
        $listener.Stop()
    }
}

function Start-PcpClient([string]$HostName, [int]$Port, [string]$Token, [string]$SendFile, [string]$GetName, [string]$OutPath) {
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $client.Connect($HostName, $Port)
    } catch {
        Write-PcpError "Could not connect to ${HostName}:${Port}: $($_.Exception.Message)"
        exit 1
    }

    $stream = $client.GetStream()
    $writer = New-LineWriter $stream
    $reader = New-LineReader $stream

    $writer.WriteLine("PCP1 $Token")
    $resp = $reader.ReadLine()
    if ($resp -ne 'OK') {
        Write-PcpError 'Authentication failed.'
        $client.Close()
        exit 1
    }

    if ($SendFile) {
        if (-not (Test-Path -LiteralPath $SendFile -PathType Leaf)) {
            Write-PcpError "Local file not found: $SendFile"
            $client.Close()
            exit 1
        }
        $size = (Get-Item -LiteralPath $SendFile).Length
        $name = [System.IO.Path]::GetFileName($SendFile)
        $writer.WriteLine('PUT ' + (ConvertTo-PcpHex $name) + " $size")

        $resp = $reader.ReadLine()
        if ($resp -ne 'READY') {
            Write-PcpError "Server rejected upload: $(Format-PcpFail $resp)"
            $client.Close()
            exit 1
        }

        Write-Host "Uploading $SendFile -> $name ($size bytes) ..."
        $fs = [System.IO.File]::OpenRead($SendFile)
        try {
            Copy-ToStreamWithProgress -Source $fs -Dest $stream -Total $size
        } finally {
            $fs.Dispose()
        }

        $resp = $reader.ReadLine()
        if ($resp -and $resp.StartsWith('DONE')) {
            Write-Host 'Upload complete.'
        } else {
            Write-PcpError "Upload failed: $(Format-PcpFail $resp)"
            $client.Close()
            exit 1
        }
    } elseif ($GetName) {
        $writer.WriteLine('GET ' + (ConvertTo-PcpHex $GetName))
        $resp = $reader.ReadLine()
        if ($resp -and $resp.StartsWith('READY ')) {
            $size = [long]$resp.Substring(6)
            $dest = if ($OutPath) { $OutPath } else { $GetName }
            Write-Host "Downloading $GetName -> $dest ($size bytes) ..."
            $fs = [System.IO.File]::Create($dest)
            try {
                Receive-ExactBytes -Source $stream -Dest $fs -Count $size
            } finally {
                $fs.Dispose()
            }
            Write-Host 'Download complete.'
        } else {
            Write-PcpError "Download failed: $(Format-PcpFail $resp)"
            $client.Close()
            exit 1
        }
    } else {
        Write-PcpError 'Client mode requires --send or --get.'
        $client.Close()
        exit 1
    }

    $client.Close()
}

# --- Argument parsing ---

$Mode = $null
$Token = $null
$Port = $script:DefaultPort
$HostName = $null
$Dir = '.'
$SendFile = $null
$GetName = $null
$OutPath = $null

for ($i = 0; $i -lt $args.Count; $i++) {
    $a = $args[$i]
    switch ($a) {
        { $_ -in '--server', '-s' } { $Mode = 'server' }
        { $_ -in '--client', '-c' } { $Mode = 'client' }
        { $_ -in '--help', '-h' } { Show-Help; exit 0 }
        { $_ -in '--token', '-t' } {
            $i++
            if ($i -ge $args.Count) { Write-PcpError "Missing value for $a"; exit 1 }
            $Token = $args[$i]
        }
        { $_ -in '--port', '-p' } {
            $i++
            if ($i -ge $args.Count) { Write-PcpError "Missing value for $a"; exit 1 }
            if (-not [int]::TryParse($args[$i], [ref]$Port)) { Write-PcpError "Invalid port: $($args[$i])"; exit 1 }
        }
        { $_ -in '--host', '-H' } {
            $i++
            if ($i -ge $args.Count) { Write-PcpError "Missing value for $a"; exit 1 }
            $HostName = $args[$i]
        }
        { $_ -in '--dir', '-d' } {
            $i++
            if ($i -ge $args.Count) { Write-PcpError "Missing value for $a"; exit 1 }
            $Dir = $args[$i]
        }
        { $_ -in '--send', '-u' } {
            $i++
            if ($i -ge $args.Count) { Write-PcpError "Missing value for $a"; exit 1 }
            $SendFile = $args[$i]
        }
        { $_ -in '--get', '-g' } {
            $i++
            if ($i -ge $args.Count) { Write-PcpError "Missing value for $a"; exit 1 }
            $GetName = $args[$i]
        }
        { $_ -in '--out', '-o' } {
            $i++
            if ($i -ge $args.Count) { Write-PcpError "Missing value for $a"; exit 1 }
            $OutPath = $args[$i]
        }
        default {
            Write-PcpError "Unknown argument: $a"
            Show-Help
            exit 1
        }
    }
}

if (-not $Mode) {
    Show-Help
    exit 1
}

if ($Mode -eq 'server') {
    if (-not $Token) { $Token = New-RandomToken }
    Start-PcpServer -Port $Port -Token $Token -Dir $Dir
} else {
    if (-not $HostName) { Write-PcpError 'Client mode requires --host/-H'; exit 1 }
    if (-not $Token) { Write-PcpError 'Client mode requires --token/-t'; exit 1 }
    if (-not $SendFile -and -not $GetName) { Write-PcpError 'Client mode requires --send or --get'; exit 1 }
    if ($SendFile -and $GetName) { Write-PcpError 'Use only one of --send or --get at a time'; exit 1 }
    Start-PcpClient -HostName $HostName -Port $Port -Token $Token -SendFile $SendFile -GetName $GetName -OutPath $OutPath
}
