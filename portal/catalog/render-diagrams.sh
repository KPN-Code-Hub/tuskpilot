#!/usr/bin/env bash
# Renders the Mermaid diagrams of the platform docs (docs/diagrams/*.mmd) to
# PNG next to them. TechDocs doesn't run Mermaid, so the pages embed the PNG;
# the .mmd is the source. Run it after editing a diagram and commit both.
#
#   ./render-diagrams.sh
#
# Needs Node (npx fetches mermaid-cli) and a Chrome for puppeteer: set
# PUPPETEER_EXECUTABLE_PATH, else the one `npx puppeteer browsers install
# chrome-headless-shell` put in ~/.cache/puppeteer is used.
set -euo pipefail
cd "$(dirname "$0")/docs/diagrams"

CHROME="${PUPPETEER_EXECUTABLE_PATH:-$(find ~/.cache/puppeteer/chrome-headless-shell -type f -name chrome-headless-shell 2>/dev/null | head -1)}"
if [[ -z "${CHROME}" ]]; then
  echo "No Chrome: set PUPPETEER_EXECUTABLE_PATH or run: npx puppeteer browsers install chrome-headless-shell" >&2
  exit 1
fi
CONFIG="$(mktemp)"
trap 'rm -f "${CONFIG}"' EXIT
printf '{"executablePath": "%s", "args": ["--no-sandbox"]}\n' "${CHROME}" >"${CONFIG}"

for src in *.mmd; do
  # -s 2: sharp on high-density screens; the page shows it at half the size.
  PUPPETEER_SKIP_DOWNLOAD=1 npx --yes @mermaid-js/mermaid-cli@11.4.2 \
    -p "${CONFIG}" -b '#0e0f13' -s 2 -i "${src}" -o "${src%.mmd}.png" >/dev/null
  echo "rendered ${src%.mmd}.png"
done
