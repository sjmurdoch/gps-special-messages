#!/usr/bin/env bash
# Footnote-integrity checker for the tracked article.
#
# Pandoc numbers footnotes by order of first REFERENCE, not by label value
# (see CLAUDE.md "Pandoc footnotes"). So a label renders as its own number
# only when the labels are 1..N and first appear in that order with no gaps.
# Removing or inserting a note silently renumbers everything after it, which
# desynchronises the article from CLAIMS.md (keyed by rendered number) and
# from in-text "(footnote N)" cross-references — and the rendered HTML still
# looks clean, so this can only be caught at the markdown level.
#
# Checks:
#   1. Definitions are contiguous [^1]..[^N], each defined exactly once.
#   2. Every reference has a definition and every definition is referenced.
#   3. First-reference order is [^1]..[^N] (=> label == rendered number).
#   4. Every CLAIMS.md footnote key exists in the article.
#   5. Every in-text "(footnote N)" cross-ref points to an existing note
#      (non-dangling; semantic correctness still needs human review).
#   6. If built, the HTML has N note bodies fn1..fnN matching the article.
#
# Usage: article/check_footnotes.sh [ARTICLE.md] [CLAIMS.md] [SITE_HTML]
# Exit:  0 = all checks pass, 1 = at least one failure.

set -uo pipefail
cd "$(dirname "$0")/.."

ART="${1:-article/the-empty-field-that-wasnt.md}"
CLAIMS="${2:-CLAIMS.md}"
HTML="${3:-article/site/index.html}"

[ -f "$ART" ]    || { echo "FAIL: article not found: $ART" >&2; exit 1; }
[ -f "$CLAIMS" ] || { echo "FAIL: CLAIMS file not found: $CLAIMS" >&2; exit 1; }

args=( "$ART" "$CLAIMS" )
[ -f "$HTML" ] && args+=( "$HTML" )

if awk -v ART="$ART" -v CLAIMS="$CLAIMS" -v HTML="$HTML" '
# ── Article: definitions, references (in order), prose cross-refs ──────────
FILENAME==ART {
  line=$0
  if (match(line,/^\[\^[0-9]+\]:/)) {                 # definition line
    lbl=substr(line,1,RLENGTH-1); gsub(/[^0-9]/,"",lbl)
    def[lbl+0]++
    line=substr(line,RLENGTH+1)                       # strip leading label
  }
  s=line                                              # remaining references
  while (match(s,/\[\^[0-9]+\]/)) {
    r=substr(s,RSTART,RLENGTH); gsub(/[^0-9]/,"",r)
    nref++; refseq[nref]=r+0
    s=substr(s,RSTART+RLENGTH)
  }
  t=$0                                                # prose "footnote N"
  while (match(t,/footnote [0-9]+/)) {
    p=substr(t,RSTART,RLENGTH); gsub(/[^0-9]/,"",p)
    nprose++; prose[nprose]=p+0; proseln[nprose]=FNR
    t=substr(t,RSTART+RLENGTH)
  }
  next
}
# ── CLAIMS.md: footnote keys ──────────────────────────────────────────────
FILENAME==CLAIMS {
  s=$0
  while (match(s,/\[\^[0-9]+\]/)) {
    r=substr(s,RSTART,RLENGTH); gsub(/[^0-9]/,"",r)
    claimk[r+0]++
    s=substr(s,RSTART+RLENGTH)
  }
  next
}
# ── Built HTML: note-body ids (fnN, not fnrefN) ───────────────────────────
FILENAME==HTML {
  htmlpresent=1
  s=$0
  while (match(s,/id="fn[0-9]+"/)) {
    m=substr(s,RSTART,RLENGTH); gsub(/[^0-9]/,"",m)
    fnbody[m+0]++
    s=substr(s,RSTART+RLENGTH)
  }
  next
}
END {
  rc=0
  ndef=0; maxdef=0
  for (k in def) { ndef++; if (k+0>maxdef) maxdef=k+0 }

  # Check 1: contiguous, no duplicates
  b=0
  for (i=1;i<=maxdef;i++) if (!(i in def)) { printf "FAIL: missing definition [^%d]\n",i; b=1; rc=1 }
  for (k in def) if (def[k]>1) { printf "FAIL: [^%d] defined %d times\n",k,def[k]; b=1; rc=1 }
  if (!b) printf "PASS: %d definitions, contiguous [^1]..[^%d]\n",ndef,maxdef

  # Check 2: reference/definition set equality
  for (i=1;i<=nref;i++) refset[refseq[i]]=1
  b=0
  for (k in refset) if (!(k in def)) { printf "FAIL: reference [^%d] has no definition\n",k; b=1; rc=1 }
  for (k in def)    if (!(k in refset)) { printf "FAIL: definition [^%d] is never referenced\n",k; b=1; rc=1 }
  if (!b) printf "PASS: every reference resolves and every definition is used\n"

  # Check 3: first-reference order == 1..N
  nf=0
  for (i=1;i<=nref;i++) { r=refseq[i]; if (!(r in seen)) { seen[r]=1; nf++; first[nf]=r } }
  b=0
  for (i=1;i<=nf;i++) if (first[i]!=i) { printf "FAIL: note #%d is first-referenced as [^%d] (renumbering: label != rendered number)\n",i,first[i]; b=1; rc=1; break }
  if (nf!=maxdef) { printf "FAIL: %d distinct labels referenced but highest label is %d\n",nf,maxdef; b=1; rc=1 }
  if (!b) printf "PASS: first-reference order is [^1]..[^%d] (every label renders as its own number)\n",maxdef

  # Check 4: CLAIMS keys exist
  b=0
  for (k in claimk) if (!(k in def)) { printf "FAIL: CLAIMS.md cites [^%d] but the article has no such footnote\n",k; b=1; rc=1 }
  if (!b) printf "PASS: all CLAIMS.md footnote keys resolve to article notes\n"

  # Check 5: prose cross-refs non-dangling
  b=0
  for (i=1;i<=nprose;i++) if (!(prose[i] in def)) { printf "FAIL: line %d cites \"footnote %d\" — no such note\n",proseln[i],prose[i]; b=1; rc=1 }
  if (!b) {
    printf "PASS: %d in-text \"footnote N\" cross-refs are non-dangling (targets:",nprose
    for (i=1;i<=nprose;i++) printf " %d",prose[i]
    printf ") -- verify topic match by eye\n"
  }

  # Check 6: rendered HTML
  if (htmlpresent) {
    nb=0; maxb=0; b=0
    for (k in fnbody) { nb++; if (k+0>maxb) maxb=k+0; if (fnbody[k]>1) { printf "FAIL: HTML has duplicate id=fn%d\n",k; b=1; rc=1 } }
    for (i=1;i<=maxb;i++) if (!(i in fnbody)) { printf "FAIL: HTML missing note body id=fn%d\n",i; b=1; rc=1 }
    if (nb!=ndef) { printf "FAIL: HTML has %d note bodies but article defines %d\n",nb,ndef; b=1; rc=1 }
    if (!b) printf "PASS: HTML renders %d note bodies, contiguous fn1..fn%d, matching the article\n",nb,maxb
  } else {
    printf "SKIP: %s not built — run article/build.sh to enable the rendered check\n",HTML
  }
  exit rc
}
' "${args[@]}"; then
  echo "------"
  echo "ALL CHECKS PASSED"
else
  echo "------"
  echo "FOOTNOTE CHECK FAILED"
  exit 1
fi
