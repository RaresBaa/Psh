#!/usr/bin/env bash
# Pcp - Portable Copy
# A dependency-free file transfer companion to Psh, for Linux (Bash).
# Requires bash (uses /dev/tcp) and dd (iflag=count_bytes, status=progress).
# Server mode additionally requires 'socat' or 'nc' (netcat), since plain bash
# cannot listen on a socket.

set -u

DEFAULT_PORT=12322

show_help() {
    cat <<'EOF'
Pcp - Portable Copy

A minimal file transfer tool, companion to Psh. Run it as a server on one
machine and connect to it from the other with a shared token. No
installation required on either side (server mode needs 'socat' or 'nc').

USAGE
  pcp.sh --server [--token <token>] [--port <port>] [--dir <path>]
  pcp.sh --client --host <host> --token <token> [--port <port>] --send <file>
  pcp.sh --client --host <host> --token <token> [--port <port>] --get <name> [--out <path>]

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
  pcp.sh --server --token secret --dir /srv/shared
  pcp.sh --client --host 192.168.0.10 --token secret --send report.pdf
  pcp.sh --client --host 192.168.0.10 --token secret --get report.pdf --out ~/report.pdf

Uploaded/downloaded files are always flat inside the server's --dir - any
directory components in a name are stripped, so a transfer can never read or
write outside it.
EOF
}

# Names and error reasons travel as hex on the wire (not raw text) so that
# spaces, unicode or other bytes can never be mistaken for protocol framing.
hex_encode() {
    od -An -tx1 | tr -d ' \n'
}

hex_encode_str() {
    printf '%s' "$1" | hex_encode
}

