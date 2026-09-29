# Psh - Portable Shell

$ErrorActionPreference = 'Stop'

# UTF8 without BOM - a leading BOM would corrupt the very first protocol line.
$script:Enc = [System.Text.UTF8Encoding]::new($false)
$script:DefaultPort = 12321

function Write-PshError([string]$Message) {
    [Console]::Error.WriteLine($Message)
}

function Show-Help {
    @'
Psh - Portable Shell

A minimal remote-shell tool. Run it as a server on one machine and connect to
it from the other with a shared token.

USAGE
  psh.ps1 --server [--token <token>] [--port <port>]
  psh.ps1 --client --host <host> --token <token> [--port <port>] [--single <command>]

OPTIONS
  -s, --server            Run as a server, listening for incoming connections.
  -c, --client            Run as a client, connecting to a remote server.
  -H, --host <host>       Server hostname or IP to connect to (client mode).
  -t, --token <token>     Shared secret. Server generates a random one if omitted.
  -p, --port <port>       TCP port to use (default: 12321).
  -x, --single <command>  Run a single command on the remote server and exit,
                           instead of starting an interactive session.
  -h, --help              Show this help and exit.

EXAMPLES
  psh.ps1 --server --token secret --port 1234
  psh.ps1 --server
  psh.ps1 --client --host 192.168.0.10 --token secret
  psh.ps1 --client --host 192.168.0.10 --token secret --single "ls"
'@ | Write-Host
}

# The EXEC payload travels as hex on the wire (not raw text) so that
# embedded newlines or other bytes can never be mistaken for protocol
# framing - the command is opaque data until decoded on the far end.
function ConvertTo-PshHex([string]$Text) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    -join ($bytes | ForEach-Object { $_.ToString('x2') })
}

function ConvertFrom-PshHex([string]$Hex) {
    if (-not $Hex) { return '' }
    $bytes = [byte[]]::new($Hex.Length / 2)
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $bytes[$i] = [Convert]::ToByte($Hex.Substring($i * 2, 2), 16)
    }
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

function New-RandomToken {
    $bytes = [byte[]]::new(9)
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $clean = ([Convert]::ToBase64String($bytes) -replace '[^a-zA-Z0-9]', '')
    while ($clean.Length -lt 12) { $clean += [Guid]::NewGuid().ToString('N') }
    return $clean.Substring(0, 12)
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

function Invoke-RemoteCommand {
    param([string]$Command, [System.IO.StreamWriter]$Writer)

    # With the child's stdout/stderr redirected, PowerShell serializes the
    # progress/error/warning streams as CLIXML instead of plain text. Folding
    # everything through Out-String inside the child keeps it plain text
    # before it ever reaches a redirected stream. Console]::OutputEncoding
    # must also be forced to UTF-8: it otherwise defaults to the system
    # codepage, which mangles non-Latin1 characters (CJK, emoji, ...) into
    # '?' before the bytes ever leave the child process.
    $fullCommand = "[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new(`$false); `$ProgressPreference = 'SilentlyContinue'; & { $Command } 2>&1 | Out-String -Width 4096"
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($fullCommand))

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = "-NoLogo -NoProfile -NonInteractive -EncodedCommand $encoded"
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()

    if ($stdout) { $Writer.Write($stdout) }
    if ($stderr) { $Writer.Write($stderr) }
    $Writer.WriteLine()
    $Writer.WriteLine("__PSH_EOF__$($proc.ExitCode)")
}

if (-not ('Psh.AutoFlushStream' -as [type])) {
    Add-Type -TypeDefinition @'
using System.IO;
using System.Threading;
using System.Threading.Tasks;
namespace Psh {
    // Process.StandardInput.BaseStream buffers writes internally, and
    // Stream.CopyToAsync never flushes between chunks - without this, bytes
    // written to the child's stdin pipe can sit unseen by the child
    // indefinitely. This wrapper flushes after every write.
    public class AutoFlushStream : Stream {
        private readonly Stream _inner;
        public AutoFlushStream(Stream inner) { _inner = inner; }
        public override bool CanRead { get { return _inner.CanRead; } }
        public override bool CanSeek { get { return false; } }
        public override bool CanWrite { get { return _inner.CanWrite; } }
        public override long Length { get { throw new System.NotSupportedException(); } }
        public override long Position {
            get { throw new System.NotSupportedException(); }
            set { throw new System.NotSupportedException(); }
        }
        public override void Flush() { _inner.Flush(); }
        public override int Read(byte[] buffer, int offset, int count) { return _inner.Read(buffer, offset, count); }
        public override long Seek(long offset, SeekOrigin origin) { throw new System.NotSupportedException(); }
        public override void SetLength(long value) { throw new System.NotSupportedException(); }
        public override void Write(byte[] buffer, int offset, int count) { _inner.Write(buffer, offset, count); _inner.Flush(); }
        public override async Task WriteAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) {
            await _inner.WriteAsync(buffer, offset, count, cancellationToken).ConfigureAwait(false);
            await _inner.FlushAsync(cancellationToken).ConfigureAwait(false);
        }
    }
}
'@
}

