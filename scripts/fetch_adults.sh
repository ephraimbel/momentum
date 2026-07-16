#!/bin/bash
# fetch_adults.sh <gender> <target> <outdir>
# Adults ONLY: cycles the adult age buckets the site exposes (19-25, 26-35, 35-50, 50+) — never
# 12-18 or all-ages (which is what let children into the pool). Weighted toward 26-50 for a real
# adult-community feel, with some young adults + some older. License-safe: faces depict no real person.
set -u
GENDER="$1"; TARGET="$2"; OUT="$3"
mkdir -p "$OUT"
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
BASE="https://this-person-does-not-exist.com"
HASHES="$OUT/.hashes"; : > "$HASHES"
# Weighted CLEARLY-adult buckets (repeats = weight). No 12-18, no 19-25 (both can look under-18),
# no all-ages. 26-35 / 35-50 / 50+ only — guarantees no child/teen faces.
AGES=(26-35 26-35 26-35 26-35 35-50 35-50 35-50 35-50 50 50)
i=0; attempts=0; maxattempts=$((TARGET*10))
while [ "$i" -lt "$TARGET" ] && [ "$attempts" -lt "$maxattempts" ]; do
  attempts=$((attempts+1))
  age=${AGES[$((RANDOM % ${#AGES[@]}))]}
  json=$(curl -s -m 15 -A "$UA" "$BASE/new?new&gender=$GENDER&age=$age&etnic=all" 2>/dev/null)
  src=$(printf '%s' "$json" | sed -E 's/.*"src":"([^"]+)".*/\1/' | sed 's#\\/#/#g')
  case "$src" in /img/*) ;; *) sleep 0.5; continue;; esac
  tmp="$OUT/.tmp.$$.jpg"
  code=$(curl -s -m 25 -A "$UA" -e "$BASE/" -o "$tmp" -w "%{http_code}" "$BASE$src" 2>/dev/null)
  bytes=$(stat -f%z "$tmp" 2>/dev/null || echo 0)
  if [ "$code" != "200" ] || [ "$bytes" -lt 50000 ]; then sleep 0.6; continue; fi
  if ! sips -g pixelWidth "$tmp" >/dev/null 2>&1; then sleep 0.4; continue; fi
  h=$(md5 -q "$tmp" 2>/dev/null)
  if grep -q "$h" "$HASHES" 2>/dev/null; then sleep 0.3; continue; fi   # dup face
  echo "$h" >> "$HASHES"
  sips -c 860 860 "$tmp" >/dev/null 2>&1   # crop bottom watermark
  sips -z 256 256 "$tmp" >/dev/null 2>&1   # resize
  out=$(printf "%s/%s-%03d.jpg" "$OUT" "$GENDER" "$i")
  mv "$tmp" "$out"
  i=$((i+1))
  if [ $((i % 20)) -eq 0 ]; then echo "$GENDER: $i/$TARGET (attempts $attempts)"; fi
  sleep 0.35
done
echo "$GENDER DONE: $i faces in $attempts attempts"
