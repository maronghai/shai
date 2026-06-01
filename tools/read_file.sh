#!/bin/sh
path=$(echo "$1" | jq -r .path 2>/dev/null)
if [ -z "$path" ]; then
  echo '{"success":false,"error":"missing path"}'
  exit 1
fi
if [ -f "$path" ]; then
  content=$(cat "$path")
  rlen=${#content}
  if [ $rlen -gt 10000 ]; then
    content="${content:0:10000}"$'\n... [truncated, '"$rlen"' total chars]'
  fi
  echo "$content"
else
  echo '{"success":false,"error":"File not found"}'
  exit 1
fi
