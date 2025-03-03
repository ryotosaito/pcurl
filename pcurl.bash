#!/bin/bash

help() {
	cat <<- EOF
	cURL clone made using only bash
	Usage: $0 [options]... <url>
	 -A <name>   Send User-Agent <name> to Server
	 -H <header> Insert HTTP Header
	 -o <file>   Output Response to OUTPUT file
	 -v          Verbose output
	EOF
	exit
}

send() {
	if $VERBOSE
	then
		echo -e "> $1" >&2
	fi
	echo -en "$1\r\n"
}

# Parse URL parameter and print as `declare -p return`
# URL=http://www.example.com:80/index.html
# SCHEME=http (default: http), unused value
# HOST=www.example.com
# PORT=80 (default:80)
# PATH=/index.html (default: /)
parse_url() {
	URL="$1"
	SCHEME="${URL%://*}"
	# Default scheme is "http"
	[[ "$SCHEME" == "$URL" ]] && SCHEME=http
	TMP="${URL#*://}"

	# Append slash if path (/) not contained
	TMP_REMOVE_SLASH="${TMP/\//}"
	[[ ${#TMP} -eq ${#TMP_REMOVE_SLASH} ]] && TMP="$TMP/"

	HOST_PORT="${TMP%%/*}"
	HOST="${HOST_PORT%%:*}"
	PORT_TMP="${HOST_PORT#+([^:]):}"
	if [[ ${#HOST} -eq ${#PORT_TMP} ]]
	then
		PORT=80
	else
		declare -i PORT=$PORT_TMP
	fi
	PATH="/${TMP#*/}"

	local -A return=(
		[URL]="$URL"
		[SCHEME]="$SCHEME"
		[HOST]="$HOST"
		[PORT]="$PORT"
		[PATH]="$PATH"
	)
	echo "$(declare -p return)"
}
###############################################
# Main
###############################################
declare -A HEADERS=(
	[Accept-Encoding]="identity"
	[Connection]="Close"
)
METHOD="GET"
VERBOSE=false

while getopts A:H:o:vx: OPT; do
	case "$OPT" in
		A)
			HEADERS["User-Agent"]="$OPTARG" ;;
		H)
			# TODO: Header format validation
			HEADERS[${OPTARG%%:*}]="${OPTARG#*: }" ;;
		o)
			OUTPUT="$OPTARG";;
		v)
			VERBOSE=true;;
		x)
			PROXY="$OPTARG" ;;
		*) exit 1 ;;
	esac
done
shift $((OPTIND - 1))

if [[ $# -eq 0 ]]
then
	help
	exit 1
fi

# Parse URL and set variable TARGET
if [[ -v PROXY ]]
then
	url_parsed="$(parse_url "$PROXY")"
	echo $url_parsed
	eval "${url_parsed/return/PROXY_TARGET}"
fi

# Parse URL and set variable TARGET
url_parsed="$(parse_url "$1")"
eval "${url_parsed/return/TARGET}"

[[ -v HEADERS[Host] ]] || HEADERS[Host]="${TARGET[HOST]}"

# Copy original stdout
exec {stdout}>&1

# Connect peer
if [[ -v PROXY ]]
then
	exec {peer}<>"/dev/tcp/${PROXY_TARGET[HOST]}/${PROXY_TARGET[PORT]}"
else
	exec {peer}<>"/dev/tcp/${TARGET[HOST]}/${TARGET[PORT]}"
fi
exec >&"$peer"

# Send HTTP Request
if [[ -v PROXY ]]
then
	send "$METHOD ${TARGET[URL]} HTTP/1.0"
else
	send "$METHOD ${TARGET[PATH]} HTTP/1.0"
fi

for key in "${!HEADERS[@]}"
do
	send "$key: ${HEADERS[$key]}"
done
send ""
exec >&"$stdout"
# End of HTTP Request

# Parse HTTP Response Header
exec <&"$peer"
read LINE
$VERBOSE && echo "< $LINE" >&2
RESP_STATUS="${LINE#HTTP/1.1 }"

while true
do
	read LINE
	[[ "$LINE" == $'\r' ]] && break
	$VERBOSE && echo "< $LINE" >&2
done
# End of HTTP Response Header

# Response body
[[ -v OUTPUT ]] && exec >"$OUTPUT"
cat <&"$peer"
