#!/usr/bin/env bash
#
# check-basics.sh — end-to-end checks of clipboard redirection between the
# Windows mstsc client and MacRDP in the Tart VM: text, image, and files with
# a nested folder, in both directions. Each check prints PASS or FAIL.
#
#   ./scripts/check-basics.sh            # all checks
#   ./scripts/check-basics.sh text image # a subset: text image files
#
# Expects MacRDP running in the VM (scripts/tart-vm.sh up/deploy/start) and
# connects mstsc if needed (scripts/win-client.sh). Needs `guestcheck` in the
# VM: ./scripts/tart-vm.sh tool tools/guestcheck/guestcheck.swift
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VMSH="$REPO_ROOT/scripts/tart-vm.sh"
WINSH="$REPO_ROOT/scripts/win-client.sh"
WINDIR='$env:USERPROFILE\macrdp-test'
CHECKS=("$@"); [[ ${#CHECKS[@]} -gt 0 ]] || CHECKS=(text image files)
failures=0

vm() { "$VMSH" exec "$@"; }
win() { "$WINSH" "$@"; }
result() { # <name> <ok> <detail>
  if [[ "$2" == 1 ]]; then echo "PASS  $1  $3"; else echo "FAIL  $1  $3"; failures=$((failures + 1)); fi
}
# Clipboard ownership travels as a format list; give it a moment to land.
settle() { sleep 2; }

# "relative/path|size|sha256" lines for every file under a VM directory.
vm_manifest() {
  vm sh -c "cd '$1' && find . -type f | sed 's|^\./||' | sort | while read -r f; do
    printf '%s|%s|%s\n' \"\$f\" \"\$(stat -f %z \"\$f\")\" \"\$(shasum -a 256 \"\$f\" | cut -d' ' -f1)\"; done"
}

check_text() {
  local s="MacRDP clipboard 剪貼簿 ✓ $RANDOM" got want
  want="$(printf %s "$s" | shasum -a 256 | cut -d' ' -f1)"

  win clip "{\"op\": \"set-text\", \"text\": \"$s\"}" >/dev/null; settle
  got="$(vm /usr/local/bin/guestcheck clip-text-get 2>&1)"
  [[ "$(printf %s "$got" | shasum -a 256 | cut -d' ' -f1)" == "$want" ]] && ok=1 || ok=0
  result "text win->mac" $ok "got: $got"

  vm /usr/local/bin/guestcheck clip-text-set "$s"; settle
  got="$(win clip '{"op": "get-text"}' | head -1 | tr -d '\r\357\273\277')"
  [[ "$got" == "utf8-sha256=$want" ]] && ok=1 || ok=0
  result "text mac->win" $ok "$got"
}

check_image() {
  local got
  win ps "Add-Type -AssemblyName System.Drawing; \$b = New-Object Drawing.Bitmap 320,200
    for (\$x = 0; \$x -lt 320; \$x++) { for (\$y = 0; \$y -lt 200; \$y += 4) { \$b.SetPixel(\$x, \$y, [Drawing.Color]::FromArgb(\$x % 256, \$y, 128)) } }
    New-Item -ItemType Directory -Force \"$WINDIR\\clip\" | Out-Null; \$b.Save(\"$WINDIR\\clip\\win-img.png\")"
  win clip "{\"op\": \"set-image\", \"path\": \"C:\\\\Users\\\\hujkconsole\\\\macrdp-test\\\\clip\\\\win-img.png\"}" >/dev/null; settle
  got="$(vm /usr/local/bin/guestcheck clip-image-get /tmp/win-img.png 2>&1)"
  [[ "$got" == "320x200" ]] && ok=1 || ok=0
  result "image win->mac" $ok "got: $got"

  vm sh -c '/usr/sbin/screencapture -x -R0,0,320,200 /tmp/mac-img.png && /usr/local/bin/guestcheck clip-image-set /tmp/mac-img.png'; settle
  got="$(win clip '{"op": "get-image", "path": "C:\\Users\\hujkconsole\\macrdp-test\\clip\\mac-img.png"}' | tr -d '\r\357\273\277')"
  [[ "$got" =~ ^[0-9]+x[0-9]+$ ]] && ok=1 || ok=0
  result "image mac->win" $ok "got: $got"
}

check_files() {
  local want got paths
  # Windows source: a text file, a 3 MiB binary, a folder with a nested binary.
  want="$(win ps "\$d = \"$WINDIR\\clipsrc\"; Remove-Item -Recurse -Force \$d -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force \"\$d\\folder\\sub\" | Out-Null
    [IO.File]::WriteAllText(\"\$d\\hello.txt\", 'hello from windows')
    \$r = New-Object byte[] 3145728; (New-Object Random 42).NextBytes(\$r); [IO.File]::WriteAllBytes(\"\$d\\blob.bin\", \$r)
    [IO.File]::WriteAllText(\"\$d\\folder\\a.txt\", 'a')
    \$r = New-Object byte[] 1048576; (New-Object Random 7).NextBytes(\$r); [IO.File]::WriteAllBytes(\"\$d\\folder\\sub\\b.bin\", \$r)
    Get-ChildItem \$d -Recurse -File | ForEach-Object { \"\$(\$_.FullName.Substring(\$d.Length + 1).Replace('\\', '/'))|\$(\$_.Length)|\$((Get-FileHash \$_.FullName).Hash.ToLower())\" } | Sort-Object" | tr -d '\r')"
  win clip '{"op": "set-files", "paths": ["C:\\Users\\hujkconsole\\macrdp-test\\clipsrc\\hello.txt", "C:\\Users\\hujkconsole\\macrdp-test\\clipsrc\\blob.bin", "C:\\Users\\hujkconsole\\macrdp-test\\clipsrc\\folder"]}' >/dev/null
  settle
  paths="$(vm /usr/local/bin/guestcheck clip-files-get 2>&1)"
  vm sh -c 'rm -rf /tmp/clipdst && mkdir -p /tmp/clipdst'
  while IFS= read -r p; do
    [[ -n "$p" ]] && vm /bin/cp -R "$p" /tmp/clipdst/ 2>&1 | head -2
  done <<< "$paths"
  got="$(vm_manifest /tmp/clipdst)"
  [[ "$got" == "$want" ]] && ok=1 || ok=0
  result "files win->mac" $ok "$(echo "$got" | wc -l | tr -d ' ') files; pasteboard: $(echo "$paths" | tr '\n' ' ')"
  [[ $ok == 1 ]] || diff <(echo "$want") <(echo "$got") | sed 's/^/      /'

  # Mac source, same shape, in a fresh folder so the pasteboard always
  # changes; copied in Finder and pasted with Ctrl+V in Explorer, as a user
  # would (a tool writing several file URLs keeps only the first, and a
  # scripted Shell paste behaves differently from Explorer's).
  local src="/tmp/clipsrc-$RANDOM"
  vm sh -c "mkdir -p $src/mac-folder/sub && cd $src &&
    printf 'hello from mac' > mac-hello.txt && head -c 3145728 /dev/urandom > mac-blob.bin &&
    printf a > mac-folder/a.txt && head -c 1048576 /dev/urandom > mac-folder/sub/b.bin"
  want="$(vm_manifest "$src")"
  vm /usr/local/bin/guestcheck finder-copy "$src" >/dev/null
  settle
  win ps "Remove-Item -Recurse -Force \"$WINDIR\\clipdst\" -ErrorAction SilentlyContinue; exit 0"
  got="$(win paste 'C:\\Users\\hujkconsole\\macrdp-test\\clipdst' 180 |
    tr -d '\r\357\273\277' | sed 's|\\|/|g' | sort)"
  [[ "$got" == "$want" ]] && ok=1 || ok=0
  result "files mac->win" $ok "$(echo "$got" | grep -c '|') files"
  [[ $ok == 1 ]] || diff <(echo "$want") <(echo "$got") | sed 's/^/      /'
}

"$WINSH" connect >/dev/null || exit 1
for c in "${CHECKS[@]}"; do "check_$c"; done
echo "$failures failure(s)"
exit $((failures > 0))