function Start-ShellRelay([System.IO.Stream]$Stream) {
    # Console encoding defaults to the system codepage, which mangles
    # non-Latin1 input/output (CJK, emoji, ...). Forcing UTF-8 here - via
    # -EncodedCommand to dodge quoting entirely - keeps the raw byte relay
    # below faithful to whatever the user actually typed or sees.
    $startupCommand = "`$ProgressPreference = 'SilentlyContinue'; [Console]::InputEncoding = [System.Text.UTF8Encoding]::new(`$false); [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new(`$false)"
    $startupEncoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($startupCommand))

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = "-NoLogo -NoProfile -NoExit -EncodedCommand $startupEncoded"
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    $procStdin = [Psh.AutoFlushStream]::new($proc.StandardInput.BaseStream)

    $outTask = $proc.StandardOutput.BaseStream.CopyToAsync($Stream)
    $errTask = $proc.StandardError.BaseStream.CopyToAsync($Stream)
    $inTask = $Stream.CopyToAsync($procStdin)

    while (-not $proc.HasExited -and -not $outTask.IsCompleted -and -not $inTask.IsCompleted) {
        Start-Sleep -Milliseconds 150
    }

    if (-not $proc.HasExited) {
        try { $proc.Kill() } catch {}
    }
}

function Receive-PshSession($Client, [string]$Token) {
    $stream = $Client.GetStream()
    $reader = New-LineReader $stream
    $writer = New-LineWriter $stream

    $line = $reader.ReadLine()
    if (-not $line -or -not $line.StartsWith('PSH1 ')) { return }

    $clientToken = $line.Substring(5)
    if ($clientToken -ne $Token) {
        $writer.WriteLine('FAIL')
        return
    }
    $writer.WriteLine('OK')

    $modeLine = $reader.ReadLine()
    if (-not $modeLine) { return }

    if ($modeLine -eq 'SHELL') {
        Start-ShellRelay -Stream $stream
    } elseif ($modeLine.StartsWith('EXEC ')) {
        $cmd = ConvertFrom-PshHex $modeLine.Substring(5)
        Invoke-RemoteCommand -Command $cmd -Writer $writer
    }
}

function Start-PshServer([int]$Port, [string]$Token) {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $Port)
    $listener.Start()

    Write-Host "Psh server listening on port $Port"
    Write-Host "Token: $Token"
    Write-Host "Press Ctrl+C to stop."

    try {
        while ($true) {
            $client = $listener.AcceptTcpClient()
            try {
                Receive-PshSession -Client $client -Token $Token
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

function Start-PshClient([string]$HostName, [int]$Port, [string]$Token, [string]$SingleCmd) {
    # Best-effort: legacy console hosts default to the system codepage, which
    # would otherwise mis-render the UTF-8 text the server now sends back.
    try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch {}

    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $client.Connect($HostName, $Port)
    } catch {
        Write-PshError "Could not connect to ${HostName}:${Port}: $($_.Exception.Message)"
        exit 1
    }

    $stream = $client.GetStream()
    $writer = New-LineWriter $stream
    $reader = New-LineReader $stream

    $writer.WriteLine("PSH1 $Token")
    $resp = $reader.ReadLine()
    if ($resp -ne 'OK') {
        Write-PshError 'Authentication failed.'
        $client.Close()
        exit 1
    }

    if ($SingleCmd) {
        $writer.WriteLine("EXEC " + (ConvertTo-PshHex $SingleCmd))
        $exitCode = 0
        while ($null -ne ($line = $reader.ReadLine())) {
            if ($line -match '^__PSH_EOF__(-?\d+)$') {
                $exitCode = [int]$Matches[1]
                break
            }
            Write-Output $line
        }
        $client.Close()
        exit $exitCode
    } else {
        $writer.WriteLine('SHELL')
        Write-Host "Connected. Interactive session started (Ctrl+C to exit)."
        $stdin = [Console]::OpenStandardInput()
        $stdout = [Psh.AutoFlushStream]::new([Console]::OpenStandardOutput())

        $outTask = $stream.CopyToAsync($stdout)
        $inTask = $stdin.CopyToAsync($stream)

        # Wait specifically for the server to close its side (outTask). If
        # local stdin reaches EOF first (e.g. piped input), keep receiving
        # any remaining output instead of tearing the connection down early.
        while (-not $outTask.IsCompleted) {
            Start-Sleep -Milliseconds 150
        }
        $client.Close()
        Write-Host "`nConnection closed."
    }
}

# --- Argument parsing ---

$Mode = $null
$Token = $null
$Port = $script:DefaultPort
$HostName = $null
$SingleCmd = $null

for ($i = 0; $i -lt $args.Count; $i++) {
    $a = $args[$i]
    switch ($a) {
        { $_ -in '--server', '-s' } { $Mode = 'server' }
        { $_ -in '--client', '-c' } { $Mode = 'client' }
        { $_ -in '--help', '-h' } { Show-Help; exit 0 }
        { $_ -in '--token', '-t' } {
            $i++
            if ($i -ge $args.Count) { Write-PshError "Missing value for $a"; exit 1 }
            $Token = $args[$i]
        }
        { $_ -in '--port', '-p' } {
            $i++
            if ($i -ge $args.Count) { Write-PshError "Missing value for $a"; exit 1 }
            if (-not [int]::TryParse($args[$i], [ref]$Port)) { Write-PshError "Invalid port: $($args[$i])"; exit 1 }
        }
        { $_ -in '--host', '-H' } {
            $i++
            if ($i -ge $args.Count) { Write-PshError "Missing value for $a"; exit 1 }
            $HostName = $args[$i]
        }
        { $_ -in '--single', '-x' } {
            $i++
            if ($i -ge $args.Count) { Write-PshError "Missing value for $a"; exit 1 }
            $SingleCmd = $args[$i]
        }
        default {
            Write-PshError "Unknown argument: $a"
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
    Start-PshServer -Port $Port -Token $Token
} else {
    if (-not $HostName) { Write-PshError 'Client mode requires --host/-H'; exit 1 }
    if (-not $Token) { Write-PshError 'Client mode requires --token/-t'; exit 1 }
    Start-PshClient -HostName $HostName -Port $Port -Token $Token -SingleCmd $SingleCmd
}
