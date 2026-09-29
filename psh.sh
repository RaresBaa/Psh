#!/usr/bin/env bash
# Psh - Portable Shell
# A dependency-free remote shell for Linux (Bash) <-> Windows (PowerShell) pairs.
# See psh.ps1 for the PowerShell counterpart. Wire protocol is shared between both.
#
# Requires bash (uses /dev/tcp). Server mode additionally requires 'socat' or
# 'nc' (netcat) to be installed, since plain bash cannot listen on a socket.

set -u

DEFAULT_PORT=12321

show_help() {
    cat <<'EOF'
Psh - Portable Shell

A minimal remote-shell tool. Run it as a server on one machine and connect to
it from the other with a shared token. No installation required on either
side (server mode needs 'socat' or 'nc' already present).

USAGE
  psh.sh --server [--token <token>] [--port <port>]
  psh.sh --client --host <host> --token <token> [--port <port>] [--single <command>]

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
  psh.sh --server --token secret --port 1234
  psh.sh --server
  psh.sh --client --host 192.168.0.10 --token secret
  psh.sh --client --host 192.168.0.10 --token secret --single "ls"
EOF
}

# The EXEC payload travels as hex on the wire (not raw text) so that
# embedded newlines or other bytes can never be mistaken for protocol
# framing - the command is opaque data until decoded on the far end.
hex_encode() {
    od -An -tx1 | tr -d ' \n'
}

hex_decode() {
    local hex="$1" i byte out=""
    for ((i = 0; i < ${#hex}; i += 2)); do
        byte="${hex:i:2}"
        out+="\x$byte"
    done
    printf '%b' "$out"
}

rand_token() {
    if command -v od >/dev/null 2>&1 && [ -r /dev/urandom ]; then
        od -An -tx1 -N9 /dev/urandom | tr -d ' \n'
    else
        printf '%04x%04x%04x' "$RANDOM" "$RANDOM" "$RANDOM"
    fi
}

detect_transport() {
    if command -v socat >/dev/null 2>&1; then
        echo socat
    elif command -v nc >/dev/null 2>&1; then
        echo nc
    else
        echo none
    fi
}

# Runs one accept-and-serve cycle; its stdout is the bytes to send back over
# the network, its stdin is the bytes received from the network.
listen_once() {
    local port="$1" fifo="$2" transport="$3"
    case "$transport" in
        socat)
            socat TCP-LISTEN:"$port",reuseaddr - < "$fifo"
            ;;
        nc)
            if nc -h 2>&1 | grep -q -- '-p '; then
                nc -l -p "$port" < "$fifo"
            else
                nc -l "$port" < "$fifo"
            fi
            ;;
    esac
}

# Speaks the Psh handshake on stdin/stdout, then either hands off to an
# interactive shell (raw passthrough) or runs a single command and returns.
psh_handle_session() {
    local token="$1"
    local line modeline cmd output code

    IFS= read -r line || return 0
    line=${line%$'\r'}
    if [ "$line" != "PSH1 $token" ]; then
        printf 'FAIL\n'
        return 0
    fi
    printf 'OK\n'

    IFS= read -r modeline || return 0
    modeline=${modeline%$'\r'}

    case "$modeline" in
        SHELL)
            # Without this, stderr stays on whatever fd 2 the server script
            # itself inherited (its own terminal) instead of going back over
            # the network - the remote user would never see command errors.
            exec bash -i 2>&1
            ;;
        EXEC\ *)
            cmd=$(hex_decode "${modeline#EXEC }")
            output=$(bash -c "$cmd" 2>&1)
            code=$?
            printf '%s\n' "$output"
            printf '__PSH_EOF__%d\n' "$code"
            ;;
    esac
}

run_server() {
    local port="$1" token="$2"
    local transport
    transport=$(detect_transport)
    if [ "$transport" = none ]; then
        echo "Error: --server mode requires 'socat' or 'nc' (netcat) to be installed." >&2
        exit 1
    fi

    echo "Psh server listening on port $port (using $transport)"
    echo "Token: $token"
    echo "Press Ctrl+C to stop."

    local fifo
    fifo=$(mktemp -u "${TMPDIR:-/tmp}/psh.XXXXXX")
    mkfifo "$fifo"
    trap 'rm -f "$fifo"' EXIT INT TERM

    while true; do
        listen_once "$port" "$fifo" "$transport" | psh_handle_session "$token" > "$fifo"
    done
}

run_client() {
    local host="$1" port="$2" token="$3" single_cmd="$4"

    if ! exec 3<>"/dev/tcp/$host/$port"; then
        echo "Error: cannot connect to $host:$port" >&2
        exit 1
    fi

    printf 'PSH1 %s\n' "$token" >&3
    local resp
    IFS= read -r resp <&3
    resp=${resp%$'\r'}
    if [ "$resp" != "OK" ]; then
        echo "Authentication failed." >&2
        exec 3<&- 3>&- 2>/dev/null
        exit 1
    fi

    if [ -n "$single_cmd" ]; then
        printf 'EXEC %s\n' "$(printf '%s' "$single_cmd" | hex_encode)" >&3
        local line code=0
        while IFS= read -r line <&3; do
            line=${line%$'\r'}
            case "$line" in
                __PSH_EOF__*)
                    code="${line#__PSH_EOF__}"
                    break
                    ;;
                *)
                    printf '%s\n' "$line"
                    ;;
            esac
        done
        exec 3<&- 3>&- 2>/dev/null
        exit "${code:-0}"
    else
        printf 'SHELL\n' >&3
        echo "Connected. Interactive session started (Ctrl-D or Ctrl-C to exit)."
        cat <&3 &
        local catpid=$!
        trap 'kill "$catpid" 2>/dev/null; exec 3<&- 3>&- 2>/dev/null' EXIT INT TERM
        cat >&3
        kill "$catpid" 2>/dev/null
        exec 3<&- 3>&- 2>/dev/null
    fi
}

# --- Argument parsing ---

MODE=""
TOKEN=""
PORT="$DEFAULT_PORT"
HOST=""
SINGLE_CMD=""

while [ $# -gt 0 ]; do
    case "$1" in
        -s|--server) MODE="server"; shift ;;
        -c|--client) MODE="client"; shift ;;
        -h|--help) show_help; exit 0 ;;
        -t|--token)
            [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 1; }
            TOKEN="$2"; shift 2 ;;
        -p|--port)
            [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 1; }
            PORT="$2"; shift 2 ;;
        -H|--host)
            [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 1; }
            HOST="$2"; shift 2 ;;
        -x|--single)
            [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 1; }
            SINGLE_CMD="$2"; shift 2 ;;
        *)
            echo "Unknown argument: $1" >&2
            show_help
            exit 1
            ;;
    esac
done

if [ -z "$MODE" ]; then
    show_help
    exit 1
fi

if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then
    echo "Invalid port: $PORT" >&2
    exit 1
fi

if [ "$MODE" = "server" ]; then
    [ -n "$TOKEN" ] || TOKEN=$(rand_token)
    run_server "$PORT" "$TOKEN"
else
    if [ -z "$HOST" ]; then
        echo "Client mode requires --host/-H" >&2
        exit 1
    fi
    if [ -z "$TOKEN" ]; then
        echo "Client mode requires --token/-t" >&2
        exit 1
    fi
    run_client "$HOST" "$PORT" "$TOKEN" "$SINGLE_CMD"
fi
