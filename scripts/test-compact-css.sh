#!/bin/bash
# Static checks for the 3.5 inch layout (app.css compact-screen block, app.js status strip). Runs on any
# host with a POSIX shell, grep and awk, no image needed:
#   bash scripts/test-compact-css.sh
# (replaces test-compact-css.py; same checks, same "ok   ..." / "FAIL ..." lines and exit status)
HERE=$(cd "$(dirname "$0")" && pwd)
WWW=$HERE/../overlay/usr/local/share/alnasl-setup/www
CSS=$WWW/app.css
JS=$WWW/app.js
fails=0
expect() { # expect 0|1 what   (1 = the condition held)
  if [ "$1" = 1 ]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails + 1)); fi
}

BLK=$(awk '/\/\* ==== compact-screen:/ { on = 1 } on { print } /\/\* ==== end compact-screen ==== \*\// { if (on) exit }' "$CSS")
has_start=$(grep -c '/\* ==== compact-screen:' "$CSS")
has_end=$(grep -c '/\* ==== end compact-screen ==== \*/' "$CSS")
delim=0; [ "$has_start" -ge 1 ] && [ "$has_end" -ge 1 ] && [ -n "$BLK" ] && delim=1
expect $delim "compact block is delimited"

opens=$(printf '%s' "$BLK" | tr -cd '{' | wc -c | tr -d ' ')
closes=$(printf '%s' "$BLK" | tr -cd '}' | wc -c | tr -d ' ')
b=0; [ "$opens" = "$closes" ] && b=1
expect $b "compact block braces balance"

m=0; printf '%s\n' "$BLK" | grep -qF '@media (max-width: 520px), (max-height: 360px)' && m=1
expect $m "compact layout sits behind the 520/360 media query"

s=0; printf '%s\n' "$BLK" | grep -q '^\.statusbar { display: none; }' && s=1
expect $s "status strip hidden on big screens"

# Everything between the markers other than the one hidden rule lives inside an @media block: count the
# top-level rules that are not @media blocks (the comments between the markers carry no braces).
outside=$(printf '%s\n' "$BLK" | awk '
  { text = text $0 "\n" }
  END {
    depth = 0; prefix = ""; n = 0
    for (i = 1; i <= length(text); i++) {
      c = substr(text, i, 1)
      if (c == "{") { if (depth == 0 && prefix !~ /@media/) n++; depth++ }
      else if (c == "}") { depth--; if (depth == 0) prefix = "" }
      else if (depth == 0) prefix = prefix c
    }
    print n
  }')
o=0; [ "$outside" = 1 ] && o=1
expect $o "no compact rule leaks outside a media query ($outside outside)"

# The tap targets: the first "SEL {" rule that has a min-height of 40 px or more.
tap() {
  printf '%s\n' "$BLK" | awk -v sel="$1 {" '
    { text = text $0 "\n" }
    END {
      rest = text; best = -1
      while ((p = index(rest, sel)) > 0) {
        rest = substr(rest, p + length(sel))
        rule = rest; q = index(rule, "}"); if (q > 0) rule = substr(rule, 1, q - 1)
        if (match(rule, /min-height: [0-9]+px/)) { v = substr(rule, RSTART + 12, RLENGTH - 14); best = v + 0; break }
      }
      print best
    }'
}
for sel in .tab .btn ".top .btn.sm" .item; do
  px=$(tap "$sel")
  t=0; [ "$px" -ge 40 ] 2>/dev/null && t=1
  expect $t "$sel keeps a tap target of 40 px or more"
done

h=1; printf '%s\n' "$BLK" | grep -q hover && h=0
expect $h "no hover-only control in the compact block"

up=$(grep -o 'st_up:' "$JS" | wc -l | tr -d ' ')
down=$(grep -o 'st_down:' "$JS" | wc -l | tr -d ' ')
w=0; [ "$up" = 2 ] && [ "$down" = 2 ] && w=1
expect $w "status strip words exist in EN and NL"

[ "$fails" -eq 0 ]
