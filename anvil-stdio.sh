#!/usr/bin/env bash
# anvil-stdio.sh - Connect to Anvil MCP server via stdio transport
#
# Copyright (C) 2025 Laurynas Biveinis
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

set -eu -o pipefail

# Default values
INIT_FUNCTION=""
STOP_FUNCTION=""
SOCKET=""
SERVER_ID=""
EMACS_MCP_DEBUG_LOG=${EMACS_MCP_DEBUG_LOG:-""}

# GNU base64 tolerates stray non-alphabet bytes with --ignore-garbage;
# BSD/macOS base64 has no such flag.  Probe once at startup and pass
# the flag only where supported.
if printf 'Zg==' | base64 -d --ignore-garbage >/dev/null 2>&1; then
	_anvil_b64_flags="--ignore-garbage"
else
	_anvil_b64_flags=""
fi

# Debug logging setup
if [ -n "$EMACS_MCP_DEBUG_LOG" ]; then
	# Verify log file is writable
	if ! touch "$EMACS_MCP_DEBUG_LOG" 2>/dev/null; then
		echo "Error: Cannot write to debug log file: $EMACS_MCP_DEBUG_LOG" >&2
		exit 1
	fi

	# Helper function for debug logging
	mcp_debug_log() {
		local direction="$1"
		local message="$2"
		local timestamp
		timestamp=$(date "+%Y-%m-%d %H:%M:%S")
		echo "[$timestamp] [$$] MCP-${direction}: ${message}" >>"$EMACS_MCP_DEBUG_LOG"
	}

	mcp_debug_log "INFO" "Debug logging enabled"

	# Log version/path so future failure reports can tell which copy of
	# anvil-stdio.sh was actually executed (opencode/zed MCP configs
	# sometimes point to a checkout other than the user's working copy).
	_anvil_script_path="$0"
	_anvil_script_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo '?')"
	_anvil_git_sha="$(git -C "$_anvil_script_dir" rev-parse --short HEAD 2>/dev/null || echo 'no-git')"
	_anvil_mtime="$(stat -c %Y "$_anvil_script_path" 2>/dev/null || stat -f %m "$_anvil_script_path" 2>/dev/null || echo 'unknown')"
	mcp_debug_log "INFO" "anvil-stdio.sh path=$_anvil_script_path git=$_anvil_git_sha mtime=$_anvil_mtime"
	mcp_debug_log "INFO" "tooling bash=$(command -v bash || echo '?') sed=$(command -v sed || echo '?') tr=$(command -v tr || echo '?') base64=$(command -v base64 || echo '?') emacsclient=$(command -v emacsclient || echo '?')"
else
	# No-op function when debug logging is disabled
	mcp_debug_log() {
		:
	}
fi

# --- Retry wrapper for emacsclient ------------------------------------
# Absorbs the ~few-second window where `emacs --daemon' is being
# restarted: emacsclient then fails with "can't find socket" /
# "Connection refused" until the new daemon's server file is ready.
# Retrying silently keeps the MCP pipe alive so upstream Claude Code
# (or whoever is driving this bridge) doesn't see a hard failure for
# a routine daemon bounce.
#
# Configure with env vars (defaults chosen to cover a typical restart):
#   ANVIL_EMACSCLIENT_RETRY_MAX        attempts (default 60)
#   ANVIL_EMACSCLIENT_RETRY_DELAY_MS   delay per attempt in ms (default 100)
# 60 * 100ms = 6 seconds of tolerance.
ANVIL_EMACSCLIENT_RETRY_MAX=${ANVIL_EMACSCLIENT_RETRY_MAX:-60}
ANVIL_EMACSCLIENT_RETRY_DELAY_MS=${ANVIL_EMACSCLIENT_RETRY_DELAY_MS:-100}

