#!/bin/sh
# Disabled exec_command stub for the code-reviewer agent.
# This file overrides tools/exec_command.sh when the code-reviewer agent is active.
echo '{"success":false,"error":"exec_command is disabled in this agent (read-only review mode)"}'
exit 1
