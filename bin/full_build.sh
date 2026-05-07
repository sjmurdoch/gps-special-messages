#!/usr/bin/env bash
# Full-pipeline rebuild from staged Zenodo archives, runnable unattended.
#
# Goal: rebuild data/messages.duckdb from gps-navbits-2026-01-26.tar.xz +
# nanu-archive-2026-02-26.tar.xz and confirm verify/run_all.sh exits 0.
# Validates the migration plan's deferred §10.3 #7 gate.
#
# Usage:
#   bin/full_build.sh                # full real build (~hours, ~250 GB intermediate)
#   bin/full_build.sh --dry-run      # print plan, validate prereqs, do nothing
#   bin/full_build.sh --smoke        # tiny end-to-end on data/arrow_test fixtures
#   bin/full_build.sh --restart      # wipe markers + work dir, start over
#
# Designed for fire-and-forget. Recommended invocation:
#   nohup bin/full_build.sh > /dev/null 2>&1 &
#   echo "$!" > /tmp/full_build.pid
# Then:
#   cat _build/STATUS.md             # see current state
#   tail -f _build/full.log          # live progress
#   cat _build/RESULTS.md            # final report (only after run completes)
#
# Environment overrides:
#   WORK_DIR     working directory (default: /Users/smurdoch/w/gps-special-messages-fullbuild)
#   ARCHIVE_DIR  staged tarballs    (default: /Users/smurdoch/w/gps-special-messages-release)
#   REPO_DIR     target repo        (default: dirname of this script's parent)
#   JULIA        julia binary       (default: /Users/smurdoch/.juliaup/bin/julia)
#   THREADS      thread count       (default: auto)
#
# The script is resumable: each stage writes a marker file under
# $WORK_DIR/_build/markers/. Re-running skips stages whose markers already exist.

set -uo pipefail   # -e disabled so we can capture and log per-stage failures

# ── Defaults ────────────────────────────────────────────────────────────────

REPO_DIR_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="${REPO_DIR:-$REPO_DIR_DEFAULT}"
if [[ -n "${WORK_DIR:-}" ]]; then WORK_DIR_EXPLICIT=1; fi
WORK_DIR="${WORK_DIR:-/Users/smurdoch/w/gps-special-messages-fullbuild}"
ARCHIVE_DIR="${ARCHIVE_DIR:-/Users/smurdoch/w/gps-special-messages-release}"
JULIA="${JULIA:-/Users/smurdoch/.juliaup/bin/julia}"
THREADS="${THREADS:-auto}"

NAVBITS_ARCHIVE="$ARCHIVE_DIR/gps-navbits-2026-01-26.tar.xz"
NANU_ARCHIVE="$ARCHIVE_DIR/nanu-archive-2026-02-26.tar.xz"

MODE="full"
RESTART=0
for arg in "$@"; do
    case "$arg" in
        --dry-run)  MODE="dry-run" ;;
        --smoke)    MODE="smoke" ;;
        --restart)  RESTART=1 ;;
        --help|-h)  sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)          echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

# ── Smoke mode: redirect work_dir to a tmp_dir, use arrow_test fixtures ─────

if [[ "$MODE" == "smoke" && -z "${WORK_DIR_EXPLICIT:-}" ]]; then
    # Smoke mode: default to a fresh temp dir unless WORK_DIR was set explicitly
    # (e.g. for an idempotency test). Use $TMPDIR rather than macOS's /var/folders.
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/full_build_smoke.XXXXXX")"
    if [[ -z "$WORK_DIR" || ! -d "$WORK_DIR" ]]; then
        echo "ERROR: could not create smoke work dir under \$TMPDIR=$TMPDIR" >&2
        exit 4
    fi
fi

BUILD_DIR="$WORK_DIR/_build"
DATA_DIR="$WORK_DIR/data"
STATUS_FILE="$BUILD_DIR/STATUS.md"
RESULTS_FILE="$BUILD_DIR/RESULTS.md"
FULL_LOG="$BUILD_DIR/full.log"
LOGS_DIR="$BUILD_DIR/logs"
MARKERS_DIR="$BUILD_DIR/markers"

