#!/bin/sh
# Installs the worker and the agent CLIs into the box's volume, as the box's user. Safe to run
# again: it reinstalls the latest of each. Claude Code always; Codex and Grok only while the worker
# runs on them (IMD_RUNTIME, set by ./box and IMD Agents). One installed earlier and no longer used is
# removed, its sign-in kept for next time.
set -eu

runtime="${IMD_RUNTIME:-claude}"
case "$runtime" in *codex*) codex=yes ;; *) codex=no ;; esac
case "$runtime" in *grok*) grok=yes ;; *) grok=no ;; esac

packages="@anthropic-ai/claude-code"
scripts="@anthropic-ai/claude-code"
[ "$codex" = no ] || packages="$packages @openai/codex"
[ "$grok" = no ] || { packages="$packages @xai-official/grok"; scripts="$scripts,@xai-official/grok"; }
case "$codex$grok" in
  yesyes) names="Claude Code, Codex and Grok" ;;
  yesno) names="Claude Code and Codex" ;;
  noyes) names="Claude Code and Grok" ;;
  *) names="Claude Code" ;;
esac
echo "Installing $names…"
# shellcheck disable=SC2086 # one package per word
npm install --global --no-fund --no-audit --allow-scripts="$scripts" $packages >/dev/null
if [ "$codex" = no ] && command -v codex >/dev/null 2>&1; then npm uninstall --global @openai/codex >/dev/null; fi
if [ "$grok" = no ] && command -v grok >/dev/null 2>&1; then npm uninstall --global @xai-official/grok >/dev/null; fi

echo "Installing the IMD worker from its latest release, checking its SHA-256…"
dir=$(mktemp -d)
(cd "$dir" \
  && curl -fsSLO https://github.com/Identity-md/worker/releases/latest/download/identitymd-worker.tgz \
          -O https://github.com/Identity-md/worker/releases/latest/download/SHA256SUMS \
  && sha256sum -c SHA256SUMS)
npm install --global --no-fund --no-audit "$dir/identitymd-worker.tgz" >/dev/null
rm -rf "$dir"

# The image's browser, as the worker's `browser` tool: website steps come to a machine with one
# first. Everything but running code in the tool's own process and handing it local files.
echo "Connecting the browser…"
imd tools add browser --command /usr/local/bin/imd-browser \
  --enable browser_navigate --enable browser_navigate_back --enable browser_snapshot \
  --enable browser_take_screenshot --enable browser_resize --enable browser_emulate_media \
  --enable browser_click --enable browser_hover --enable browser_drag --enable browser_type \
  --enable browser_press_key --enable browser_fill_form --enable browser_select_option \
  --enable browser_handle_dialog --enable browser_wait_for --enable browser_find \
  --enable browser_evaluate --enable browser_console_messages --enable browser_network_requests \
  --enable browser_network_request --enable browser_tabs --enable browser_close >/dev/null \
  || echo "The browser isn't connected; website jobs still run, without it."

echo
installed="$(claude --version 2>/dev/null | head -1)"
[ "$codex" = no ] || installed="$installed, $(codex --version 2>/dev/null | head -1)"
[ "$grok" = no ] || installed="$installed, $(grok --version 2>/dev/null | head -1)"
echo "Installed: $installed, imd, $(forge --version | head -1)"
echo
# Whether the first-time steps are still to do, from which files exist; nothing is read. The sign-in is
# the one the worker's tasks run on, the first runtime named.
case "$runtime" in
  codex*) login="$HOME/.codex/auth.json"; how="codex login --device-auth   sign in with ChatGPT: open the link, enter the code" ;;
  *) login="$HOME/.claude/.credentials.json"; how="claude              sign in (/login), accept the prompts, then /exit" ;;
esac
if [ -s "$login" ] && [ -s "$HOME/.identitymd/config.json" ]; then
  echo "Signed in and paired already."
else
  echo "Next, still in this box:"
  echo "  1. $how"
  echo "  2. imd pair            pair this box with the wallet that holds your seat NFT"
  echo "  3. imd doctor          check it end to end"
  echo "  4. exit                then run ./box start on the Mac"
fi
