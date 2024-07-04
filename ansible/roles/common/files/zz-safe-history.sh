# shellcheck disable=SC2148
HISTSIZE=1048576
HISTFILESIZE=1048576

LAST_HISTORY_WRITE=$SECONDS
function prompt_command {
	if [ $((SECONDS - LAST_HISTORY_WRITE)) -gt 60 ]; then
		history -a && history -c && history -r
		LAST_HISTORY_WRITE=$SECONDS
	fi
}

if [ "$PROMPT_COMMAND" == "" ]; then
	PROMPT_COMMAND="prompt_command"
else
	PROMPT_COMMAND="$PROMPT_COMMAND; prompt_command"
fi
