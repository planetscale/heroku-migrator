#!/usr/bin/env bash
set -u
# =============================================================================
# verify-migration.sh -- compare source and target before cutover.
#
# Catalog comparisons plus sampled exact row counts, so no full table scans.
# Reads HEROKU_URL (source) and PLANETSCALE_URL (target). Migrator metadata is
# excluded from every comparison. Requires bash for process substitution.
#
# Exit: 0 all checks passed, 1 warnings only, 2 differences or unable to verify.
# =============================================================================

SRC="${HEROKU_URL:-}"
TGT="${PLANETSCALE_URL:-}"
if [ -z "$SRC" ] || [ -z "$TGT" ]; then
  echo "ERROR: HEROKU_URL and PLANETSCALE_URL must be set."
  exit 2
fi

# Schemas/tables that belong to the migration tooling, not the user's data.
ART_SCHEMAS="'pg_catalog','information_schema','pg_toast','bucardo','_ps_migrator','pscale_extensions'"
# Relations an extension owns, schema-qualified
EXT_OWNED="SELECT en.nspname||'.'||ec.relname FROM pg_class ec
           JOIN pg_namespace en ON en.oid = ec.relnamespace
           JOIN pg_depend ed ON ed.classid = 'pg_class'::regclass
                            AND ed.objid = ec.oid AND ed.deptype = 'e'"
ART_TABLE="_ps_migration_state"

PASS=0; FAIL=0; WARN=0
pass() { PASS=$((PASS+1)); echo "  [PASS] $*"; }
fail() { FAIL=$((FAIL+1)); echo "  [FAIL] $*"; }
warn() { WARN=$((WARN+1)); echo "  [WARN] $*"; }
info() { echo "  - $*"; }
section() { echo ""; echo "==================================================================="; echo "  $1"; echo "==================================================================="; }


QERR="$(mktemp)"
trap 'rm -f "$QERR"' EXIT

q() {
  local out err rc
  err="$(mktemp)"
  out="$(psql "$1" -X -t -A -F $'\t' -c "$2" 2>"$err")"; rc=$?
  if [ "$rc" -ne 0 ]; then
    { echo "query failed (psql exit $rc): $(printf '%s' "$2" | tr '\n' ' ' | cut -c1-120)"
      sed 's/^/    /' "$err"; } >> "$QERR"
  fi
  rm -f "$err"
  printf '%s\n' "$out" | grep -v '^$' || true
}

check_queries() {
  [ -s "$QERR" ] || return 0
  echo ""
  fail "Verification aborted: a catalog query failed, so these comparisons cannot be trusted."
  sed 's/^/         /' "$QERR"
  echo ""
  echo "RESULT: FAILED — verification could not be completed."
  exit 2
}

lc() { printf '%s' "${1:-}" | grep -c . || true; }

# ---------------------------------------------------------------------------
section "1  CONNECTIONS"
if q "$SRC" "SELECT 1" | grep -q 1; then pass "Source (Heroku) connected"; else fail "Cannot connect to source"; echo "RESULT: FAILED"; exit 2; fi
if q "$TGT" "SELECT 1" | grep -q 1; then pass "Target (PlanetScale) connected"; else fail "Cannot connect to target"; echo "RESULT: FAILED"; exit 2; fi
info "Source: $(q "$SRC" "SHOW server_version" | head -1)   Target: $(q "$TGT" "SHOW server_version" | head -1)"

# ---------------------------------------------------------------------------
section "2  TABLES"
TBL="SELECT n.nspname||'.'||c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
     WHERE c.relkind IN ('r','p') AND n.nspname NOT IN ($ART_SCHEMAS) AND c.relname<>'$ART_TABLE'
       AND n.nspname||'.'||c.relname NOT IN ($EXT_OWNED) ORDER BY 1"
ST=$(q "$SRC" "$TBL"); TT=$(q "$TGT" "$TBL")
check_queries
info "Source tables: $(lc "$ST")   Target tables: $(lc "$TT")"

if [ "$(lc "$ST")" -eq 0 ]; then
  fail "Source has no user tables — wrong database, or the schema was never created."
  echo ""; echo "RESULT: FAILED — nothing to verify against."; exit 2
