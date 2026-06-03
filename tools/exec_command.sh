#!/bin/sh
cmd=$(echo "$1" | jq -r .command 2>/dev/null)
if [ -z "$cmd" ]; then
  echo '{"success":false,"error":"missing command"}'
  exit 1
fi
output=$(timeout 10 sh -c "$cmd" 2>&1)
rc=$?
if [ $rc -eq 124 ]; then
  output="$output
[timeout after 10s, killed]"
fi
printf "%s\n" "$output"
