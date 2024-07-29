#!/bin/bash

set -e

BASE=/var/log/httpd
LAST_MONTH=$(date -d "$(date +%Y-%m-1) -1 month" +%Y-%m)

for i in "${BASE}/${LAST_MONTH}"-??-{,ssl-}access; do
	cat "$i" >>"${BASE}/old/access_log_${LAST_MONTH}"
	rm -f "$i"
done
