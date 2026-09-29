# Psh

Dependency-free remote tools for hopping between two of your own machines.
Run one script as a server, the other as a client, share a token.
Two standalone tool pairs, each with a pure PowerShell and a pure Bash 
implementation that speak the same wire protocol:

- **[Psh](#psh--portable-shell)** — a remote shell, continuous or one-shot.
- **[Pcp](#pcp--portable-copy)** — file transfer, upload or download.

## Psh — Portable Shell

- **Windows**: [`psh.ps1`](psh.ps1) — pure PowerShell, built entirely on .NET sockets.
- **Linux**: [`psh.sh`](psh.sh) — pure Bash, using `/dev/tcp` for the client. The
  server needs `socat` or `nc` already on the box.

Both speak the same wire protocol, so a Windows client can drive a Linux
server and vice versa.

### Usage

```
psh.ps1 --server [--token <token>] [--port <port>]
psh.sh  --server [--token <token>] [--port <port>]

psh.ps1 --client --host <host> --token <token> [--port <port>] [--single <command>]
psh.sh  --client --host <host> --token <token> [--port <port>] [--single <command>]
```

```sh
# Start a server with an explicit token and port
psh.ps1 --server --token secret --port 1234

# Start a server on the default port (12321) with a random token, printed on start
psh.sh --server

# Open an interactive session, like ssh
psh.sh --client --host 192.168.0.10 --token secret

# Run one command on the remote machine and print its output
psh.ps1 --client --host 192.168.0.10 --token secret --single "ls"
```

### Options

| Flag | Short | Description |
|---|---|---|
| `--server` | `-s` | Run as a server, listening for connections. |
| `--client` | `-c` | Run as a client, connecting to a server. |
| `--host <host>` | `-H` | Server hostname/IP (client mode). |
| `--token <token>` | `-t` | Shared secret. Server generates a random one if omitted. |
| `--port <port>` | `-p` | TCP port (default `12321`). |
| `--single <command>` | `-x` | Run one command remotely and exit, instead of an interactive session. |
| `--help` | `-h` | Show usage. |

### How it works

The server listens on a TCP port; a client connects and sends a shared
token. If it matches, the client either opens a live shell on the server
(raw stdin/stdout passthrough, close to what SSH gives you) or sends a
single command and gets its combined stdout+stderr and exit code back.

## Pcp — Portable Copy

- **Windows**: [`pcp.ps1`](pcp.ps1) — pure PowerShell.
- **Linux**: [`pcp.sh`](pcp.sh) — pure Bash. The server needs `socat` or `nc` 
;the client additionally uses `dd` for byte-exact transfer.

Standalone from Psh with the default port `12322` so both servers can run 
on the same machine at once.

### Usage

```
pcp.ps1 --server [--token <token>] [--port <port>] [--dir <path>]
pcp.sh  --server [--token <token>] [--port <port>] [--dir <path>]

pcp.ps1 --client --host <host> --token <token> --send <file>
pcp.sh  --client --host <host> --token <token> --get <name> [--out <path>]
```

```sh
# Start a server, storing uploads in / serving downloads from ./shared
pcp.sh --server --token secret --dir ./shared

# Upload a file to it
pcp.ps1 --client --host 192.168.0.10 --token secret --send report.pdf

# Download a file from it
pcp.ps1 --client --host 192.168.0.10 --token secret --get report.pdf --out C:\Downloads\report.pdf
```

### Options

| Flag | Short | Description |
|---|---|---|
| `--server` | `-s` | Run as a server, listening for connections. |
| `--client` | `-c` | Run as a client, connecting to a server. |
| `--host <host>` | `-H` | Server hostname/IP (client mode). |
| `--token <token>` | `-t` | Shared secret. Server generates a random one if omitted. |
| `--port <port>` | `-p` | TCP port (default `12322`). |
| `--dir <path>` | `-d` | Server-side directory to store uploads in / serve downloads from (default: current directory). |
| `--send <file>` | `-u` | Upload this local file to the server. |
| `--get <name>` | `-g` | Download this file, by name, from the server. |
| `--out <path>` | `-o` | Local destination path for `--get` (default: same name, current directory). |
| `--help` | `-h` | Show usage. |

Uploaded/downloaded files are always flat inside the server's `--dir` — any
directory components in a requested name are stripped, so a transfer can
never read or write outside it.

## Security note

Both tools are convenience utilities for trusted networks (e.g. your own LAN
or a VPN you already control), not a replacement for SSH/SCP. Connections
are **unencrypted** — the token proves you know the secret, but traffic
isn't protected against anyone who can already see your network. Don't
expose the port to the open internet.

## License

[MIT](LICENSE)
