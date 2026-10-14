#!/bin/sh
# Installs the worker and the agent CLIs into the box's volume, as the box's user. Safe to run
# again: it reinstalls the latest of each. Grok only while the worker runs on it (IMD_RUNTIME, set by
# ./box); otherwise a Grok installed earlier is removed and its sign-in kept for next time.
set -eu

case "${IMD_RUNTIME:-claude}" in *grok*) grok=yes ;; *) grok=no ;; esac

if [ "$grok" = yes ]; then
  echo "Installing Claude Code and Grok…"
  npm install --global --no-fund --no-audit --allow-scripts=@anthropic-ai/claude-code,@xai-official/grok \
    @anthropic-ai/claude-code @xai-official/grok >/dev/null
else
  echo "Installing Claude Code…"
  npm install --global --no-fund --no-audit --allow-scripts=@anthropic-ai/claude-code @anthropic-ai/claude-code >/dev/null
  if command -v grok >/dev/null 2>&1; then npm uninstall --global @xai-official/grok >/dev/null; fi
fi

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
[ "$grok" = no ] || installed="$installed, $(grok --version 2>/dev/null | head -1)"
echo "Installed: $installed, imd, $(forge --version | head -1)"
echo
# Whether the first-time steps are still to do, from which files exist; nothing is read.
if [ -s "$HOME/.claude/.credentials.json" ] && [ -s "$HOME/.identitymd/config.json" ]; then
  echo "Signed in and paired already."
else
  echo "Next, still in this box:"
  echo "  1. claude              sign in (/login), accept the prompts, then /exit"
  echo "  2. imd pair            pair this box with the wallet that holds your seat NFT"
  echo "  3. imd doctor          check it end to end"
  echo "  4. exit                then run ./box start on the Mac"
fi
