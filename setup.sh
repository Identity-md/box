#!/bin/sh
# Installs the worker and the agent CLIs into the box's volume, as the box's user. Safe to run
# again: it reinstalls the latest of each.
set -eu

echo "Installing Claude Code and Grok…"
npm install --global --no-fund --no-audit --allow-scripts=@anthropic-ai/claude-code,@xai-official/grok \
  @anthropic-ai/claude-code @xai-official/grok >/dev/null

echo "Installing the IMD worker from its latest release, checking its SHA-256…"
dir=$(mktemp -d)
(cd "$dir" \
  && curl -fsSLO https://github.com/Identity-md/worker/releases/latest/download/identitymd-worker.tgz \
          -O https://github.com/Identity-md/worker/releases/latest/download/SHA256SUMS \
  && sha256sum -c SHA256SUMS)
npm install --global --no-fund --no-audit "$dir/identitymd-worker.tgz" >/dev/null
rm -rf "$dir"

echo
echo "Installed: $(claude --version 2>/dev/null | head -1), $(grok --version 2>/dev/null | head -1), imd, $(forge --version | head -1)"
echo
echo "Next, still in this box:"
echo "  1. claude              sign in (/login), accept the prompts, then /exit"
echo "  2. imd pair            pair this box with the wallet that holds your seat NFT"
echo "  3. imd doctor          check it end to end"
echo "  4. exit                then run ./box start on the Mac"