# emacsclient's complaints when no server answers yet.  On MS-Windows the
# server is reached over TCP: a missing server file reads "error accessing
# server file", and a refused connection "connect: " followed by the
# system's message, which is localized; "No socket or alternate editor"
# ends either failure.
_anvil_retry_pattern="can't find socket|Connection refused|server.*not.*running|No such file or directory"
_anvil_retry_pattern+="|: connect: |error accessing server file|No socket or alternate editor"

# Keep the fallback self-contained: install.sh and install.ps1 deploy only
# this bridge script.  read's here-document redirection is local to this
# builtin, so emacsclient retains the bridge's original stdin.
read -r -d '' _anvil_perl_timeout_program <<'PERL' || :
use strict;
use warnings;
use POSIX qw(:sys_wait_h);
use POSIX;
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC usleep);
sub fail { print STDERR "Anvil Perl timeout: $_[0]\n"; exit 69; }
@ARGV >= 2 or fail('missing timeout or command');
my $seconds = shift @ARGV;
$seconds =~ /\A(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)\z/ && $seconds > 0
    or fail('timeout must be a finite positive number');
my $delta = 0 + $seconds;
POSIX::isfinite($delta) && $delta > 0 or fail('timeout must be a finite positive number');
my $now = eval { clock_gettime(CLOCK_MONOTONIC) };
defined($now) && $@ eq '' or fail('monotonic clock unavailable');
my $deadline = $now + $delta;
my $child_exited = 0;
my $action = eval { POSIX::SigAction->new(sub { $child_exited = 1 },
    POSIX::SigSet->new(), POSIX::SA_NOCLDSTOP()) };
defined($action) or fail('SIGCHLD handling unavailable');
eval { POSIX::sigaction(POSIX::SIGCHLD(), $action) == 0 or die 'sigaction failed'; 1 }
    or fail('SIGCHLD handling unavailable');
my $interrupted = 0;
my %signal_number = (HUP => 1, INT => 2, TERM => 15);
for my $name (keys %signal_number) {
    my $number = $signal_number{$name};
    $SIG{$name} = sub { $interrupted ||= $number };
}
if ($interrupted) { exit 128 + $interrupted; }
my $pid = fork();
defined($pid) or fail("fork failed: $!");
if ($pid == 0) {
    $SIG{$_} = 'DEFAULT' for keys %signal_number;
    $SIG{CHLD} = 'DEFAULT';
    setpgid(0, 0) == 0 or POSIX::_exit(126);
    my @command = @ARGV;
    exec { $command[0] } @command or POSIX::_exit(127);
}
sub signal_group { my ($sig) = @_; kill $sig, -$pid; kill $sig, $pid; }
sub reap_child {
    while (1) {
        my $result = waitpid($pid, 0);
        return $? if $result == $pid;
        next if $result == -1 && $!{EINTR};
        print STDERR "Anvil Perl timeout: waitpid failed: $!\n";
        return 127 << 8;
    }
}
sub grace_then_kill {
    signal_group('TERM');
    my $end = clock_gettime(CLOCK_MONOTONIC) + 1;
    usleep(20_000) while clock_gettime(CLOCK_MONOTONIC) < $end;
    signal_group('KILL');
    return reap_child();
}
usleep(20_000) while !$child_exited && !$interrupted
    && clock_gettime(CLOCK_MONOTONIC) < $deadline;
if ($interrupted) { my $sig = $interrupted; grace_then_kill(); exit 128 + $sig; }
if ($child_exited) {
    # Do not reap the leader until its group is killed; this prevents PGID
    # reuse and closes stdout inherited by orphaned descendants.
    signal_group('KILL');
    my $status = reap_child();
    exit WEXITSTATUS($status) if WIFEXITED($status);
    exit 128 + WTERMSIG($status) if WIFSIGNALED($status);
    exit 1;
}
grace_then_kill();
exit 124;
PERL

