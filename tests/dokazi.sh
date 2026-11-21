#!/usr/bin/env bash
# Pokreće provjere koje README mora sadržavati i upisuje njihov stvarni izlaz u README.md
# između oznaka <!-- IZLAZ:ime --> i <!-- /IZLAZ:ime -->. Izlazi se čuvaju i u docs/izlazi/.
#   make dokazi   (nakon make all)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
mkdir -p docs/izlazi
bez_boja() { sed 's/\x1b\[[0-9;]*m//g'; }

echo "== 1/3 drugo izvršavanje (idempotentnost)"
make --no-print-directory idempotencija 2>&1 | bez_boja > docs/izlazi/idempotencija.txt || true
echo "== 2/3 testovi"
make --no-print-directory test 2>&1 | bez_boja > docs/izlazi/testovi.txt || true
echo "== 3/3 drift DNS zapisa"
bash tests/drift.sh 2>&1 | bez_boja > docs/izlazi/drift.txt || true

python3 - <<'PY'
import re, pathlib
readme = pathlib.Path("README.md")
s = readme.read_text(encoding="utf-8")
for ime in ["idempotencija", "testovi", "drift"]:
    izlaz = pathlib.Path(f"docs/izlazi/{ime}.txt").read_text(encoding="utf-8").rstrip()
    blok = f"<!-- IZLAZ:{ime} -->\n```text\n{izlaz}\n```\n<!-- /IZLAZ:{ime} -->"
    s, n = re.subn(rf"<!-- IZLAZ:{ime} -->.*?<!-- /IZLAZ:{ime} -->", lambda _: blok, s, flags=re.S)
    print(f"README: {ime} {'upisan' if n else 'OZNAKA NIJE NAĐENA'}")
readme.write_text(s, encoding="utf-8")
PY
