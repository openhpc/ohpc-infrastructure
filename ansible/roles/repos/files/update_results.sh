#!/bin/bash

set -ex

cd /results/$1/$2

if [ ! -e HEADER.html ]; then
	cp /home/ohpc/HEADER.tmpl HEADER.html
	sed -e "s,@@VERSION@@,$2,g" -i HEADER.html
fi

for i in *OHPC*; do
	if [ -e $i/FAIL ]; then
		echo "AddDescription \"<img src=\\\"/.files/test_error.png\\\"/>\" $i" >>.htaccess.new
	else
		echo "AddDescription \"<img src=\\\"/.files/test_ok.png\\\"/>\" $i" >>.htaccess.new
	fi
done
mv .htaccess.new .htaccess

sed '1,/<!-- END HEADER MARKER -->/!d' -i HEADER.html

TOTAL=$(echo 0-LATEST* | wc -w)

echo "<ul><li>Total number of test permutations: ${TOTAL}</li></ul>" >>HEADER.html

echo "<table><tr><th>Test</th><th>Total</th><th>PASS</th><th>FAIL</th><th>Overall</th><tr>" >>HEADER.html

FAIL=0
PASS=0
TOTAL=0

for i in $(ls 0-LATEST* -d | sort | cut -d- -f5 | uniq); do
	for l in 0*-$i-*; do
		((TOTAL += 1))
		if [ -e $l/FAIL ]; then
			((FAIL += 1))
		else
			((PASS += 1))
		fi
	done
	echo "<tr><td>$i</td><td>$TOTAL</td><td>$PASS</td><td>$FAIL</td><td>" >>HEADER.html
	if [ "$FAIL" -eq 0 ]; then
		echo "<img src=\"/.files/test_ok.png\"/>" >>HEADER.html
	elif [ "$PASS" -eq 0 ]; then
		echo "<img src=\"/.files/test_error.png\"/>" >>HEADER.html
	else
		echo "<img src=\"/.files/test_warning.png\"/>" >>HEADER.html
	fi
	echo "</td></tr>" >>HEADER.html

	FAIL=0
	PASS=0
	TOTAL=0
done

echo "</table>" >>HEADER.html


cd /results/$1

FAIL=0
PASS=0

if [ ! -e HEADER.html ]; then
	cp /home/ohpc/HEADER.tmpl HEADER.html
	sed -e "s,@@VERSION@@,$1,g" -i HEADER.html
fi

for i in ${1}*; do
	if [ ! -d $i ]; then
		continue
	fi
	for l in $i/*LATEST*; do
		if [ -e $l/FAIL ]; then
			((FAIL += 1))
		else
			((PASS += 1))
		fi
	done
	if [ "$FAIL" -eq 0 ]; then
		echo "AddDescription \"<img src=\\\"/.files/test_ok.png\\\"/>\" $i" >>.htaccess.new
	elif [ "$PASS" -eq 0 ]; then
		echo "AddDescription \"<img src=\\\"/.files/test_error.png\\\"/>\" $i" >>.htaccess.new
	else
		echo "AddDescription \"<img src=\\\"/.files/test_warning.png\\\"/>\" $i" >>.htaccess.new
	fi
	FAIL=0
	PASS=0
done
mv .htaccess.new .htaccess

cd /results/

if [ ! -e HEADER.html ]; then
	cp /home/ohpc/HEADER.tmpl HEADER.html
	sed -e "s,@@VERSION@@,Overall,g" -i HEADER.html
fi

for i in *; do
	if [ ! -d $i ]; then
		continue
	fi
	ERRORS=$(grep -c test_error $i/.htaccess || true)
	WARNINGS=$(grep -c test_warning $i/.htaccess || true)
	if [ "$ERRORS" -gt 0 ] && [ "$WARNINGS" -eq 0 ]; then
		echo "AddDescription \"<img src=\\\"/.files/test_error.png\\\"/>\" $i" >>.htaccess.new
	elif [ "$WARNINGS" -gt 0 ] && [ "$ERRORS" -eq 0 ]; then
		echo "AddDescription \"<img src=\\\"/.files/test_warning.png\\\"/>\" $i" >>.htaccess.new
	else
		echo "AddDescription \"<img src=\\\"/.files/test_ok.png\\\"/>\" $i" >>.htaccess.new
	fi
done
mv .htaccess.new .htaccess
