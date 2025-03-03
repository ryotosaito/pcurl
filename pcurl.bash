#!/bin/bash -Ceu

shopt -s extglob

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
	if [[ "$SCHEME" == "$URL" ]]
	then
		SCHEME=http
	fi
	if [[ "$SCHEME" != http ]]
	then
		echo "HTTP is the only supported scheme (given: $SCHEME)" >&2
		exit 1
	fi
	TMP="${URL#*://}"

	# Append slash if path (/) not contained
	TMP_REMOVE_SLASH="${TMP/\//}"
	[[ ${#TMP} -eq ${#TMP_REMOVE_SLASH} ]] && TMP="$TMP/"

	HOST_PORT="${TMP%%/*}"
	HOST="${HOST_PORT%%:*}"
	PORT_TMP="${HOST_PORT#+([^:]):}"
	if [[ "${HOST}" == "${PORT_TMP}" ]]
	then
		PORT=80
	else
		declare -i PORT=$PORT_TMP
	fi
	PATH="/${TMP#*/}"
	# Remove hash from PATH
	PATH="${PATH%#*}"

	local -A return=(
		[URL]="$URL"
		[SCHEME]="$SCHEME"
		[HOST]="$HOST"
		[PORT]="$PORT"
		[PATH]="$PATH"
	)
	echo "$(declare -p return)"
}

http_request() {
	# init
	REDIRECT_URL=
	# Parse URL and set variable TARGET
	url_parsed="$(parse_url "$1")"
	if [[ -z "$url_parsed" ]]
	then
		exit 1
	fi
	eval "${url_parsed/return/TARGET}"
	[[ -v HEADERS[Host] ]] || HEADERS[Host]="${TARGET[HOST]}"

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
	if $VERBOSE
	then
		echo "< $LINE" >&2
	fi
	RESP_STATUS="${LINE#HTTP/1.1 }"

	while true
	do
		read LINE
		if [[ "$LINE" == $'\r' ]]
		then
			break
		fi
		if $VERBOSE
		then
			echo "< $LINE" >&2
		fi
		if [[ "${LINE%%:*}" == "Location" ]]
		then
			REDIRECT_URL="${LINE#Location:+( )}"
			REDIRECT_URL="${REDIRECT_URL%$'\r'}"
		fi
	done
	# End of HTTP Response Header

	# Response body
	if [[ -v OUTPUT ]]
	then
		exec >"$OUTPUT"
	fi
	if ! $LOCATION || [[ -z "$REDIRECT_URL" ]]
	then
		cat <&"$peer"
	fi
}

###############################################
# Main
###############################################
declare -A HEADERS=(
	[Accept-Encoding]="identity"
	[Connection]="Close"
	[User-Agent]="curl"
)
METHOD="GET"
VERBOSE=false
LOCATION=false

while getopts A:H:Lo:vx: OPT; do
	case "$OPT" in
		A)
			HEADERS["User-Agent"]="$OPTARG" ;;
		H)
			# TODO: Header format validation
			HEADERS[${OPTARG%%:*}]="${OPTARG#*: }" ;;
		L)
			LOCATION=true;;
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
	eval "${url_parsed/return/PROXY_TARGET}"
fi

# Copy original stdout
exec {stdout}>&1

http_request "$1"
while $LOCATION && [[ -n "$REDIRECT_URL" ]]
do
	http_request "$REDIRECT_URL"
done
