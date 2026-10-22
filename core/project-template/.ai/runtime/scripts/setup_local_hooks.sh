#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)
WORKSPACE_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd -P)
DESIRED_HOOKS_PATH=.ai/runtime/githooks

if ! GIT_TOP_LEVEL=$(git -C "$WORKSPACE_ROOT" rev-parse --show-toplevel 2>/dev/null); then
  echo "ERROR: $WORKSPACE_ROOT is not a Git work tree." >&2
  exit 1
fi
GIT_TOP_LEVEL=$(CDPATH= cd -- "$GIT_TOP_LEVEL" && pwd -P)
if [ "$GIT_TOP_LEVEL" != "$WORKSPACE_ROOT" ]; then
  echo "ERROR: run the hook setup from the installed Git top-level." >&2
  echo "Workspace: $WORKSPACE_ROOT" >&2
  echo "Git top-level: $GIT_TOP_LEVEL" >&2
  exit 1
fi

for hook in pre-commit pre-push; do
  hook_path="$WORKSPACE_ROOT/$DESIRED_HOOKS_PATH/$hook"
  if [ ! -f "$hook_path" ] || [ ! -x "$hook_path" ]; then
    echo "ERROR: required executable hook is missing: $hook_path" >&2
    exit 1
  fi
done

CURRENT_HOOKS_PATH=$(git -C "$WORKSPACE_ROOT" config --get core.hooksPath 2>/dev/null || true)
if [ -n "$CURRENT_HOOKS_PATH" ]; then
  case "$CURRENT_HOOKS_PATH" in
    "$DESIRED_HOOKS_PATH"|"./$DESIRED_HOOKS_PATH"|"$WORKSPACE_ROOT/$DESIRED_HOOKS_PATH")
      echo "Git hooks are already configured for $WORKSPACE_ROOT ($CURRENT_HOOKS_PATH)."
      exit 0
      ;;
    *)
      CURRENT_ORIGIN=$(git -C "$WORKSPACE_ROOT" config --show-origin --get core.hooksPath 2>/dev/null || true)
      echo "ERROR: core.hooksPath is already configured and was not changed." >&2
      echo "Current value: $CURRENT_HOOKS_PATH" >&2
      [ -z "$CURRENT_ORIGIN" ] || echo "Origin: $CURRENT_ORIGIN" >&2
      echo "Review the existing hook manager and choose an explicit integration strategy." >&2
      echo "The workflow kit hooks remain at: $WORKSPACE_ROOT/$DESIRED_HOOKS_PATH" >&2
      exit 2
      ;;
  esac
fi

git -C "$WORKSPACE_ROOT" config --local core.hooksPath "$DESIRED_HOOKS_PATH"
echo "Configured local Git hooks for $WORKSPACE_ROOT ($DESIRED_HOOKS_PATH)."
echo "To restore the default hooks path: git -C \"$WORKSPACE_ROOT\" config --local --unset core.hooksPath"