# anvil_emacsclient_retry STDERR_FILE -- EMACSCLIENT_ARGS...
#
# Run `emacsclient EMACSCLIENT_ARGS...', retrying on transient socket-
# missing / connection-refused errors.  STDERR_FILE receives stderr of
# the final attempt.  Non-socket failures (e.g. elisp errors) surface
# immediately so genuine faults aren't masked.
# Prints emacsclient's stdout on success; exits with emacsclient's rc.
anvil_emacsclient_retry() {
	local stderr_file="$1"
	shift
	if [ "${1-}" = "--" ]; then shift; fi

	local attempt=0 out="" rc=0
	while :; do
		set +e
		# VAL-PATCH-TIMEOUT-V2: hard wall-clock cap on emacsclient.
		# Default 330s (daemon's `with-timeout' is 300s — we sit
		# slightly above so the daemon can return a richer error
		# first when possible).  Set ANVIL_EMACSCLIENT_TIMEOUT=0
		# to disable.  Prefer GNU timeout(1); otherwise use the
		# process-group supervisor embedded in this script.
		_anvil_tmo="${ANVIL_EMACSCLIENT_TIMEOUT:-330}"
		if [ "$_anvil_tmo" = "0" ]; then
			out=$(emacsclient "$@" 2>"$stderr_file")
			rc=$?
		elif command -v timeout >/dev/null 2>&1; then
			# GNU timeout otherwise waits forever for a TERM-resistant
			# emacsclient to exit.  Escalate its command group to KILL
			# after one second while timeout is monitoring it.
			out=$(timeout -k 1 "$_anvil_tmo" emacsclient "$@" 2>"$stderr_file")
			rc=$?
		elif command -v perl >/dev/null 2>&1; then
			out=$(perl -e "$_anvil_perl_timeout_program" "$_anvil_tmo" emacsclient "$@" 2>"$stderr_file")
			rc=$?
		else
			printf '%s\n' "Anvil: no usable timeout backend (GNU timeout or Perl supervisor)" >"$stderr_file"
			out=""
			rc=69
		fi
		set -e
		if [ "$rc" -eq 0 ]; then
			printf '%s' "$out"
			return 0
		fi
		if [ -s "$stderr_file" ] \
			&& grep -qE "$_anvil_retry_pattern" "$stderr_file"; then
			attempt=$((attempt + 1))
			if [ "$attempt" -ge "$ANVIL_EMACSCLIENT_RETRY_MAX" ]; then
				mcp_debug_log "RETRY-EXHAUSTED" "attempts=$attempt max=$ANVIL_EMACSCLIENT_RETRY_MAX rc=$rc"
				printf '%s' "$out"
				return "$rc"
			fi
			if [ "$attempt" -eq 1 ] || [ $((attempt % 10)) -eq 0 ]; then
				mcp_debug_log "RETRY" "attempt=$attempt rc=$rc stderr=$(tr '\n' ' ' <"$stderr_file" | cut -c1-120)"
			fi
			if [ "$ANVIL_EMACSCLIENT_RETRY_DELAY_MS" -gt 0 ]; then
				local delay_sec
				delay_sec=$(awk -v ms="$ANVIL_EMACSCLIENT_RETRY_DELAY_MS" 'BEGIN{printf "%.3f", ms/1000}')
				sleep "$delay_sec"
			fi
			continue
		fi
		# Non-retriable failure — surface immediately.
		printf '%s' "$out"
		return "$rc"
	done
}

# Parse command line arguments
while [ $# -gt 0 ]; do
	case "$1" in
	--init-function=*)
		INIT_FUNCTION="${1#--init-function=}"
		shift
		;;
	--stop-function=*)
		STOP_FUNCTION="${1#--stop-function=}"
		shift
		;;
	--socket=*)
		SOCKET="${1#--socket=}"
		shift
		;;
	--server-id=*)
		SERVER_ID="${1#--server-id=}"
		shift
		;;
	*)
		echo "Unknown option: $1" >&2
		echo "Usage: $0 [--init-function=name] [--stop-function=name] [--socket=path] [--server-id=id]" >&2
		exit 1
		;;
	esac
done