hex_decode() {
    local hex="$1" i byte out=""
    for ((i = 0; i < ${#hex}; i += 2)); do
        byte="${hex:i:2}"
        out+="\x$byte"
    done
    printf '%b' "$out"
}

fail_reason() {
    case "$1" in
        FAIL\ *) hex_decode "${1#FAIL }" ;;
        *) printf '%s' "$1" ;;
    esac
}

rand_token() {
    if command -v od >/dev/null 2>&1 && [ -r /dev/urandom ]; then
        od -An -tx1 -N9 /dev/urandom | tr -d ' \n'
    else
        printf '%04x%04x%04x' "$RANDOM" "$RANDOM" "$RANDOM"
    fi
}

file_size() {
    stat -c %s "$1" 2>/dev/null || wc -c < "$1"
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

# Speaks the Pcp handshake on stdin/stdout, then serves one PUT or GET.
pcp_handle_session() {
    local token="$1" dir="$2"
    local line modeline

    IFS= read -r line || return 0
    line=${line%$'\r'}
    if [ "$line" != "PCP1 $token" ]; then
        printf 'FAIL\n'
        return 0
    fi
    printf 'OK\n'

    IFS= read -r modeline || return 0
    modeline=${modeline%$'\r'}

    case "$modeline" in
        PUT\ *)
            local rest name_hex size name dest got
            rest="${modeline#PUT }"
            name_hex="${rest%% *}"
            size="${rest#* }"
            if ! [[ "$size" =~ ^[0-9]+$ ]]; then
                printf 'FAIL %s\n' "$(hex_encode_str 'invalid size')"
                return 0
            fi
            name=$(basename -- "$(hex_decode "$name_hex")")
            if [ -z "$name" ] || [ "$name" = "." ] || [ "$name" = ".." ]; then
                printf 'FAIL %s\n' "$(hex_encode_str 'invalid filename')"
                return 0
            fi
            dest="$dir/$name"

            printf 'READY\n'
            echo "Receiving $name ($size bytes) ..." >&2
            dd of="$dest" bs=65536 count="$size" iflag=count_bytes status=none 2>/dev/null
            got=$(file_size "$dest")
            if [ "$got" = "$size" ]; then
                printf 'DONE %s\n' "$size"
                echo "Saved to $dest" >&2
            else
                printf 'FAIL %s\n' "$(hex_encode_str 'incomplete transfer')"
            fi
            ;;
        GET\ *)
            local name src size
            name=$(basename -- "$(hex_decode "${modeline#GET }")")
            src="$dir/$name"
            if [ -z "$name" ] || [ ! -f "$src" ]; then
                printf 'FAIL %s\n' "$(hex_encode_str 'file not found')"
                return 0
            fi
            size=$(file_size "$src")
            printf 'READY %s\n' "$size"
            echo "Sending $name ($size bytes) ..." >&2
            dd if="$src" bs=65536 status=none
            echo "Sent." >&2
            ;;
    esac
}

run_server() {
    local port="$1" token="$2" dir="$3"
    local transport
    transport=$(detect_transport)
    if [ "$transport" = none ]; then
        echo "Error: --server mode requires 'socat' or 'nc' (netcat) to be installed." >&2
        exit 1
    fi

    mkdir -p "$dir"
    dir=$(cd "$dir" && pwd)

    echo "Pcp server listening on port $port (using $transport)"
    echo "Token: $token"
    echo "Directory: $dir"
    echo "Press Ctrl+C to stop."

    local fifo
    fifo=$(mktemp -u "${TMPDIR:-/tmp}/pcp.XXXXXX")
    mkfifo "$fifo"
    trap 'rm -f "$fifo"' EXIT INT TERM

    while true; do
        listen_once "$port" "$fifo" "$transport" | pcp_handle_session "$token" "$dir" > "$fifo"
    done
}

run_client() {
    local host="$1" port="$2" token="$3" send_file="$4" get_name="$5" out_path="$6"

    if ! exec 3<>"/dev/tcp/$host/$port"; then
        echo "Error: cannot connect to $host:$port" >&2
        exit 1
    fi

    printf 'PCP1 %s\n' "$token" >&3
    local resp
    IFS= read -r resp <&3
    resp=${resp%$'\r'}
    if [ "$resp" != "OK" ]; then
        echo "Authentication failed." >&2
        exec 3<&- 3>&- 2>/dev/null
        exit 1
    fi

    if [ -n "$send_file" ]; then
        if [ ! -f "$send_file" ]; then
            echo "Error: local file not found: $send_file" >&2
            exec 3<&- 3>&- 2>/dev/null
            exit 1
        fi
        local size name
        size=$(file_size "$send_file")
        name=$(basename -- "$send_file")
        printf 'PUT %s %s\n' "$(hex_encode_str "$name")" "$size" >&3

        IFS= read -r resp <&3
        resp=${resp%$'\r'}
        if [ "$resp" != "READY" ]; then
            echo "Server rejected upload: $(fail_reason "$resp")" >&2
            exec 3<&- 3>&- 2>/dev/null
            exit 1
        fi

        echo "Uploading $send_file -> $name ($size bytes) ..."
        dd if="$send_file" bs=65536 status=progress >&3

        IFS= read -r resp <&3
        resp=${resp%$'\r'}
        case "$resp" in
            DONE\ *) echo "Upload complete." ;;
            *)
                echo "Upload failed: $(fail_reason "$resp")" >&2
                exec 3<&- 3>&- 2>/dev/null
                exit 1
                ;;
        esac
    elif [ -n "$get_name" ]; then
        printf 'GET %s\n' "$(hex_encode_str "$get_name")" >&3

        IFS= read -r resp <&3
        resp=${resp%$'\r'}
        case "$resp" in
            READY\ *)
                local size dest
                size="${resp#READY }"
                dest="${out_path:-$get_name}"
                echo "Downloading $get_name -> $dest ($size bytes) ..."
                dd of="$dest" bs=65536 count="$size" iflag=count_bytes status=progress <&3
                echo "Download complete."
                ;;
            *)
                echo "Download failed: $(fail_reason "$resp")" >&2
                exec 3<&- 3>&- 2>/dev/null
                exit 1
                ;;
        esac
    fi

    exec 3<&- 3>&- 2>/dev/null
}

# --- Argument parsing ---

MODE=""
TOKEN=""
PORT="$DEFAULT_PORT"
HOST=""
DIR="."
SEND_FILE=""
GET_NAME=""
OUT_PATH=""

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
        -d|--dir)
            [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 1; }
            DIR="$2"; shift 2 ;;
        -u|--send)
            [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 1; }
            SEND_FILE="$2"; shift 2 ;;
        -g|--get)
            [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 1; }
            GET_NAME="$2"; shift 2 ;;
        -o|--out)
            [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 1; }
            OUT_PATH="$2"; shift 2 ;;
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
    run_server "$PORT" "$TOKEN" "$DIR"
else
    if [ -z "$HOST" ]; then
        echo "Client mode requires --host/-H" >&2
        exit 1
    fi
    if [ -z "$TOKEN" ]; then
        echo "Client mode requires --token/-t" >&2
        exit 1
    fi
    if [ -z "$SEND_FILE" ] && [ -z "$GET_NAME" ]; then
        echo "Client mode requires --send or --get" >&2
        exit 1
    fi
    if [ -n "$SEND_FILE" ] && [ -n "$GET_NAME" ]; then
        echo "Use only one of --send or --get at a time" >&2
        exit 1
    fi
    run_client "$HOST" "$PORT" "$TOKEN" "$SEND_FILE" "$GET_NAME" "$OUT_PATH"
fi