fi
MISS=$(comm -23 <(echo "$ST"|sort) <(echo "$TT"|sort) 2>/dev/null || true)
EXTRA=$(comm -13 <(echo "$ST"|sort) <(echo "$TT"|sort) 2>/dev/null || true)
[ -z "$MISS" ] && pass "All source tables present in target" || { fail "Tables missing in target ($(lc "$MISS")):"; echo "$MISS" | sed 's/^/         /'; }
[ -z "$EXTRA" ] && pass "No unexpected extra tables in target" || { warn "Extra tables in target ($(lc "$EXTRA")):"; echo "$EXTRA" | sed 's/^/         /'; }

# ---------------------------------------------------------------------------
section "3  COLUMNS"
COL="SELECT table_schema||'.'||table_name||' '||column_name||' '||data_type||' null='||is_nullable||' def='||COALESCE(column_default,'-')
     FROM information_schema.columns WHERE table_schema NOT IN ($ART_SCHEMAS) AND table_name<>'$ART_TABLE'
       AND table_schema||'.'||table_name NOT IN ($EXT_OWNED)
     ORDER BY 1"
MISS=$(comm -23 <(q "$SRC" "$COL"|sort) <(q "$TGT" "$COL"|sort) 2>/dev/null || true)
[ -z "$MISS" ] && pass "All column definitions match" || { fail "Columns missing/changed in target ($(lc "$MISS")):"; echo "$MISS" | head -30 | sed 's/^/         /'; }
check_queries

# ---------------------------------------------------------------------------
section "4  INDEXES"
IDX="SELECT schemaname||'.'||tablename||' '||indexname||' '||indexdef FROM pg_indexes
     WHERE schemaname NOT IN ($ART_SCHEMAS) AND tablename<>'$ART_TABLE'
       AND schemaname||'.'||tablename NOT IN ($EXT_OWNED) ORDER BY 1"
MISS=$(comm -23 <(q "$SRC" "$IDX"|sort) <(q "$TGT" "$IDX"|sort) 2>/dev/null || true)
EXTRA=$(comm -13 <(q "$SRC" "$IDX"|sort) <(q "$TGT" "$IDX"|sort) 2>/dev/null || true)
[ -z "$MISS" ] && pass "All indexes present in target" || { fail "Indexes missing in target ($(lc "$MISS")):"; echo "$MISS" | head -30 | sed 's/^/         /'; }
[ -n "$EXTRA" ] && { warn "Extra indexes in target ($(lc "$EXTRA")):"; echo "$EXTRA" | head -10 | sed 's/^/         /'; }
check_queries

# ---------------------------------------------------------------------------
section "5  CONSTRAINTS (PK / FK / UNIQUE / CHECK; NOT NULL excluded)"
# contype is "char"; without the cast the || is ambiguous and the whole query errors.
CON="SELECT n.nspname||'.'||t.relname||' '||c.conname||' '||c.contype::text||' '||pg_get_constraintdef(c.oid,true)
     FROM pg_constraint c JOIN pg_class t ON t.oid=c.conrelid JOIN pg_namespace n ON n.oid=t.relnamespace
     WHERE n.nspname NOT IN ($ART_SCHEMAS) AND t.relname<>'$ART_TABLE' AND c.contype<>'n'
       AND n.nspname||'.'||t.relname NOT IN ($EXT_OWNED) ORDER BY 1"
MISS=$(comm -23 <(q "$SRC" "$CON"|sort) <(q "$TGT" "$CON"|sort) 2>/dev/null || true)
[ -z "$MISS" ] && pass "All constraints present and matching in target" || { fail "Constraints missing/changed in target ($(lc "$MISS")):"; echo "$MISS" | head -30 | sed 's/^/         /'; }
check_queries

# ---------------------------------------------------------------------------
section "6  SEQUENCES"
SEQ="SELECT n.nspname||'.'||c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
     WHERE c.relkind='S' AND n.nspname NOT IN ($ART_SCHEMAS)
        AND n.nspname||'.'||c.relname NOT IN ($EXT_OWNED) ORDER BY 1"
MISS=$(comm -23 <(q "$SRC" "$SEQ"|sort) <(q "$TGT" "$SEQ"|sort) 2>/dev/null || true)
[ -z "$MISS" ] && pass "All sequences present in target ($(lc "$(q "$SRC" "$SEQ")") sequences)" || { fail "Sequences missing in target:"; echo "$MISS" | sed 's/^/         /'; }

