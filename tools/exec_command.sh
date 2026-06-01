#!/bin/sh
cmd=$(echo "$1" | jq -r .command 2>/dev/null)
if [ -z "$cmd" ]; then
  echo '{"success":false,"error":"missing command"}'
  exit 1
fi
output=$(eval "$cmd" 2>&1 || echo "Command failed")
echo "$output"