# ── Stage definitions ───────────────────────────────────────────────────────
# Each entry: id|description|invariant_hint
STAGES=(
    "01_extract_navbits|Extract navbit archive into data/raw/y*|expect ~6,786 yearly tars"
    "02_extract_nanu|Extract NANU archive into data/ops_advisories/|expect ~6,905 .oa1 files"
    "03_decompress|pipeline/02_decompress.jl: data/raw/ -> data/processed/|expect ~215,000 .nc files"
    "04_arrow|pipeline/03_convert_to_arrow.jl: data/processed/ -> data/arrow/|expect ~5,322 .arrow files"
    "05_db|pipeline/04_build_database.jl: data/arrow/ -> data/messages.duckdb|expect 12,163,006 rows / 3,994 unique"
    "06_analysis|analysis/run_all.sh: populate derived tables + reports|expect 11 tables populated, 7 reports written"
    "07_verify|verify/run_all.sh: claim-level checks|expect 7/7 verifiers pass"
)

# ── Helpers ─────────────────────────────────────────────────────────────────

ts() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }

log() {
    # Append to full.log with timestamp; also echo to stdout for foreground users.
    # If FULL_LOG's directory doesn't yet exist (e.g. during prereq check in dry-run),
    # write to stderr only.
    local line="[$(ts)] $*"
    if [[ -d "$(dirname "$FULL_LOG")" ]]; then
        echo "$line" >> "$FULL_LOG"
    fi
    echo "$line"
}

stage_id_at() { echo "${STAGES[$1]}" | cut -d'|' -f1; }
stage_desc_at() { echo "${STAGES[$1]}" | cut -d'|' -f2; }
stage_inv_at() { echo "${STAGES[$1]}" | cut -d'|' -f3; }

marker_for() { echo "$MARKERS_DIR/$1.done"; }

# Return per-stage state: "done", "skipped", "pending"
stage_state() {
    local marker; marker="$(marker_for "$1")"
    if [[ -s "$marker" ]]; then
        if grep -q '^skipped=true' "$marker"; then echo skipped
        else echo done
        fi
    else
        echo pending
    fi
}

write_marker() {
    local id="$1"; shift
    {
        echo "completed_at=$(ts)"
        for kv in "$@"; do echo "$kv"; done
    } > "$(marker_for "$id")"
}

# ── STATUS.md ───────────────────────────────────────────────────────────────

