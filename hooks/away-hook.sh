#!/bin/sh
# Agent Away hook for Claude Code (the grok CLI reads the same hooks).
#
# Reads flag files written by the Agent Away menu-bar app and exits at once
# when no mode is on. Synchronous modes always exit 0, so a failure here can
# never block a session. The two "wake-*" modes run as async hooks with
# asyncRewake: exiting 2 wakes an idle session and hands it the stderr text.
#
# Files in $R:  pid        the running app's pid (flags are ignored without it)
#               away       keep-awake is on
#               lid        lid closed while away (content: epoch)
#               hot        heat-guard note (line 1: epoch, rest: message)
#               askfirst   "ask first, then don't" is on (content: epoch timeout-seconds)
#               s/<sid>    ask phase per session: "asked|waiting|answered <epoch>"
#               seen/<sid>.lid|.hot   which lid/heat notice the session already got
#               bounced/<sid>, rewoke/<sid>   last question bounce / last wake (epochs)
#               pending/<sid>.<pid>   a wake mode is waiting (keeps the app from switching off)

R="$HOME/Library/Application Support/AgentAway/run"
# Fast path. Always read stdin fully: closing it early can surface as a hook error.
[ -f "$R/away" ] || [ -f "$R/askfirst" ] || { cat >/dev/null; exit 0; }
# Flags left behind by an app that is no longer running mean nothing.
APP=""
{ read -r APP || [ -n "$APP" ]; } < "$R/pid" 2>/dev/null
[ -n "$APP" ] && kill -0 "$APP" 2>/dev/null || { cat >/dev/null; exit 0; }

MODE=$1
J=/usr/bin/jq
IN=$(cat)
NOW=$(date +%s)
SESSIONS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions"

eval "$(printf '%s' "$IN" | $J -r '
  @sh "SID=\(.session_id // .sessionId // "")",
  @sh "TOOL=\(.tool_name // .toolName // "")",
  @sh "ACTIVE=\(.stop_hook_active // .stopHookActive // false)",
  @sh "ERR=\(.error // "")",
  @sh "EVENT=\(.hook_event_name // "")",
  @sh "SUB=\(if ((.agent_id // .agentId // "") | tostring) != "" then 1 else 0 end)",
  @sh "GROK=\(if has("hookEventName") then 1 else 0 end)"' 2>/dev/null)" || exit 0
case $SID in "" | *[!A-Za-z0-9_-]*) exit 0 ;; esac
# Headless runs (claude -p, Agent SDK scripts) have nobody to ask: no ask-first, no wakes.
HEADLESS=0
case ${CLAUDE_CODE_ENTRYPOINT:-} in sdk-*) HEADLESS=1 ;; esac

P="" PT=0
[ -f "$R/s/$SID" ] && read -r P PT < "$R/s/$SID"
setp() { mkdir -p "$R/s" && printf '%s %s\n' "$1" "$NOW" > "$R/s/$SID"; } 2>/dev/null
stamp() { mkdir -p "$R/$1" && printf '%s' "$NOW" > "$R/$1/$SID"; } 2>/dev/null

ASKFIRST=0 ASK_TIMEOUT=600
if [ -f "$R/askfirst" ] && [ $HEADLESS = 0 ]; then
    ASKFIRST=1
    read -r _ ASK_TIMEOUT < "$R/askfirst"
    case $ASK_TIMEOUT in "" | *[!0-9]*) ASK_TIMEOUT=600 ;; esac
    # An ask window nobody used for 10 min counts as answered.
    [ "$P" = asked ] && [ $((NOW - PT)) -gt 600 ] && P=answered
fi