# Set socket arguments if provided
if [ -n "$SOCKET" ]; then
	readonly SOCKET_OPTIONS=("-s" "$SOCKET")
	mcp_debug_log "INFO" "Using socket: $SOCKET"
else
	readonly SOCKET_OPTIONS=()
fi

# Log init function info if provided
if [ -n "$INIT_FUNCTION" ]; then
	mcp_debug_log "INFO" "Using init function: $INIT_FUNCTION"

	# Derive server-id from init function if not explicitly provided
	# This is a hack for backwards compatibility and will be removed later
	if [ -z "$SERVER_ID" ]; then
		# Extract server-id by removing -mcp-enable suffix
		SERVER_ID="${INIT_FUNCTION%-mcp-enable}"
		mcp_debug_log "INFO" "Derived server-id from init function: $SERVER_ID"
	fi
else
	mcp_debug_log "INFO" "No init function specified"
fi

# Log server-id
if [ -n "$SERVER_ID" ]; then
	mcp_debug_log "INFO" "Using server-id: $SERVER_ID"
else
	# Default to "default" if not specified
	SERVER_ID="default"
	mcp_debug_log "INFO" "Using default server-id: $SERVER_ID"
fi

# Initialize MCP if init function is provided
if [ -n "$INIT_FUNCTION" ]; then
	mcp_debug_log "INIT-CALL" "emacsclient ${SOCKET_OPTIONS[@]+"${SOCKET_OPTIONS[@]}"} -e ($INIT_FUNCTION) (with retry)"

	# Execute the command and capture output and return code
	init_stderr_file="/tmp/mcp-init-stderr.$$-$(date +%s%N)"
	mcp_debug_log "INIT-STDERR-FILE" "$init_stderr_file"
	set +e
	INIT_OUTPUT=$(anvil_emacsclient_retry "$init_stderr_file" -- \
		${SOCKET_OPTIONS[@]+"${SOCKET_OPTIONS[@]}"} \
		-e "($INIT_FUNCTION)")
	INIT_RC=$?
	set -e

	# Log results
	mcp_debug_log "INIT-RC" "$INIT_RC"
	mcp_debug_log "INIT-OUTPUT" "$INIT_OUTPUT"
	if [ -s "$init_stderr_file" ]; then
		mcp_debug_log "INIT-STDERR" "$(cat "$init_stderr_file")"
	fi
	rm -f "$init_stderr_file"
else
	mcp_debug_log "INFO" "Skipping init function call (none provided)"
fi

# --- T71: MCP Content-Length framing read helpers --------------------
# The standard MCP stdio transport frames messages as:
#
#     Content-Length: <N>\r\n
#     \r\n
#     <N bytes JSON body>
#
# Older callers may still emit line-delimited JSON.  We sniff the first
# byte of each request: if it is `{', treat as legacy line mode; if it
# is `C' (start of "Content-Length:"), treat as framed.  Mode is
# decided per-request to keep the legacy fallback transparent for
# dev/test invocations.
#
# Output: when input was framed, emit a framed response; otherwise emit
# legacy single-line JSON.

# anvil_mcp_read_framed_message
#
# Reads one MCP framed message from STDIN.  Headers are read line by
# line until an empty line; then exactly N bytes of body are read.
# Prints the JSON body on STDOUT (no trailing newline).  Returns 1 on
# EOF or malformed framing, 2 if no Content-Length header found.
anvil_mcp_read_framed_message() {
	local first_line="$1"
	local header_line content_length=""

	# Process the already-consumed first line.
	# Strip trailing CR (DOS line endings).
	first_line="${first_line%$'\r'}"
	if [[ "$first_line" =~ ^[Cc]ontent-[Ll]ength:[[:space:]]*([0-9]+)[[:space:]]*$ ]]; then
		content_length="${BASH_REMATCH[1]}"
	fi

	# Read remaining header lines until blank line.
	while IFS= read -r header_line; do
		header_line="${header_line%$'\r'}"
		if [ -z "$header_line" ]; then
			break
		fi
		if [[ "$header_line" =~ ^[Cc]ontent-[Ll]ength:[[:space:]]*([0-9]+)[[:space:]]*$ ]]; then
			content_length="${BASH_REMATCH[1]}"
		fi
	done

	if [ -z "$content_length" ]; then
		return 2
	fi

	# Read exactly content_length bytes of body.
	# `head -c N` is portable across GNU/BSD coreutils for byte count.
	local body
	body=$(head -c "$content_length")
	if [ -z "$body" ]; then
		return 1
	fi
	printf '%s' "$body"
	return 0
}

