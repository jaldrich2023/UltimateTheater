#!/bin/zsh
# Rebuilds the user manual's HTML from docs/USER_MANUAL.md, then prints it to PDF with headless Chrome.
set -e
D="${0:A:h:h}"   # the docs folder
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
python3 -I "${0:A:h}/build_manual.py" "$D/USER_MANUAL.md" "$D/manual/Ultimate-Theater-User-Manual.html"
"$CHROME" --headless=new --disable-gpu --no-pdf-header-footer \
  --print-to-pdf="$D/Ultimate-Theater-User-Manual.pdf" "file://$D/manual/Ultimate-Theater-User-Manual.html" 2>/dev/null
ls -la "$D/Ultimate-Theater-User-Manual.pdf"