HOW='Ask them as a numbered list in your reply text, each with your recommended default (not with the AskUserQuestion tool: its dialog cannot time out while the user is away), then end your turn.'
STANDING=''
[ $GROK = 0 ] && STANDING=" This mode is the user's standing instruction: if they have not replied within $((ASK_TIMEOUT / 60)) minutes, you will get an automated reminder, and you should then go with your recommended defaults (they pre-approved that), note them as assumptions, and continue."
ASK_BUSY="[Agent Away] The user switched on \"ask first, then don't\": they are about to leave the computer for a while. Pause your work now. Using what you already know (do not run more tools first), think ahead through the rest of this task and collect every question or decision you expect to need from the user. $HOW If you need nothing from them, say so in one line and carry on. After they reply you will not be able to ask anything else.$STANDING"
ASK_NEW="[Agent Away] The user switched on \"ask first, then don't\": they are about to leave the computer. Before starting on this message, think through the whole task and collect every question or decision you will need from them. $HOW If you need nothing, say so in one line and start. After they reply you will not be able to ask anything else.$STANDING"
ASK_TEXT="[Agent Away] Not with this tool while ask-first mode is on. $HOW"
AWAY_NOW='[Agent Away] The user has answered and is now away from the computer. Do not ask them anything or wait for input from here on (AskUserQuestion is disabled). When a question comes up, pick what you judge best, note the assumption, and keep going. List your assumptions in your final summary.'
DENY_ASK='[Agent Away] The user is away and cannot answer. Do not ask. Choose the option you judge best (your recommended one), note it as an assumption for your final summary, and continue.'
STOP_BLOCK='[Agent Away] The user is away and cannot answer questions right now. Do not wait for input: choose the option you judge best, state the assumption in one line, and continue the task. If the task is completely done, end with a short summary instead of a question.'
LID='[Agent Away] The laptop lid is closed and the Mac is probably in a bag with little airflow. Keep working, but avoid anything that loads the CPU or GPU hard for long: video, audio or 3D rendering and encoding, image or media batch processing, ML training or local model inference, simulators, VMs and container image builds, benchmarks, and long CPU-bound loops or huge parallel builds and test runs (prefer targeted builds and tests). If the task needs one of those, do everything else and leave that step for when the user is back (say so in your summary). Heavy processes are throttled or paused automatically, and some heavy commands are refused.'
HEAVY='[Agent Away] Refused while the lid is closed (heat): this command is heavy CPU/GPU work (rendering/encoding, ML, simulators/VMs, image builds, benchmarks). Skip it for now, continue with the rest of the task, and list it as a step to run when the user is back.'