# anvil_mcp_emit_framed_response BODY
#
# Emits BODY framed with Content-Length.  N is computed in bytes
# (not characters) because the MCP spec mandates byte length.
anvil_mcp_emit_framed_response() {
	local body="$1"
	local n
	# `wc -c' counts bytes (LANG=C ensures no locale weirdness).
	n=$(LC_ALL=C printf '%s' "$body" | wc -c)
	# Strip leading whitespace from wc output (BSD pads).
	n="${n##* }"
	printf 'Content-Length: %s\r\n\r\n%s' "$n" "$body"
}

# anvil_decode_reply RAW
#
# Sets _anvil_reply to the text RAW, emacsclient's printed base64
# string, encodes.
anvil_decode_reply() {
	local raw="$1" decoded rc err_file
	# Strip the quotes emacsclient prints around a string.
	if [[ "$raw" == \"* && "$raw" == *\" ]]; then
		raw="${raw:1:${#raw}-2}"
		raw="${raw//\\\"/\"}"
	fi

	# Repair Windows MSYS frame-boundary corruption.
	# emacsclient.c uses a read buffer of BUFSIZ+1 bytes; on MSYS / mingw
	# stdio.h, BUFSIZ is 512.  The Emacs server's `server-reply-print'
	# splits its output into frames of up to `server-msg-size' (1024 by
	# default), so on Windows every frame larger than ~512 bytes overruns
	# the client's read buffer.  When that happens, the tail of the frame
	# loses its `-print-nonl ' prefix and emacsclient prints it as
	#   *ERROR*: Unknown message: <tail>
	# interleaved with the legitimate base64 payload.  Strip those
	# injection markers with `sed s///g' (POSIX BRE, so `\*' is
	# unambiguously a literal asterisk on every sed implementation --
	# unlike `awk' where `\*' in ERE is treated differently by gawk /
	# mawk / busybox / git-bash-bundled awk and may cause the strip to
	# silently fail).  Then remove ALL CR/LF bytes; frame boundaries
	# leave CRLF behind, and `tr' is trivially portable.  `--ignore-
	# garbage' on the base64 decoder is NOT sufficient on its own: the
	# marker text "ERROR Unknown message" is 15 base64-alphabet bytes
	# that the decoder happily consumes as payload, throwing off the
	# multiple-of-4 requirement and yielding `invalid input' under
	# `set -e -o pipefail'.  Stripping the marker textually, before
	# decoding, is what makes Windows work at all.
	# (No-op on Linux/macOS where one frame fits in one read.)
	raw=$(printf '%s' "$raw" \
		| sed 's/\*ERROR\*: Unknown message: //g' \
		| tr -d '\r\n')

	# Diagnostic: confirm strip actually happened.  If markers survived,
	# base64 -d will almost certainly fail below, and we want the log to
	# say so out loud rather than just ending at BASE64-RESPONSE.
	mcp_debug_log "INFO" "after-strip len=${#raw} markers=$(printf '%s' "$raw" | grep -c '\*ERROR\*' || true)"

	# Decode the base64 content (lenient against stray non-base64 bytes).
	# Capture rc/stderr explicitly so that a decode failure is logged
	# instead of silently killing the script under `set -e -o pipefail'.
	err_file="$_anvil_state.decode-err.$$-$RANDOM"
	set +e
	decoded=$(printf '%s' "$raw" | base64 -d $_anvil_b64_flags 2>"$err_file")
	rc=$?
	set -e
	if [ "$rc" != 0 ]; then
		mcp_debug_log "DECODE-ERROR" "rc=$rc stderr=$(tr '\n' ' ' <"$err_file" 2>/dev/null) input_head=${raw:0:160}"
	fi
	rm -f "$err_file"
	_anvil_reply="$decoded"
}

# anvil_call_emacs EXPR
#
# Evaluates EXPR, which returns a string encoded in base64, in Emacs,
# and sets _anvil_reply to that string decoded, and _anvil_client_rc to
# emacsclient's status.
anvil_call_emacs() {
	local stderr_file="$_anvil_state.stderr.$$-$RANDOM" raw
	set +e
	raw=$(anvil_emacsclient_retry "$stderr_file" -- \
		${SOCKET_OPTIONS[@]+"${SOCKET_OPTIONS[@]}"} \
		-e "$1")
	_anvil_client_rc=$?
	set -e
	mcp_debug_log "EMACSCLIENT-RC" "$_anvil_client_rc"
	if [ -s "$stderr_file" ]; then
		mcp_debug_log "EMACSCLIENT-STDERR" "$(<"$stderr_file")"
	fi
	rm -f "$stderr_file"
	mcp_debug_log "BASE64-RESPONSE" "$raw"
	anvil_decode_reply "$raw"
}

# anvil_emit BODY FRAMED
#
# Writes BODY to the client, framed when FRAMED is 1, alone on standard
# output: deferred answers come from other processes, and a lock keeps
# their responses whole.
anvil_emit() {
	# noclobber creates the lock exclusively, as a builtin.
	until (set -C && : >"$_anvil_out_lock") 2>/dev/null; do
		sleep 0.01
	done
	if [ "$2" = "1" ]; then
		# T71: framed output for MCP-compliant clients.
		anvil_mcp_emit_framed_response "$1"
	else
		# Legacy line-delimited output (dev / test mode).
		printf '%s\n' "$1"
	fi
	rm -f "$_anvil_out_lock"
}

# anvil_request_id REQUEST
#
# Prints the JSON id of REQUEST, as written there, or nothing.
anvil_request_id() {
	printf '%s' "$1" \
		| sed -nE 's/.*"id"[[:space:]]*:[[:space:]]*([0-9]+|"[^"]*"|null).*/\1/p' \
		| head -1
}

# anvil_emit_error ID MESSAGE FRAMED
#
# Answers the request ID with a JSON-RPC internal error saying MESSAGE.
anvil_emit_error() {
	anvil_emit "$(printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32603,"message":"%s"}}' "$1" "$2")" "$3"
}

# --- Deferred answers ---------------------------------------------------
# A tool whose answer comes later answers "anvil-deferred:JOB:SECONDS"
# rather than a response (see `anvil-server-defer').  The bridge then
# polls `anvil-server-deferred-poll' in a process of its own, each call
# returning at once, and writes the response once it is there, while it
# goes on reading and answering other requests: Emacs never waits, and
# neither do the other requests.  The poller gives up SECONDS plus a
# minute after it began, answering an error; a request the client
# cancels has its poller stopped.

# The bridge's files: its output lock, and a file per poller, named by
# the request it holds, giving its process and job.
_anvil_state="${TMPDIR:-/tmp}"
_anvil_state="${_anvil_state%/}/anvil-stdio-$$"
_anvil_out_lock="$_anvil_state.lock"

anvil_cleanup() {
	local hold pid job
	for hold in "$_anvil_state".hold-*; do
		if [ -f "$hold" ]; then
			read -r pid job <"$hold" || true
			kill "$pid" 2>/dev/null || true
			rm -f "$hold"
		fi
	done
	rm -f "$_anvil_out_lock"
}
trap anvil_cleanup EXIT
# Signals end the bridge through its exit, so that its pollers stop.
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# anvil_hold_name ID
#
# Prints the name of the file holding the poller of the request ID.
anvil_hold_name() {
	printf '%s.hold-%s' "$_anvil_state" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"
}

# anvil_hold_deferred JOB SECONDS ID FRAMED
anvil_hold_deferred() {
	local job="$1" id="$3" framed="$4" reply delay=0.2 failures=0
	local deadline=$((SECONDS + $2 + 60))
	while :; do
		sleep "$delay"
		# A bridge gone, its client is too.
		kill -0 "$$" 2>/dev/null || break
		case "$delay" in
		0.2) delay=0.5 ;;
		0.5) delay=1 ;;
		esac
		anvil_call_emacs "(base64-encode-string (encode-coding-string (or (anvil-server-deferred-poll \"$job\") \"\") 'utf-8 t) t)"
		reply="$_anvil_reply"
		case "$reply" in
		-)
			failures=0
			;;
		"?")
			anvil_emit_error "$id" "The deferred answer was lost: Emacs no longer knows its request" "$framed"
			break
			;;
		"")
			failures=$((failures + 1))
			if [ "$failures" -ge 30 ]; then
				anvil_emit_error "$id" "Emacs stopped answering the polls of a deferred answer (emacsclient rc=${_anvil_client_rc:-?})" "$framed"
				break
			fi
			;;
		*)
			mcp_debug_log "DEFERRED-RESPONSE" "$reply"
			anvil_emit "$reply" "$framed"
			break
			;;
		esac
		if [ "$SECONDS" -gt "$deadline" ]; then
			anvil_call_emacs "(base64-encode-string (anvil-server-deferred-cancel \"$job\") t)" || true
			anvil_emit_error "$id" "Timed out waiting for a deferred answer" "$framed"
			break
		fi
	done
	rm -f "$(anvil_hold_name "$id")"
}

