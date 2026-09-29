# Psh — Portable Shell

A dependency-free remote shell for hopping between two of your own machines.
Run one script as a server, the other as a client, share a token, and you get
either a continuous interactive session or a single remote command.

- **Windows**: [`psh.ps1`](psh.ps1) — pure PowerShell, built entirely on .NET sockets.
- **Linux**: [`psh.sh`](psh.sh) — pure Bash, using `/dev/tcp` for the client. The
  server needs `socat` or `nc` already on the box.

Both speak the same wire protocol, so a Windows client can drive a Linux
server and vice versa.

## Usage

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

## Options

| Flag | Short | Description |
|---|---|---|
| `--server` | `-s` | Run as a server, listening for connections. |
| `--client` | `-c` | Run as a client, connecting to a server. |
| `--host <host>` | `-H` | Server hostname/IP (client mode). |
| `--token <token>` | `-t` | Shared secret. Server generates a random one if omitted. |
| `--port <port>` | `-p` | TCP port (default `12321`). |
| `--single <command>` | `-x` | Run one command remotely and exit, instead of an interactive session. |
| `--help` | `-h` | Show usage. |

## How it works

The server listens on a TCP port; a client connects and sends a shared
token. If it matches, the client either opens a live shell on the server
(raw stdin/stdout passthrough, close to what SSH gives you) or sends a
single command and gets its combined stdout+stderr and exit code back.

## Security note

Psh is a convenience tool for trusted networks (e.g. your own LAN or a VPN
you already control), not a replacement for SSH. The connection is
**unencrypted** — the token proves you know the secret, but traffic isn't
protected against anyone who can already see your network. Don't expose the
port to the open internet.

## License

[MIT](LICENSE)