# Commands that are heavy by nature (refused only while away with the lid closed).
# Matched in command position: line start or after ; & | ( $( `, after VAR=x
# prefixes, wrappers (sudo, time, nice, nohup, env, exec, caffeinate, xargs) and a path.
# Quoted strings and heredoc bodies are removed first (they are text, not commands).
S='[[:space:]]'
HEAVY_CMD="(ffmpeg|ffpb|handbrakecli|blender|manim|melt|avconv|x264|x265|svtav1encapp|gst-launch-1\.0|povray|vspipe\
|(npx|bunx|pnpm$S+(exec|dlx))?$S*remotion$S+render\
|torchrun|deepspeed|accelerate$S+launch|ollama$S+(run|serve|create)|llama-(cli|server|bench)|mlx_lm\.[a-z_]+|mlx_whisper\
|whisper(-cli)?|vllm|lms$S+load|python[0-9.]*($S+-[^[:space:]]+)*$S+(-m$S+(torch\.distributed[a-z._]*|mlx_lm[a-z._]*|mlx_whisper|whisper|vllm[a-z._]*)\
|[^[:space:];&|]*(train|finetune|fine_tune)[a-z0-9_-]*\.py)\
|stress(-ng)?|sysbench|geekbench[0-9]*|xmrig|cpuminer|hashcat\
|qemu-system-[a-z0-9_]+|colima$S+start|limactl$S+start|docker$S+(buildx$S+)?build|docker$S+compose$S+up[^;&|]*--build\
|podman$S+build|xcrun$S+simctl$S+boot)"
HEAVY_RE="(^|[;&|(\`]|\\\$\()$S*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*$S+)*((sudo|time|nice|nohup|env|exec|caffeinate|xargs)($S+-[^[:space:]]+)*$S+)*([^[:space:];&|]*/)?$HEAVY_CMD([^A-Za-z0-9_.-]|\$)"
COMMAND_TEXT='(.tool_input.command // .toolInput.command // "") | strings
  | (split("\n") | reduce .[] as $l ({out: [], end: null};
      if .end then (if ($l | gsub("^\\s+|\\s+$"; "")) == .end then .end = null else . end)
      else .out += [$l]
        | (($l | capture("<<-?\\s*[\"'"'"']?(?<w>[A-Za-z_][A-Za-z0-9_]*)")) // null) as $m
        | if $m then .end = $m.w else . end end) | .out | join("\n"))
  | gsub("'"'"'[^'"'"']*'"'"'"; "") | gsub("\"(\\\\.|[^\"\\\\])*\""; "")'

# The reply's text without code and links, for spotting questions.
PROSE='(.last_assistant_message // .lastAssistantMessage // "") | strings
  | gsub("```[\\s\\S]*?```"; "") | gsub("`[^`]*`"; "") | gsub("https?://\\S+"; "")'
QUESTION_WORDS='let me know|would you like|do you want|should i |which (one|option|would you)|please (confirm|choose|advise|let me)|your (call|choice|preference)|waiting (for|on) (you|your)'
asks_anything() { # some sentence in the reply asks the user something
    T=$(printf '%s' "$IN" | $J -r "$PROSE")
    printf '%s' "$T" | /usr/bin/grep -Eq '\?[)*_"'"'"']*([[:space:]]|$)' || printf '%s' "$T" | /usr/bin/grep -Eqi "$QUESTION_WORDS"
}
ends_on_question() { # the last few lines of the reply ask the user something
    T=$(printf '%s' "$IN" | $J -r "$PROSE"' | split("\n") | map(select(test("\\S"))) | .[-3:] | join("\n")')
    printf '%s' "$T" | /usr/bin/grep -Eq '\?[)*_"'"'"']*([[:space:]]|$)' || printf '%s' "$T" | /usr/bin/grep -Eqi "$QUESTION_WORDS"
}

# Lid and heat-guard notices, each delivered once per event per session.
notices() {
    [ -f "$R/away" ] || return 0
    if [ -f "$R/lid" ]; then
        id=$(cat "$R/lid" 2>/dev/null)
        if [ "$id" != "$(cat "$R/seen/$SID.lid" 2>/dev/null)" ]; then
            mkdir -p "$R/seen" 2>/dev/null && printf '%s' "$id" > "$R/seen/$SID.lid"
            printf '%s\n\n' "$LID"
        fi
    fi
    if [ -f "$R/hot" ]; then
        id=$(head -n 1 "$R/hot" 2>/dev/null)
        if [ "$id" != "$(cat "$R/seen/$SID.hot" 2>/dev/null)" ]; then
            mkdir -p "$R/seen" 2>/dev/null && printf '%s' "$id" > "$R/seen/$SID.hot"
            tail -n +2 "$R/hot"
        fi
    fi
}

# While a wake mode waits, a marker tells the app not to switch itself off.
pending() {
    mkdir -p "$R/pending" 2>/dev/null
    PF="$R/pending/$SID.$$"
    : > "$PF"
    trap 'rm -f "$PF"' EXIT
    trap 'exit 0' TERM INT HUP
}

context() { # $1 = event name, $2 = text
    [ -n "$2" ] && $J -nc --arg e "$1" --arg c "$2" '{hookSpecificOutput:{hookEventName:$e, additionalContext:$c}}'
}

deny() {
    $J -nc --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"deny", permissionDecisionReason:$r}}'
}

# Is this session's turn running right now? (Claude Code's own status file)
session_busy() {
    for f in "$SESSIONS"/*.json; do
        $J -r --arg s "$SID" 'select(.sessionId == $s) | .status' "$f" 2>/dev/null
    done | /usr/bin/grep -qx busy
}

case $MODE in
prompt) # UserPromptSubmit
    [ $SUB = 0 ] || exit 0
    C="" N=""
    if [ $ASKFIRST = 1 ]; then
        case $P in
        # grok drops prompt context, so it gets the request at its first tool call instead.
        "") [ $GROK = 0 ] && { setp asked; C=$ASK_NEW; } ;;
        asked | waiting) setp answered; C=$AWAY_NOW ;;
        esac
    fi
    [ $GROK = 0 ] && N=$(notices)
    context UserPromptSubmit "$(printf '%s\n\n%s' "$C" "$N" | sed '/./,$!d')"
    ;;

post) # PostToolUse and PostToolUseFailure. Subagents don't use up the main agent's notices.
    [ $SUB = 0 ] || exit 0
    C=""
    if [ $ASKFIRST = 1 ] && [ -z "$P" ]; then
        setp asked
        C=$ASK_BUSY
    fi
    N=$(notices)
    case $EVENT in PostToolUseFailure) ;; *) EVENT=PostToolUse ;; esac
    context "$EVENT" "$(printf '%s\n\n%s' "$C" "$N" | sed '/./,$!d')"
    ;;

pre) # PreToolUse (matcher: AskUserQuestion and shell tools)
    case $TOOL in
    AskUserQuestion | ask_user_question)
        [ $ASKFIRST = 1 ] || exit 0
        if [ "$P" = answered ] || [ $SUB = 1 ]; then
            deny "$DENY_ASK"
        else
            # Questions go in plain text so the unanswered-questions timeout can apply.
            [ -z "$P" ] && setp asked
            deny "$ASK_TEXT"
        fi ;;
    *)
        if [ -f "$R/away" ] && [ -f "$R/lid" ]; then
            CMD=$(printf '%s' "$IN" | $J -r "$COMMAND_TEXT" 2>/dev/null)
            if printf '%s' "$CMD" | /usr/bin/grep -Eqi "$HEAVY_RE"; then
                deny "$HEAVY"
            fi
        fi ;;
    esac
    ;;

stop) # Stop
    [ $ASKFIRST = 1 ] || exit 0
    case $P in
    asked)
        # Questions asked: wait for answers. Said it needs nothing: it's on its own.
        if asks_anything; then setp waiting; else setp answered; fi ;;
    answered)
        # Loop protection: one bounce per chain of continuations. A turn woken by
        # this hook also starts with stop_hook_active set, so track bounces ourselves.
        if [ "$ACTIVE" = true ]; then
            B=$(cat "$R/bounced/$SID" 2>/dev/null) W=$(cat "$R/rewoke/$SID" 2>/dev/null)
            [ "${B:-0}" -gt 0 ] && [ "${B:-0}" -ge "${W:-0}" ] && exit 0
        fi
        if ends_on_question; then
            stamp bounced
            $J -nc --arg r "$STOP_BLOCK" '{decision:"block", reason:$r}'
        fi ;;
    esac
    ;;

wake-ask) # Stop, async + asyncRewake. Questions asked but nobody answered in time.
    [ $GROK = 0 ] && [ $HEADLESS = 0 ] && [ $ASKFIRST = 1 ] || exit 0
    sleep 5 # let the synchronous stop hook record the phase first
    read -r P PT0 < "$R/s/$SID" 2>/dev/null || exit 0
    [ "$P" = waiting ] || exit 0
    pending
    sleep "$ASK_TIMEOUT"
    [ -f "$R/askfirst" ] || exit 0
    # Still the same unanswered round (not one from an earlier on/off cycle).
    read -r P PT < "$R/s/$SID" 2>/dev/null || exit 0
    [ "$P" = waiting ] && [ "$PT" = "$PT0" ] || exit 0
    session_busy && exit 0
    NOW=$(date +%s)
    setp answered
    stamp rewoke
    echo "[Agent Away] Reminder: no reply to your questions for $((ASK_TIMEOUT / 60)) min; the user has left. As they set up when turning on ask-first mode, go with your recommended default for each open question, list them as assumptions, and continue the task without asking anything else. If the task is already complete, just say so briefly." >&2
    exit 2
    ;;

wake-failure) # StopFailure, async + asyncRewake. Turn died on an API/network error.
    [ $GROK = 0 ] && [ $HEADLESS = 0 ] || exit 0
    [ -f "$R/away" ] || exit 0
    [ -n "${CLAUDE_CODE_USE_BEDROCK:-}${CLAUDE_CODE_USE_VERTEX:-}" ] && exit 0
    case $ERR in overloaded | server_error | max_output_tokens | unknown) ;; *) exit 0 ;; esac
    mkdir -p "$R/wake" 2>/dev/null
    # At most 3 automatic continues per session per hour.
    n=$(find "$R/wake" -name "$SID.*" -mmin -60 2>/dev/null | wc -l)
    [ "$n" -lt 3 ] || exit 0
    : > "$R/wake/$SID.$NOW"
    pending
    URL=${ANTHROPIC_BASE_URL:-https://api.anthropic.com}
    ok=0 i=0
    while [ $i -lt 480 ]; do # up to ~2 h waiting for the network
        sleep 15
        [ -f "$R/away" ] || exit 0
        if /usr/bin/curl -s -o /dev/null -m 8 "$URL"; then
            ok=$((ok + 1))
            [ $ok -ge 2 ] && break
        else
            ok=0
        fi
        i=$((i + 1))
    done
    [ $ok -ge 2 ] || exit 0
    session_busy && exit 0 # someone already resumed it
    NOW=$(date +%s)
    stamp rewoke
    echo "[Agent Away] Your last turn stopped on an API/network error ($ERR) while the user is away. The connection works again: please continue the task from where you left off." >&2
    exit 2
    ;;
esac
exit 0