# anvil_cancel_held REQUEST
#
# Stops the poller of the request a notifications/cancelled REQUEST names.
anvil_cancel_held() {
	local id hold pid job
	id=$(printf '%s' "$1" \
		| sed -nE 's/.*"requestId"[[:space:]]*:[[:space:]]*([0-9]+|"[^"]*").*/\1/p' \
		| head -1)
	[ -n "$id" ] || return 0
	hold=$(anvil_hold_name "$id")
	if [ -f "$hold" ]; then
		read -r pid job <"$hold" || true
		mcp_debug_log "DEFERRED-CANCEL" "id=$id job=$job"
		kill "$pid" 2>/dev/null || true
		rm -f "$hold"
		anvil_call_emacs "(base64-encode-string (anvil-server-deferred-cancel \"$job\") t)" || true
	fi
}

# Process input and print response
while IFS= read -r line; do
	# T71: detect framing.  An MCP framed request begins with
	# `Content-Length:' (case-insensitive); legacy line-delimited
	# requests begin with `{'.
	# Strip CR for cross-platform safety.
	_anvil_first_line="${line%$'\r'}"
	_anvil_framed=0
	if [[ "$_anvil_first_line" =~ ^[Cc]ontent-[Ll]ength: ]]; then
		_anvil_framed=1
		mcp_debug_log "FRAMING" "Content-Length detected"
		# Re-read full framed message; reuse the already-consumed line.
		line=$(anvil_mcp_read_framed_message "$_anvil_first_line") || {
			mcp_debug_log "FRAMING-ERROR" "rc=$? first=$_anvil_first_line"
			continue
		}
	fi

	# Log the incoming request
	mcp_debug_log "REQUEST" "$line"

	case "$line" in
	*'"notifications/cancelled"'*) anvil_cancel_held "$line" ;;
	esac

	# Base64 encode the raw JSON to avoid emacsclient transport issues
	# with a specific combination of length, UTF-8 characters, and quoting
	# that occurs in Test 5 with the Lithuanian letter 'ą'
	base64_input=$(echo -n "$line" | base64)
	mcp_debug_log "BASE64-INPUT" "$base64_input"

	# Process JSON-RPC request and return the result with proper UTF-8 encoding
	# Encode the response to base64 to avoid any character encoding issues
	# Handle nil responses from notifications by converting to empty string.
	# `anvil-server-deferrable' tells tools this bridge holds deferred answers.
	elisp_expr="(base64-encode-string (encode-coding-string (or (let ((anvil-server-deferrable t)) (anvil-server-process-jsonrpc (base64-decode-string \"$base64_input\") \"$SERVER_ID\")) \"\") 'utf-8 t) t)"

	# Get response from emacsclient (with retry across daemon restarts).
	# The rc is for logging only; an empty response is a soft failure.
	anvil_call_emacs "$elisp_expr"
	formatted_response="$_anvil_reply"

	mcp_debug_log "RESPONSE" "$formatted_response"

	case "$formatted_response" in
	anvil-deferred:*)
		_anvil_deferred="${formatted_response#anvil-deferred:}"
		_anvil_job="${_anvil_deferred%%:*}"
		_anvil_seconds="${_anvil_deferred##*:}"
		[[ "$_anvil_seconds" =~ ^[0-9]+$ ]] || _anvil_seconds=600
		_anvil_id_field=$(anvil_request_id "$line")
		mcp_debug_log "DEFERRED" "id=$_anvil_id_field job=$_anvil_job seconds=$_anvil_seconds"
		anvil_hold_deferred "$_anvil_job" "$_anvil_seconds" "${_anvil_id_field:-null}" "$_anvil_framed" &
		echo "$! $_anvil_job" >"$(anvil_hold_name "${_anvil_id_field:-null}")"
		;;
	?*)
		# Only output non-empty responses
		anvil_emit "$formatted_response" "$_anvil_framed"
		;;
	*)
		# VAL-PATCH-ALWAYS-REPLY: empty daemon output for a
		# request-with-id would otherwise hang the MCP client
		# forever.  Synthesise a JSON-RPC error so the client
		# can match the id and move on.  Notifications (no id)
		# stay silent as the protocol expects.
		_anvil_id_field=$(anvil_request_id "$line")
		if [ -n "$_anvil_id_field" ] && [ "$_anvil_id_field" != "null" ]; then
			mcp_debug_log "SYNTH-ERROR" "id=$_anvil_id_field rc=${_anvil_client_rc:-?}"
			anvil_emit_error "$_anvil_id_field" "Bridge synthetic error: daemon returned empty response (emacsclient rc=${_anvil_client_rc:-?})" "$_anvil_framed"
		fi
		;;
	esac
