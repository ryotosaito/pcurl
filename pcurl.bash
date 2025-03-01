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

###############################################
# Main
###############################################
declare -A HEADERS=(
	[Accept-Encoding]="identity"
	[Connection]="Close"
)
METHOD="GET"
VERBOSE=false

while getopts A:H:o:v OPT; do
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
		*) exit 1 ;;
	esac
done
shift $((OPTIND - 1))

if [[ $# -eq 0 ]]
then
	help
	exit 1
fi
# URL parsing is not perfect.
URL="$1"
URL_SCHEME="${URL%://*}"
TMP="${URL#*://}"

# Append slash if path (/) not contained
TMP_REMOVE_SLASH="${TMP/\//}"
[[ ${#TMP} -eq ${#TMP_REMOVE_SLASH} ]] && TMP="$TMP/" 

URL_HOST="${TMP%%/*}"
HOST="${URL_HOST%%:*}"
PORT_TMP="${URL_HOST/#+([^:]):/}"
if [[ ${#HOST} -eq ${#PORT_TMP} ]]
then
	PORT=80
else
	declare -i PORT=$PORT_TMP
fi
URL_PATH="/${TMP#*/}"

[[ -v HEADERS[Host] ]] || HEADERS[Host]="$HOST"

# Copy original stdout
exec {stdout}>&1

# Connect peer
exec {peer}<>"/dev/tcp/$HOST/$PORT"
exec >&"$peer"

# Send HTTP Request
send "$METHOD $URL_PATH HTTP/1.0"
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
