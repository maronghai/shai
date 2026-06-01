#!/bin/sh
pattern=$(echo "$1" | jq -r .pattern 2>/dev/null)
spath=$(echo "$1" | jq -r '.path // "."' 2>/dev/null)
if [ -z "$pattern" ]; then
  echo '{"success":false,"error":"missing pattern"}'
  exit 1
fi
result=$(grep -rn -- "$pattern" "$spath" 2>/dev/null | head -100 || echo "")
if [ -n "$result" ]; then
  echo "$result"
else
  echo "No matches"
fi