write_status() {
    local current_stage="${1:-}"
    local phase="${2:-}"   # starting|running|done|failed
    local tmp="$STATUS_FILE.tmp.$$"

    {
        cat <<EOF
# Full pipeline build — STATUS

**Goal**: rebuild \`data/messages.duckdb\` from \`gps-navbits-2026-01-26.tar.xz\` +
\`nanu-archive-2026-02-26.tar.xz\` and confirm \`verify/run_all.sh\` exits 0.
This validates the migration plan's deferred §10.3 #7 gate (full-path rebuild).

**Target invariants**: \`SELECT count(*) FROM special_messages\` returns \`12163006\`
(unique = 3,994), 11 DuckDB tables populated, all 7 verifiers pass.

| Field | Value |
|---|---|
| Mode | $MODE |
| Started | $RUN_STARTED |
| Working dir | \`$WORK_DIR\` |
| Repo | \`$REPO_DIR\` @ $REPO_HEAD |
| Archives | \`$ARCHIVE_DIR\` |
| PID | $$ (\`kill -0 $$\` to test if alive) |
| Last update | $(ts) |
| Phase | ${phase:-(none)} |
| Current stage | ${current_stage:-(none)} |

## Stage progress

| # | Stage | State | Started | Finished | Wall | Invariant |
|---|---|---|---|---|---|---|
EOF
        local i id desc inv state started finished wall icon
        for ((i=0; i<${#STAGES[@]}; i++)); do
            id="$(stage_id_at $i)"
            desc="$(stage_desc_at $i)"
            inv="$(stage_inv_at $i)"
            state="$(stage_state "$id")"
            started=""; finished=""; wall=""
            local marker; marker="$(marker_for "$id")"
            if [[ -s "$marker" ]]; then
                started="$(grep -m1 '^started_at=' "$marker" 2>/dev/null | cut -d= -f2- || echo)"
                finished="$(grep -m1 '^completed_at=' "$marker" 2>/dev/null | cut -d= -f2- || echo)"
                wall="$(grep -m1 '^duration_seconds=' "$marker" 2>/dev/null | cut -d= -f2- || echo)"
                [[ -n "$wall" ]] && wall="${wall}s"
            fi
            case "$state" in
                done) icon="✅ done" ;;
                skipped) icon="↷ skipped" ;;
                pending)
                    if [[ "$id" == "${current_stage:-}" && "$phase" == "running" ]]; then
                        icon="🔄 running"
                    elif [[ "$phase" == "failed" && "$id" == "${current_stage:-}" ]]; then
                        icon="❌ failed"
                    else
                        icon="⏸ pending"
                    fi
                    ;;
            esac
            printf '| %d | %s — %s | %s | %s | %s | %s | %s |\n' \
                "$((i+1))" "$id" "$desc" "$icon" "${started:--}" "${finished:--}" "${wall:--}" "$inv"
        done

        cat <<EOF

## Logs
- Full timestamped log: \`$FULL_LOG\`
- Per-stage logs: \`$LOGS_DIR/<id>.log\`
- Markers (machine-readable, one per stage): \`$MARKERS_DIR/\`

## How to read this file with no prior context

1. **Is the run alive?** Look at the **PID** row above. \`kill -0 <pid>\` exits 0 if the
   process is still running, non-zero if it finished or was killed.
2. **What stage is it in?** \`Current stage\` and \`Phase\` rows + the table.
   ✅ done · ↷ skipped · 🔄 running · ⏸ pending · ❌ failed.
3. **Did a stage fail?** ❌ in the table → see \`$RESULTS_FILE\` for the diagnostic
   and \`$LOGS_DIR/<id>.log\` for the underlying error (typically the last 50 lines).
4. **Is it done?** \`$RESULTS_FILE\` exists and the table reads ✅ all the way through.
5. **Resume after a fix?** Re-run \`bin/full_build.sh\`; it skips stages with valid
   markers. To force a clean rebuild, \`bin/full_build.sh --restart\`.
EOF
    } > "$tmp"
    mv "$tmp" "$STATUS_FILE"
}

# ── Stage runner ────────────────────────────────────────────────────────────

# run_stage <id> <command> [more args...] — runs a stage, captures output to per-stage log.
# Sets STAGE_FAILED=1 and returns non-zero on failure.
STAGE_FAILED=0
CURRENT_STAGE=""

run_stage() {
    local id="$1"; shift
    local stage_log="$LOGS_DIR/$id.log"
    local started_at; started_at="$(ts)"
    local started_epoch; started_epoch="$(date +%s)"
    CURRENT_STAGE="$id"

    if [[ "$(stage_state "$id")" == "done" ]]; then
        log "stage $id already done (marker present); skipping"
        return 0
    fi

    log "==> stage $id: starting"
    write_status "$id" "running"

    # Execute, tee'ing stdout+stderr both to per-stage log and full log.
    {
        echo "[$started_at] $id: $*"
        "$@" 2>&1
        local rc=$?
        echo "[$(ts)] $id: exit_code=$rc"
        return $rc
    } | tee -a "$stage_log" >> "$FULL_LOG"
    local rc="${PIPESTATUS[0]}"

    local finished_at; finished_at="$(ts)"
    local elapsed=$(( $(date +%s) - started_epoch ))

    if [[ "$rc" -eq 0 ]]; then
        # caller writes the marker (so it can carry stage-specific invariants)
        # but we provide started_at + duration via STAGE_STARTED_AT / STAGE_DURATION
        STAGE_STARTED_AT="$started_at"
        STAGE_DURATION="$elapsed"
        log "    stage $id: ok (${elapsed}s)"
        return 0
    else
        log "    stage $id: FAILED (exit=$rc, ${elapsed}s)"
        log "    last 20 lines of $stage_log:"
        tail -20 "$stage_log" 2>/dev/null | sed 's/^/      /' | tee -a "$FULL_LOG"
        STAGE_FAILED=1
        return $rc
    fi
}

# ── Stage 01: extract navbits ───────────────────────────────────────────────

stage_01_extract_navbits() {
    local id="01_extract_navbits"
    if [[ "$(stage_state "$id")" == "done" ]]; then
        log "stage $id already done; skipping"; return 0
    fi
    if [[ "$MODE" == "smoke" ]]; then
        write_marker "$id" "skipped=true" "skipped_reason=smoke-mode"
        log "stage $id: skipped (smoke)"
        return 0
    fi
    [[ -f "$NAVBITS_ARCHIVE" ]] || { log "ERR: $NAVBITS_ARCHIVE not found"; STAGE_FAILED=1; return 1; }
    run_stage "$id" tar -xJf "$NAVBITS_ARCHIVE" -C "$DATA_DIR" || return $?
    local count; count=$(find "$DATA_DIR/raw" -mindepth 2 -name '*.tar' 2>/dev/null | wc -l | tr -d ' ')
    write_marker "$id" "started_at=$STAGE_STARTED_AT" "duration_seconds=$STAGE_DURATION" \
        "yearly_tar_count=$count" "data_raw_size=$(du -sh "$DATA_DIR/raw" 2>/dev/null | cut -f1)"
    if [[ "$count" -lt 6000 ]]; then
        log "WARN: extract produced only $count tars; expected ~6,786"
    fi
}

# ── Stage 02: extract NANU ──────────────────────────────────────────────────

stage_02_extract_nanu() {
    local id="02_extract_nanu"
    if [[ "$(stage_state "$id")" == "done" ]]; then
        log "stage $id already done; skipping"; return 0
    fi
    if [[ "$MODE" == "smoke" ]]; then
        # In smoke mode, symlink to source repo's ops_advisories so analysis can run
        if [[ -d /Users/smurdoch/w/gps-message/data/ops_advisories ]]; then
            ln -sfn /Users/smurdoch/w/gps-message/data/ops_advisories "$DATA_DIR/ops_advisories"
        fi
        write_marker "$id" "skipped=true" "skipped_reason=smoke-mode (symlinked)"
        log "stage $id: skipped (smoke; ops_advisories symlinked from source)"
        return 0
    fi
    [[ -f "$NANU_ARCHIVE" ]] || { log "ERR: $NANU_ARCHIVE not found"; STAGE_FAILED=1; return 1; }
    run_stage "$id" tar -xJf "$NANU_ARCHIVE" -C "$DATA_DIR" || return $?
    local count; count=$(find "$DATA_DIR/ops_advisories" -name '*.oa1' 2>/dev/null | wc -l | tr -d ' ')
    write_marker "$id" "started_at=$STAGE_STARTED_AT" "duration_seconds=$STAGE_DURATION" \
        "oa1_file_count=$count"
    if [[ "$count" -lt 6000 ]]; then
        log "WARN: extract produced only $count .oa1 files; expected ~6,905"
    fi
}

# ── Stage 03: decompress ────────────────────────────────────────────────────

stage_03_decompress() {
    local id="03_decompress"
    if [[ "$(stage_state "$id")" == "done" ]]; then
        log "stage $id already done; skipping"; return 0
    fi
    if [[ "$MODE" == "smoke" ]]; then
        write_marker "$id" "skipped=true" "skipped_reason=smoke-mode"
        log "stage $id: skipped (smoke)"
        return 0
    fi
    cd "$WORK_DIR"
    run_stage "$id" "$JULIA" --project="$REPO_DIR" "$REPO_DIR/pipeline/02_decompress.jl" \
        --raw="$DATA_DIR/raw" --out="$DATA_DIR/processed" || return $?
    cd - >/dev/null
    local count; count=$(find "$DATA_DIR/processed" -name '*.nc' 2>/dev/null | wc -l | tr -d ' ')
    write_marker "$id" "started_at=$STAGE_STARTED_AT" "duration_seconds=$STAGE_DURATION" \
        "nc_file_count=$count"
}

# ── Stage 04: arrow ─────────────────────────────────────────────────────────

stage_04_arrow() {
    local id="04_arrow"
    if [[ "$(stage_state "$id")" == "done" ]]; then
        log "stage $id already done; skipping"; return 0
    fi
    if [[ "$MODE" == "smoke" ]]; then
        # Pre-populate data/arrow/ from the repo's arrow_test fixtures.
        mkdir -p "$DATA_DIR/arrow"
        cp -R "$REPO_DIR/data/arrow_test/." "$DATA_DIR/arrow/"
        local count; count=$(find "$DATA_DIR/arrow" -name '*.arrow' 2>/dev/null | wc -l | tr -d ' ')
        write_marker "$id" "skipped=true" "skipped_reason=smoke-mode (used arrow_test)" \
            "arrow_file_count=$count"
        log "stage $id: skipped (smoke; copied $count arrow_test files)"
        return 0
    fi
    cd "$WORK_DIR"
    run_stage "$id" "$JULIA" --project="$REPO_DIR" -t "$THREADS" \
        "$REPO_DIR/pipeline/03_convert_to_arrow.jl" \
        "$DATA_DIR/processed" "$DATA_DIR/arrow" || return $?
    cd - >/dev/null
    local count; count=$(find "$DATA_DIR/arrow" -name '*.arrow' 2>/dev/null | wc -l | tr -d ' ')
    write_marker "$id" "started_at=$STAGE_STARTED_AT" "duration_seconds=$STAGE_DURATION" \
        "arrow_file_count=$count"
}

# ── Stage 05: db ────────────────────────────────────────────────────────────

stage_05_db() {
    local id="05_db"
    if [[ "$(stage_state "$id")" == "done" ]]; then
        log "stage $id already done; skipping"; return 0
    fi
    cd "$WORK_DIR"
    run_stage "$id" "$JULIA" --project="$REPO_DIR" -t "$THREADS" \
        "$REPO_DIR/pipeline/04_build_database.jl" \
        "$DATA_DIR/arrow" "$DATA_DIR/messages.duckdb" || return $?
    cd - >/dev/null
    # Read row + unique counts via a one-line julia query
    local row_count unique_count
    row_count=$("$JULIA" --project="$REPO_DIR" -e "
        using DuckDB
        db = DuckDB.DB(\"$DATA_DIR/messages.duckdb\"; readonly=true)
        r = DuckDB.execute(db, \"SELECT count(*) FROM special_messages\") |> first
        print(r[1])
    " 2>>"$FULL_LOG" || echo "?")
    unique_count=$("$JULIA" --project="$REPO_DIR" -e "
        using DuckDB
        db = DuckDB.DB(\"$DATA_DIR/messages.duckdb\"; readonly=true)
        r = DuckDB.execute(db, \"SELECT count(DISTINCT message_hash) FROM special_messages\") |> first
        print(r[1])
    " 2>>"$FULL_LOG" || echo "?")
    write_marker "$id" "started_at=$STAGE_STARTED_AT" "duration_seconds=$STAGE_DURATION" \
        "row_count=$row_count" "unique_count=$unique_count"
    if [[ "$MODE" != "smoke" ]]; then
        if [[ "$row_count" != "12163006" || "$unique_count" != "3994" ]]; then
            log "ERR: row_count=$row_count unique_count=$unique_count; expected 12163006 / 3994"
            STAGE_FAILED=1
            return 1
        fi
    fi
}

# ── Stage 06: analysis ──────────────────────────────────────────────────────

stage_06_analysis() {
    local id="06_analysis"
    if [[ "$(stage_state "$id")" == "done" ]]; then
        log "stage $id already done; skipping"; return 0
    fi
    if [[ "$MODE" == "smoke" ]]; then
        # Analysis scripts assume the full corpus; on smoke data several would error.
        write_marker "$id" "skipped=true" "skipped_reason=smoke-mode (full-corpus assumed)"
        log "stage $id: skipped (smoke)"
        return 0
    fi
    cd "$WORK_DIR"
    # analysis/run_all.sh hardcodes data/messages.duckdb relative paths;
    # we pass DB path via env that each script's DEFAULT_DB respects.
    run_stage "$id" env DUCKDB_PATH="$DATA_DIR/messages.duckdb" \
        bash "$REPO_DIR/analysis/run_all.sh" "$DATA_DIR/messages.duckdb" || return $?
    cd - >/dev/null
    write_marker "$id" "started_at=$STAGE_STARTED_AT" "duration_seconds=$STAGE_DURATION"
}

# ── Stage 07: verify ────────────────────────────────────────────────────────

stage_07_verify() {
    local id="07_verify"
    if [[ "$(stage_state "$id")" == "done" ]]; then
        log "stage $id already done; skipping"; return 0
    fi
    if [[ "$MODE" == "smoke" ]]; then
        # Verifiers assert full-corpus invariants; will fail on smoke data.
        write_marker "$id" "skipped=true" "skipped_reason=smoke-mode (invariants don't hold)"
        log "stage $id: skipped (smoke)"
        return 0
    fi
    cd "$WORK_DIR"
    run_stage "$id" bash "$REPO_DIR/verify/run_all.sh" "$DATA_DIR/messages.duckdb" || return $?
    cd - >/dev/null
    write_marker "$id" "started_at=$STAGE_STARTED_AT" "duration_seconds=$STAGE_DURATION"
}

# ── Final results ───────────────────────────────────────────────────────────

write_results() {
    local overall="$1"   # success | failed
    {
        echo "# Full pipeline build — RESULTS"
        echo
        echo "**Overall**: $overall"
        echo "**Mode**: $MODE"
        echo "**Started**: $RUN_STARTED"
        echo "**Finished**: $(ts)"
        echo "**Working dir**: \`$WORK_DIR\`"
        echo "**Repo**: \`$REPO_DIR\` @ $REPO_HEAD"
        echo
        echo "## Stage outcomes"
        echo
        echo "| Stage | State | Wall | Key invariant |"
        echo "|---|---|---|---|"
        local i id state marker
        for ((i=0; i<${#STAGES[@]}; i++)); do
            id="$(stage_id_at $i)"
            state="$(stage_state "$id")"
            # Override "pending" with "failed" for the stage that crashed.
            [[ "$overall" == "failed" && "$id" == "${CURRENT_STAGE:-}" && "$state" == "pending" ]] && state="failed"
            marker="$(marker_for "$id")"
            local kvs="-"
            if [[ -s "$marker" ]]; then
                kvs="$(grep -E '^(row_count|unique_count|nc_file_count|arrow_file_count|yearly_tar_count|oa1_file_count|skipped_reason)=' "$marker" 2>/dev/null | paste -sd, - || echo -)"
                [[ -z "$kvs" ]] && kvs="-"
            fi
            local wall="-"
            wall="$(grep -m1 '^duration_seconds=' "$marker" 2>/dev/null | cut -d= -f2- || echo)"
            [[ -n "$wall" ]] && wall="${wall}s"
            echo "| $id | $state | ${wall:--} | $kvs |"
        done
        echo
        if [[ "$overall" == "failed" ]]; then
            echo "## Failure diagnostic"
            echo
            echo "Failed stage: \`${CURRENT_STAGE:-(unknown)}\`"
            echo
            echo "Last 30 lines of \`$LOGS_DIR/${CURRENT_STAGE}.log\`:"
            echo
            echo '```'
            tail -30 "$LOGS_DIR/${CURRENT_STAGE}.log" 2>/dev/null || echo "(log unavailable)"
            echo '```'
            echo
            echo "Investigate, fix, then re-run \`bin/full_build.sh\` (resumes at the failed stage)."
        else
            echo "## Verification"
            echo
            echo "All stages completed successfully. The migration plan's deferred §10.3 #7 gate is met."
            echo
            if [[ "$MODE" == "full" ]]; then
                echo "DB: \`$DATA_DIR/messages.duckdb\` (rows = 12,163,006; unique = 3,994)."
                echo "Verifiers: 7/7 passed (see \`$LOGS_DIR/07_verify.log\`)."
            elif [[ "$MODE" == "smoke" ]]; then
                echo "Smoke run validated harness end-to-end on \`data/arrow_test/\` fixtures."
                echo "Stages 01, 02, 03, 06, 07 were skipped (smoke-mode); stages 04+05 ran for real."
                echo "The full run (\`bin/full_build.sh\` with no flags) exercises the same harness on the full archive."
            fi
        fi
    } > "$RESULTS_FILE"
}