# Values, not just names
SEQV="SELECT n.nspname||'.'||c.relname, COALESCE(COALESCE(s.last_value, s.start_value)::text,'')
      FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      LEFT JOIN pg_sequences s ON s.schemaname=n.nspname AND s.sequencename=c.relname
      WHERE c.relkind='S' AND n.nspname NOT IN ($ART_SCHEMAS)
        AND n.nspname||'.'||c.relname NOT IN ($EXT_OWNED) ORDER BY 1"
SRC_SEQV=$(q "$SRC" "$SEQV"); TGT_SEQV=$(q "$TGT" "$SEQV")
check_queries
BEHIND=""; UNREAD=""; SEQ_OK=0
while IFS=$'\t' read -r sname sval; do
  [ -z "${sname:-}" ] && continue
  # Not readable on the source (no pg_sequences row): nothing to compare.
  if [ -z "${sval:-}" ]; then UNREAD="$UNREAD$sname"$'\n'; continue; fi
  tval=$(printf '%s\n' "$TGT_SEQV" | awk -F'\t' -v n="$sname" '$1==n {print $2; exit}')
  if [ -z "$tval" ]; then UNREAD="$UNREAD$sname"$'\n'; continue; fi
  if [ "$tval" -lt "$sval" ]; then
    BEHIND="$BEHIND$(printf '%-45s source=%s target=%s' "$sname" "$sval" "$tval")"$'\n'
  else
    SEQ_OK=$((SEQ_OK+1))
  fi
done <<< "$SRC_SEQV"
if [ -n "$BEHIND" ]; then
  fail "Sequences behind the source ($(lc "$BEHIND")) — will cause duplicate key errors after cutover:"
  printf '%s' "$BEHIND" | sed 's/^/         /'
elif [ "$SEQ_OK" -gt 0 ]; then
  pass "All $SEQ_OK sequence value(s) at or ahead of the source"
fi
[ -n "$UNREAD" ] && { warn "Could not read target value for $(lc "$UNREAD") sequence(s):"; printf '%s' "$UNREAD" | sed 's/^/         /'; }

# ---------------------------------------------------------------------------
# Exact COUNT(*) on up to 10 random tables under 10 GB, 60s each. Larger
# tables are skipped.
section "7  EXACT ROW COUNTS (random sample of up to 10 tables under 10 GB; exact COUNT(*))"
# format('%I.%I') so names needing quotes (mixed case, spaces) are usable as-is;
# read -r so a name with spaces stays one table.
SAMPLE="SELECT format('%I.%I', n.nspname, c.relname) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
        CROSS JOIN LATERAL (SELECT GREATEST(pg_total_relation_size(c.oid),
            (SELECT coalesce(sum(pg_total_relation_size(t.relid)),0)
             FROM pg_partition_tree(c.oid) t)) AS sz) z
        WHERE c.relkind IN ('r','p') AND n.nspname NOT IN ($ART_SCHEMAS) AND c.relname<>'$ART_TABLE'
          AND n.nspname NOT IN (
            SELECT en.nspname FROM pg_extension e
            JOIN pg_namespace en ON en.oid = e.extnamespace
            WHERE en.nspname NOT IN ('public','pg_catalog'))
          AND NOT EXISTS (
            SELECT 1 FROM pg_depend d
            WHERE d.classid='pg_class'::regclass AND d.objid=c.oid AND d.deptype='e')
          AND z.sz > 0
          AND z.sz < 10 * 1024^3   -- skip relations >= 10 GB
        ORDER BY random() LIMIT 10"