done

# Stop MCP if stop function is provided
if [ -n "$STOP_FUNCTION" ]; then
	mcp_debug_log "INFO" "Stopping MCP with function: $STOP_FUNCTION"
	mcp_debug_log "STOP-CALL" "emacsclient ${SOCKET_OPTIONS[@]+"${SOCKET_OPTIONS[@]}"} -e ($STOP_FUNCTION) (with retry)"

	# Execute the command and capture output and return code
	stop_stderr_file="/tmp/mcp-stop-stderr.$$-$(date +%s%N)"
	set +e
	STOP_OUTPUT=$(anvil_emacsclient_retry "$stop_stderr_file" -- \
		${SOCKET_OPTIONS[@]+"${SOCKET_OPTIONS[@]}"} \
		-e "($STOP_FUNCTION)")
	STOP_RC=$?
	set -e

	# Log results
	mcp_debug_log "STOP-RC" "$STOP_RC"
	mcp_debug_log "STOP-OUTPUT" "$STOP_OUTPUT"
	if [ -s "$stop_stderr_file" ]; then
		mcp_debug_log "STOP-STDERR" "$(cat "$stop_stderr_file")"
	fi
	rm -f "$stop_stderr_file"
else
	mcp_debug_log "INFO" "Skipping stop function call (none provided)"
fi