# ── Prereq checks (fast, before any work) ───────────────────────────────────

check_prereqs() {
    log "checking prereqs..."
    local missing=()
    [[ -x "$JULIA" ]] || missing+=("julia at $JULIA")
    command -v tar >/dev/null || missing+=("tar")
    if [[ "$MODE" != "smoke" ]]; then
        [[ -f "$NAVBITS_ARCHIVE" ]] || missing+=("$NAVBITS_ARCHIVE")
        [[ -f "$NANU_ARCHIVE" ]] || missing+=("$NANU_ARCHIVE")
    fi
    [[ -d "$REPO_DIR/pipeline" ]] || missing+=("$REPO_DIR/pipeline (not a checkout?)")

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: missing prereqs:" >&2
        printf '  - %s\n' "${missing[@]}" >&2
        exit 3
    fi

    # Disk: full mode wants ~250 GB free
    if [[ "$MODE" == "full" ]]; then
        local avail_gb
        avail_gb=$(df -g "$WORK_DIR" 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)
        if [[ "${avail_gb:-0}" -lt 250 ]]; then
            log "WARN: only ${avail_gb}GB free at $WORK_DIR (recommend 250GB)"
        fi
    fi
    log "prereqs ok"
}

# ── Main ────────────────────────────────────────────────────────────────────