CNT_ERR=""
count_rows() { # url, quoted_table
  local err out rc
  err="$(mktemp)"
  out="$(psql "$1" -X -t -A -c "SET statement_timeout='60s'" -c "SELECT count(*) FROM $2" 2>"$err")"; rc=$?
  CNT_ERR="$(tr '\n' ' ' < "$err")"; rm -f "$err"
  [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -E '^[0-9]+$' | tail -1
}

EX_FAIL=0; EX_OK=0; EX_SKIP=0
while IFS= read -r tbl; do
  [ -z "$tbl" ] && continue
  sc=$(count_rows "$SRC" "$tbl"); serr="$CNT_ERR"
  tc=$(count_rows "$TGT" "$tbl"); terr="$CNT_ERR"
  if [ -z "$sc" ] || [ -z "$tc" ]; then
    EX_SKIP=$((EX_SKIP+1))
    # A timeout is expected on big tables; anything else is a real problem.
    if printf '%s%s' "$serr" "$terr" | grep -qi "statement timeout"; then
      warn "$(printf '%-45s count timed out (not verified)' "$tbl")"
    else
      fail "$(printf '%-45s count failed: %s' "$tbl" "$(printf '%s%s' "$serr" "$terr" | cut -c1-80)")"
    fi
    continue
  fi
  if [ "$sc" = "$tc" ]; then pass "$(printf '%-45s %s = %s' "$tbl" "$sc" "$tc")"; EX_OK=$((EX_OK+1));
  else fail "$(printf '%-45s src=%s tgt=%s (diff %s)' "$tbl" "$sc" "$tc" "$(( sc - tc ))")"; EX_FAIL=$((EX_FAIL+1)); fi
done <<< "$(q "$SRC" "$SAMPLE")"
check_queries
if [ "$EX_FAIL" -eq 0 ] && [ "$EX_OK" -gt 0 ]; then
  if [ "$EX_SKIP" -gt 0 ]; then info "$EX_OK sampled table(s) have identical row counts; $EX_SKIP not verified."
  else info "All $EX_OK sampled tables have identical row counts."; fi
fi
[ "$EX_FAIL" -gt 0 ] && info "Note: if live traffic is still flowing, small exact-count diffs can be replication lag — re-run when quiet."

# ---------------------------------------------------------------------------
# With writes frozen, pending deltas must reach 0 -- proof the target has
# applied every queued change.
section "8  BUCARDO DELTAS (target caught up)"
if ! command -v bucardo >/dev/null 2>&1; then
  info "bucardo CLI not available — skipping delta check"
else
  DOUT=$(bucardo delta 2>&1)
  if printf '%s\n' "$DOUT" | grep -qiE 'No (matching )?databases'; then
    info "Bucardo has no source databases to check (replication torn down or not configured)"
  else
    DLINES=$(printf '%s\n' "$DOUT" | grep -iE 'Total deltas for database' || true)
    if [ -z "$DLINES" ]; then
      printf '%s\n' "$DOUT" | sed 's/^/         /'
      warn "Could not determine pending delta counts from 'bucardo delta' output"
    else
      DTOTAL=0
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        dname=$(printf '%s' "$line" | sed -E 's/.*[Dd]atabase[[:space:]]+//; s/[[:space:]]*:.*$//' | tr -d '"')
        dn=$(printf '%s' "$line" | tr -d ',' | grep -oE '[0-9]+' | tail -1); dn=${dn:-0}
        DTOTAL=$((DTOTAL + dn))
        if [ "$dn" -gt 0 ]; then
          fail "Total deltas for database $dname: $dn — not yet applied to target"
        else
          info "$dname: 0 pending deltas"
        fi
      done < <(printf '%s\n' "$DLINES")
      if [ "$DTOTAL" -eq 0 ]; then
        pass "All Bucardo deltas drained — target is caught up (0 pending deltas)"
      else
        info "Writes are blocked, so this should reach 0 shortly; re-run once Bucardo drains and purges."
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
section "9  EXTENSIONS"
EXT="SELECT extname||' '||extversion FROM pg_extension ORDER BY 1"
MISS=$(comm -23 <(q "$SRC" "$EXT"|sort) <(q "$TGT" "$EXT"|sort) 2>/dev/null || true)
[ -z "$MISS" ] && pass "All extensions present and same version in target" || { warn "Extensions missing/version-mismatched in target:"; echo "$MISS" | sed 's/^/         /'; }
check_queries

# ---------------------------------------------------------------------------
section "SUMMARY"
echo "  PASSED:   $PASS"
echo "  WARNINGS: $WARN"
echo "  FAILED:   $FAIL"
echo ""
if [ "$FAIL" -gt 0 ]; then echo "RESULT: FAILED — $FAIL critical difference(s); review above before cutover."; exit 2
elif [ "$WARN" -gt 0 ]; then echo "RESULT: VERIFIED WITH WARNINGS — review $WARN warning(s)."; exit 1
else echo "RESULT: ALL CHECKS PASSED — source and target match."; exit 0; fi
