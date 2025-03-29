#!/bin/bash -Ceu

shopt -s extglob

pcat() {
	read -d '' input || true
	echo "$input"
}


help() {
	pcat <<- EOF
	cURL clone made using only bash
	Usage: $0 [options]... <url>
	 -A, --user-agent <name>                Send User-Agent <name> to Server
	 -d, --data <data>                      HTTP POST data
	 -H, --header <header>                  Insert HTTP Header
	 -h, --help                             Print help
	 -L, --location                         Continue request after receiving Location header
	 -o, --output <file>                    Output Response to OUTPUT file
	 -v, --verbose                          Verbose output
	 -X, --request <method>                 Request using <method>
	 -x, --proxy <proxy>                    Use proxy
	 --connect-to <host1:port1:host2:port2> connect to host2:port2 instead
	EOF
}

debug_echo() {
	if $VERBOSE
	then
		echo "$@" >&2
	fi
}

send_peer() {
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
	declare -p return
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
		HOST="${PROXY_TARGET[HOST]}"
		PORT="${PROXY_TARGET[PORT]}"
	else
		if [[ -v connect_to ]] && [[ "${TARGET[HOST]}:${TARGET[PORT]}" = "${connect_to[0]}:${connect_to[1]}" ]]
		then
			HOST="${connect_to[2]}"
			PORT="${connect_to[3]}"
			debug_echo "* Connecting to hostname: $HOST"
			debug_echo "* Connecting to port: $PORT"
		else
			HOST="${TARGET[HOST]}"
			PORT="${TARGET[PORT]}"
		fi
	fi
	debug_echo "*   Trying $HOST:$PORT..."
	exec {peer}<>"/dev/tcp/$HOST/$PORT"
	exec >&"$peer"
	debug_echo "* Connected to $HOST port $PORT (#$CONN_COUNT)"


	# Send HTTP Request
	if [[ -v PROXY ]]
	then
		if [[ "${TARGET[HOST]}:${TARGET[PORT]}" = "${connect_to[0]}:${connect_to[1]}" ]]
		then
			# Use CONNECT method when mixing --connect-to option and --proxy option
			send_peer "CONNECT ${connect_to[2]}:${connect_to[3]} HTTP/1.0"
			send_peer "Host: ${connect_to[2]}:${connect_to[3]}"
			send_peer "User-Agent: ${HEADERS[User-Agent]}"
			send_peer ""
			exec >&"$stdout"
			# End of HTTP CONNECT Request

			# Parse HTTP Response Header
			exec <&"$peer"
			read LINE
			if $VERBOSE
			then
				echo "< $LINE" >&2
			fi
			RESP_STATUS="${LINE##HTTP/+([[:digit:].]) }"
			RESP_STATUS=${RESP_STATUS%$'\r'}
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
			done
			debug_echo "* Proxy replied ${RESP_STATUS%% *} to CONNECT request"
			debug_echo "* CONNECT phase completed!"
			if [[ $(( ${RESP_STATUS%% *} / 100)) -gt 2 ]]
			then
				debug_echo "curl: (56) Received HTTP code $RESP_STATUS from proxy after CONNECT"
				exec >&$peer-
				debug_echo "* Connection $CONN_COUNT closed"
				exit
			fi
			exec >&"$peer"
			send_peer "$METHOD ${TARGET[PATH]} HTTP/1.0"
		else
			# Access via proxy
			send_peer "$METHOD ${TARGET[URL]} HTTP/1.0"
		fi
	else
		# Direct access
		send_peer "$METHOD ${TARGET[PATH]} HTTP/1.0"
	fi

	for key in "${!HEADERS[@]}"
	do
		send_peer "$key: ${HEADERS[$key]}"
	done
	send_peer ""
	if [[ -v data ]]
	then
		echo -n "$data"
	fi
	exec >&"$stdout"
	# End of HTTP Request

	# Parse HTTP Response Line
	exec <&"$peer"
	read LINE
	if $VERBOSE
	then
		echo "< $LINE" >&2
	fi
	RESP_STATUS="${LINE##HTTP/+([[:digit:].]) }"
	RESP_STATUS=${RESP_STATUS%$'\r'}

	# Parse HTTP Response Header
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
		# Parse Location header for redirection
		if [[ "${LINE%%:*}" == "Location" ]]
		then
			# RFC1945
			# Each header field consists of a name followed immediately by a colon (":"), a single space (SP) character, and the field value.
			REDIRECT_URL="${LINE#Location: }"
			REDIRECT_URL="${REDIRECT_URL%$'\r'}"
			if [[ "$REDIRECT_URL" =~ ^/ ]]
			then
				REDIRECT_URL="${TARGET[SCHEME]}://${TARGET[HOST]}:${TARGET[PORT]}$REDIRECT_URL"
			fi
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
		pcat <&"$peer"
	fi

	debug_echo "* Connection $CONN_COUNT closed"
	CONN_COUNT+=1
}

###############################################
# Main
###############################################
declare -i CONN_COUNT=0
declare -A HEADERS=(
	[Accept-Encoding]="identity"
	[Connection]="Close"
	[User-Agent]="curl"
)
VERBOSE=false
LOCATION=false

while getopts AdHhLovXx-: OPT
do
	if [[ $OPTIND -le $# ]]
	then
		optarg="${!OPTIND}"
	fi
	if [[ "$OPT" = - ]]
	then
		OPT="-$OPTARG"
	fi
	case "-$OPT" in
		-A|--user-agent)
			HEADERS["User-Agent"]="$optarg"
			shift
			;;
		--connect-to)
			declare -a connect_to=(${optarg//:/ })
			shift
			;;
		-d|--data)
			data="$optarg"
			shift
			;;
		-H|--header)
			# TODO: Header format validation
			HEADERS[${optarg%%:*}]="${optarg#*: }"
			shift
			;;
		-h|--help)
			help
			exit
			;;
		-L|--location)
			LOCATION=true
			;;
		-o|--output)
			OUTPUT="$optarg"
			shift
			;;
		-v|--verbose)
			VERBOSE=true
			;;
		-X|--request)
			METHOD="$optarg"
			shift
			;;
		-x|--proxy)
			PROXY="$optarg"
			shift
			;;
		*)
			exit 1
			;;
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

# Default method
if ! [[ -v METHOD ]]
then
	if [[ -v data ]]
	then
		METHOD=POST
	else
		METHOD=GET
	fi
fi

# Set headers when content is set
if [[ -v data ]]
then
	if ! [[ -v HEADERS[Content-Length] ]]
	then
		HEADERS[Content-Length]="${#data}"
	fi
	if ! [[ -v HEADERS[Content-Type] ]]
	then
		HEADERS[Content-Type]="application/x-www-form-urlencoded"
	fi
fi

# Copy original stdout
exec {stdout}>&1

http_request "$1"
while $LOCATION && [[ -n "$REDIRECT_URL" ]]
do
	debug_echo "* Issue another request to this URL: '$REDIRECT_URL'"
	http_request "$REDIRECT_URL"
done