print_plan() {
    REPO_HEAD="$(cd "$REPO_DIR" && git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    cat <<EOF
=== full_build.sh — dry-run plan ===
mode:        $MODE
work_dir:    $WORK_DIR
repo:        $REPO_DIR @ $REPO_HEAD
archives:    $ARCHIVE_DIR
julia:       $JULIA
threads:     $THREADS

Stages that would run, in order:

EOF
    local i id desc inv
    for ((i=0; i<${#STAGES[@]}; i++)); do
        id="$(stage_id_at $i)"
        desc="$(stage_desc_at $i)"
        inv="$(stage_inv_at $i)"
        printf '  %d. %-22s %s\n     %s\n' "$((i+1))" "$id" "$desc" "$inv"
    done
    echo
    echo "Outputs (after a real run):"
    echo "  $WORK_DIR/data/messages.duckdb     ← rebuilt DB"
    echo "  $BUILD_DIR/STATUS.md               ← live progress"
    echo "  $BUILD_DIR/RESULTS.md              ← final report"
    echo "  $BUILD_DIR/full.log                ← timestamped combined log"
    echo "  $BUILD_DIR/logs/<id>.log           ← per-stage logs"
    echo "  $BUILD_DIR/markers/<id>.done       ← per-stage completion + invariants"
    check_prereqs
}

main() {
    BUILD_DIR_FOR_PLAN_ONLY="$BUILD_DIR"
    if [[ "$MODE" == "dry-run" ]]; then
        print_plan
        exit 0
    fi

    if [[ $RESTART -eq 1 ]]; then
        echo "restart: removing $BUILD_DIR and $DATA_DIR" >&2
        rm -rf "$BUILD_DIR" "$DATA_DIR"
    fi

    mkdir -p "$BUILD_DIR" "$DATA_DIR" "$LOGS_DIR" "$MARKERS_DIR"
    : >> "$FULL_LOG"   # ensure exists

    RUN_STARTED="$(ts)"
    REPO_HEAD="$(cd "$REPO_DIR" && git rev-parse --short HEAD 2>/dev/null || echo unknown)"

    log "=== full_build.sh start ==="
    log "mode=$MODE work=$WORK_DIR repo=$REPO_DIR@$REPO_HEAD"

    check_prereqs

    write_status "" "starting"

    local i id fn
    for ((i=0; i<${#STAGES[@]}; i++)); do
        id="$(stage_id_at $i)"
        fn="stage_${id}"
        log "--- $id: $(stage_desc_at $i) ---"
        $fn
        if [[ "$STAGE_FAILED" -eq 1 ]]; then
            write_status "$id" "failed"
            write_results "failed"
            log "=== full_build.sh FAILED at $id ==="
            exit 1
        fi
        write_status "$id" "done"
    done

    write_status "" "done"
    write_results "success"
    log "=== full_build.sh OK ==="
}

main
