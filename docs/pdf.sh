#!/usr/bin/env bash
# Pravi PDF za predaju iz docs/odluke.md (pandoc + headless Chrome/Chromium). Prije toga upisati
# prezime i link na repozitorij u docs/odluke.md.   Upotreba: bash docs/pdf.sh
set -euo pipefail
cd "$(dirname "$0")"
CHROME="$(command -v google-chrome || command -v chromium || command -v chromium-browser)"
pandoc odluke.md -s -o /tmp/odluke.html --css "$PWD/pdf-stil.css" --metadata lang=bs -V pagetitle="Troslojna aplikacija kao kod"
sed -i 's|<header id="title-block-header">|&\n<div class="uni">Univerzitet u Zenici · Politehnički fakultet · Računarstvo u oblaku · Projektni zadatak, sedmice 2–5</div>|' /tmp/odluke.html
"$CHROME" --headless=new --no-sandbox --disable-gpu --no-pdf-header-footer --print-to-pdf="$PWD/RuO-Projekat-DO-ADR.pdf" /tmp/odluke.html 2>/dev/null
echo "napravljen docs/RuO-Projekat-DO-ADR.pdf"
