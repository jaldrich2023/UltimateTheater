#!/bin/zsh
# Prints the brochure (docs/brochure/Ultimate-Theater-Brochure.html) to PDF with headless Chrome.
set -e
D="${0:A:h:h}"   # the docs folder
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
"$CHROME" --headless=new --disable-gpu --no-pdf-header-footer \
  --print-to-pdf="$D/Ultimate-Theater-Brochure.pdf" "file://$D/brochure/Ultimate-Theater-Brochure.html" 2>/dev/null
ls -la "$D/Ultimate-Theater-Brochure.pdf"
