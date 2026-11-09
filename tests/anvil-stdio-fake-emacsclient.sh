#!/usr/bin/env bash
# anvil-stdio-fake-emacsclient.sh - emacsclient standing in for Emacs
#
# The stdio bridge tests copy this script as `emacsclient', its first
# line naming their bash, and run the bridge with it first on PATH.
# It answers the JSON-RPC request in the expression the bridge passes
# with -e: a request with an id gets an empty result (a list for
# tools/list and resources/list), method "fail" gets an Emacs error,
# and a notification gets nothing.  The first call waits
# FAKE_FIRST_DELAY seconds, so that the input sent with it is waiting
# for the bridge once it answers.  FAKE_BASE64 and FAKE_SLEEP name the
# programs it uses, so that it runs on a PATH holding no other.  Each
# call appends "emacsclient" to `calls' and the request to `requests',
# beside the script.

dir=${0%/*}
printf 'emacsclient\n' >>"$dir/calls"
expr=
while [ $# -gt 0 ]; do
	if [ "$1" = -e ]; then
		expr=$2
		break
	fi
	shift
done
b64=${expr#*base64-decode-string \"}
b64=${b64%%\"*}
req=$(printf '%s' "$b64" | "$FAKE_BASE64" -d)
printf '%s\n' "$req" >>"$dir/requests"
if [ ! -e "$dir/answered" ]; then
	: >"$dir/answered"
	if [ "${FAKE_FIRST_DELAY:-0}" != 0 ]; then
		"$FAKE_SLEEP" "$FAKE_FIRST_DELAY"
	fi
fi
id=
re='"id":(-?[0-9]+|"[^"]*")'
if [[ $req =~ $re ]]; then
	id=${BASH_REMATCH[1]}
fi
if [ -z "$id" ]; then
	printf '""\n'
	exit 0
fi
case $req in
*'"method":"tools/list"'*) result='{"tools":[]}' ;;
*'"method":"resources/list"'*) result='{"resources":[]}' ;;
*'"method":"fail"'*)
	printf '*ERROR*: The request failed\n' >&2
	exit 1
	;;
*) result='{}' ;;
esac
enc=$(printf '{"jsonrpc":"2.0","id":%s,"result":%s}' "$id" "$result" | "$FAKE_BASE64")
printf '"%s"\n' "${enc//$'\n'/}"
