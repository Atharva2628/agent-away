# Removes Agent Away's hook entries from a Claude Code settings object, then
# (unless $remove is "1") adds the current set. Other hooks are left as-is.
#   jq --arg cmd '/bin/sh "/path/away-hook.sh"' [--arg remove 1] -f hooks.jq settings.json

def ours: (.command // "") | contains("AgentAway/away-hook.sh");
def strip: map(.hooks |= map(select(ours | not)) | select((.hooks | length) > 0));
def sync($mode): {type: "command", command: "\($cmd) \($mode) || true", timeout: 5};
def wake($mode; $t): {type: "command", command: "\($cmd) \($mode)", async: true, asyncRewake: true, timeout: $t};

(.hooks // {}) as $h
| .hooks = ($h | with_entries(.value |= strip) | with_entries(select(.value | length > 0)))
| if ($ARGS.named.remove // "") == "1" then
    (if .hooks == {} then del(.hooks) else . end)
  else
    .hooks.UserPromptSubmit += [{hooks: [sync("prompt")]}]
    | .hooks.PreToolUse += [{matcher: "AskUserQuestion|Bash", hooks: [sync("pre")]}]
    | .hooks.PostToolUse += [{hooks: [sync("post")]}]
    | .hooks.PostToolUseFailure += [{hooks: [sync("post")]}]
    | .hooks.Stop += [{hooks: [sync("stop"), wake("wake-ask"; 3600)]}]
    | .hooks.StopFailure += [{matcher: "overloaded|server_error|max_output_tokens|unknown",
                              hooks: [wake("wake-failure"; 7500)]}]
  end
