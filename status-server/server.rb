#!/usr/bin/env ruby
# frozen_string_literal: true

# Lightweight HTTP status server for monitoring Bucardo migration progress.
# Exposes endpoints:
#   GET  /              - HTML dashboard UI
#   GET  /status        - Returns current migration status as JSON
#   GET  /health        - Basic health check (no auth)
#   GET  /logs          - Returns recent Bucardo logs
#   POST /switch-traffic - Revokes write access on Heroku
#   POST /revert-switch  - Restores write access on Heroku
#   POST /cleanup        - Runs rm-bucardo-repl.sh to tear down replication

require "webrick"
require "webrick/httpauth"
require "json"
require "tmpdir"
require "tempfile"
require "fileutils"
require "net/http"
require "uri"
require "time"

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
STATE_DIR = "/opt/bucardo/state"
STATUS_FILE = File.join(STATE_DIR, "status.json")
COPY_PROGRESS_FILE = File.join(STATE_DIR, "copy_progress.json")
SETUP_LOG_FILE = File.join(STATE_DIR, "setup.log")
BUCARDO_LOG_FILE = "/var/log/bucardo/log.bucardo"
SCRIPTS_DIR = "/opt/bucardo/scripts"
VERIFY_FILE = File.join(STATE_DIR, "verify.out")

HEROKU_URL = ENV["HEROKU_URL"]
PLANETSCALE_URL = ENV["PLANETSCALE_URL"]

PORT = (ENV["PORT"] || 8080).to_i

# ---------------------------------------------------------------------------
# Deferred index rebuild: drop secondary/unique indexes before the copy
# (drop-secondary-indexes.sh), rebuild in parallel after, with delta apply paused.
# ---------------------------------------------------------------------------
INDEX_REBUILD_WORKERS = ((ENV["INDEX_REBUILD_WORKERS"] || "4").to_i).clamp(1, 100)
MAINTENANCE_WORK_MEM = ENV["MAINTENANCE_WORK_MEM"] || "1GB"
PARALLEL_MAINTENANCE_WORKERS = ((ENV["PARALLEL_MAINTENANCE_WORKERS"] || "2").to_i).clamp(0, 32)
INDEX_DEFERRAL_DISABLED = ENV["DISABLE_INDEX_DEFERRAL"]&.downcase == "true"
REBUILD_LOG_POINTER = File.join(STATE_DIR, "current_rebuild_log")
REBUILD_LOG_LEGACY = File.join(STATE_DIR, "index-rebuild.log")

def current_rebuild_log
  name = (File.read(REBUILD_LOG_POINTER).strip rescue "")
  name.empty? ? REBUILD_LOG_LEGACY : File.join(STATE_DIR, name)
end

def start_new_rebuild_log
  name = "index-rebuild-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}.log"
  File.write(REBUILD_LOG_POINTER, name)
  File.join(STATE_DIR, name)
rescue StandardError
  REBUILD_LOG_LEGACY
end
# Dashboard-settable override for the number of parallel index builds. Persisted
# in the state dir so it survives restarts; falls back to INDEX_REBUILD_WORKERS.
REBUILD_WORKERS_FILE = File.join(STATE_DIR, "rebuild_workers")
REBUILD_WORKERS_MAX = 100

# ---------------------------------------------------------------------------
# Slack Notifications (enabled by default, disable with DISABLE_NOTIFICATIONS=true)
# ---------------------------------------------------------------------------
SLACK_WEBHOOK_URL = "https://hooks.slack.com/triggers/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"
NOTIFICATIONS_ENABLED = ENV["DISABLE_NOTIFICATIONS"]&.downcase != "true"

# Parse branch ID from PlanetScale connection string username
# Username format: pscale_api_xxx.BRANCH_ID
PS_BRANCH_ID = begin
  user = PLANETSCALE_URL&.split("/")&.dig(2)&.split(":")&.first
  user&.split(".")&.last
rescue
  nil
end

# ---------------------------------------------------------------------------
# HTTP Basic Auth
# ---------------------------------------------------------------------------
PASSWORD = ENV.fetch("PASSWORD")
AUTH_DISABLED = ENV["DISABLE_AUTH"]&.downcase == "true"
realm = "PlanetScale Migration"
htpasswd = WEBrick::HTTPAuth::Htpasswd.new("/tmp/.htpasswd")
htpasswd.set_passwd(realm, "admin", PASSWORD)
AUTHENTICATOR = WEBrick::HTTPAuth::BasicAuth.new(Realm: realm, UserDB: htpasswd)

def require_auth(req, res)
  return if AUTH_DISABLED
  AUTHENTICATOR.authenticate(req, res)
end

# ---------------------------------------------------------------------------
# Helper methods
# ---------------------------------------------------------------------------
def notify_slack(message)
  return unless NOTIFICATIONS_ENABLED
  return if SLACK_WEBHOOK_URL.empty?
  Thread.new do
    begin
      uri = URI.parse(SLACK_WEBHOOK_URL)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 5
      http.read_timeout = 5
      req = Net::HTTP::Post.new(uri.path, { "Content-Type" => "application/json" })
      req.body = JSON.generate({ text: message })
      http.request(req)
    rescue => e
      $stderr.puts "Slack notification failed: #{e.message}"
    end
  end
end

def branch_tag
  PS_BRANCH_ID ? " (branch: #{PS_BRANCH_ID})" : ""
end

def filter_harmless_pg_warnings(output)
  output.lines.reject { |line|
    line =~ /\AWARNING:\s+no privileges (?:could be revoked|were granted) for/
  }.join
end

# Phase transition tracking for milestone notifications
$last_notified_phase = nil
$last_notified_copy_phase = nil

def check_milestone_notifications(status_data)
  return unless NOTIFICATIONS_ENABLED
  phase = status_data["phase"]
  copy_phase = status_data.dig("bucardo", "initial_copy_phase")
  tables_in_sync = status_data.dig("bucardo", "tables_in_sync")

  # Only notify on transitions
  return if phase == $last_notified_phase && copy_phase == $last_notified_copy_phase

  case phase
  when "starting"
    if $last_notified_phase.nil?
      notify_slack(":rocket: Migration started#{branch_tag}")
    end
  when "configuring"
    if $last_notified_phase != "configuring"
      notify_slack(":gear: Configuring replication#{branch_tag}")
    end
  when "ready_to_copy"
    if $last_notified_phase != "ready_to_copy"
      table_info = tables_in_sync ? " -- #{tables_in_sync} tables" : ""
      notify_slack(":white_check_mark: Schema copied, ready to start data copy#{branch_tag}#{table_info}")
    end
  when "copying"
    if $last_notified_phase != "copying"
      notify_slack(":arrows_counterclockwise: Data copy started#{branch_tag}")
    end
  when "rebuilding_indexes"
    if $last_notified_phase != "rebuilding_indexes"
      notify_slack(":hammer_and_wrench: Initial copy complete -- rebuilding indexes#{branch_tag}")
    end
  when "index_rebuild_failed"
    if $last_notified_phase != "index_rebuild_failed"
      failed = status_data.dig("index_rebuild", "failed")
      notify_slack(":warning: Index rebuild finished with #{failed || 'some'} failure(s) -- replication paused for review#{branch_tag}")
    end
  when "replicating"
    if $last_notified_phase != "replicating"
      notify_slack(":white_check_mark: Databases in sync#{branch_tag}")
    end
  when "switched"
    if $last_notified_phase != "switched"
      notify_slack(":warning: Traffic switched -- Heroku writes revoked#{branch_tag}")
    end
  when "cleaning_up"
    if $last_notified_phase != "cleaning_up"
      notify_slack(":broom: Cleaning up replication#{branch_tag}")
    end
  when "completed"
    if $last_notified_phase != "completed"
      notify_slack(":tada: Migration complete!#{branch_tag}")
    end
  when "error"
    if $last_notified_phase != "error"
      error_msg = status_data["error"]&.to_s&.slice(0, 200)
      notify_slack(":x: Migration error#{branch_tag}: #{error_msg || 'Unknown error'}")
    end
  end

  $last_notified_phase = phase
  $last_notified_copy_phase = copy_phase
end

# ---------------------------------------------------------------------------
# Persistent migration state (survives Heroku dyno restarts)
# ---------------------------------------------------------------------------
def ps_migrate_query(sql)
  `psql "#{PLANETSCALE_URL}" -A -t -c "#{sql}" 2>/dev/null`.strip
end

# Migrator bookkeeping lives in _ps_migrator (not public); removed on
# Complete/Abort via rm-bucardo-repl.sh.
MIGRATION_STATE_TABLE = "_ps_migrator.migration_state"

def ensure_migration_state_table
  ps_migrate_query("CREATE SCHEMA IF NOT EXISTS _ps_migrator; CREATE TABLE IF NOT EXISTS #{MIGRATION_STATE_TABLE} (id integer PRIMARY KEY DEFAULT 1, phase text NOT NULL, started_at text, switched_at text, completed_at text, error text, updated_at text)")
end

def read_persistent_state
  return nil unless PLANETSCALE_URL
  row = ps_migrate_query("SELECT phase, started_at, switched_at, completed_at, error FROM #{MIGRATION_STATE_TABLE} WHERE id = 1")
  return nil if row.empty?
  parts = row.split("|", -1)
  return nil if parts.length < 5
  { "phase" => parts[0], "started_at" => parts[1], "switched_at" => parts[2], "completed_at" => parts[3], "error" => parts[4] }
rescue
  nil
end

def write_persistent_state(phase, extras = {})
  return unless PLANETSCALE_URL
  ensure_migration_state_table
  now = Time.now.utc.iso8601
  switched = extras[:switched_at] || "NULL"
  completed = extras[:completed_at] || "NULL"
  error_val = extras[:error]&.gsub("'", "''") || ""
  started = extras[:started_at] || now

  ps_migrate_query("INSERT INTO #{MIGRATION_STATE_TABLE} (id, phase, started_at, switched_at, completed_at, error, updated_at) VALUES (1, '#{phase}', '#{started}', #{switched == 'NULL' ? 'NULL' : "'#{switched}'"}, #{completed == 'NULL' ? 'NULL' : "'#{completed}'"}, '#{error_val}', '#{now}') ON CONFLICT (id) DO UPDATE SET phase = '#{phase}', switched_at = #{switched == 'NULL' ? 'NULL' : "'#{switched}'"}, completed_at = #{completed == 'NULL' ? 'NULL' : "'#{completed}'"}, error = '#{error_val}', updated_at = '#{now}'")
rescue => e
  $stderr.puts "Failed to write persistent state: #{e.message}"
end

def read_status_file
  if File.exist?(STATUS_FILE)
    JSON.parse(File.read(STATUS_FILE))
  else
    { "phase" => "unknown", "state" => "unknown", "message" => "Status file not found" }
  end
rescue JSON::ParserError
  { "phase" => "unknown", "state" => "unknown", "message" => "Status file corrupted" }
end

def get_bucardo_status
  # Capture stdout directly; Dir.mktmpdir can fail on a non-sticky /tmp.
  raw = `bucardo status planetscale_import 2>/dev/null`

  return nil if raw.nil? || raw.strip.empty?

  result = { "raw" => raw }

  raw.each_line do |line|
    case line
    when /^Status\s+:\s+(.+)/
      result["active"] = $1.strip
    when /^Current state\s+:\s+(.+)/
      state = $1.strip
      normalized = state.downcase
      result["current_state_raw"] = state
      result["current_state"] = if state == "No records found"
        "not-yet-started"
      elsif state == "Good"
        "good"
      elsif state == "Bad"
        "bad"
      elsif normalized.match?(/\A(insert|update|delete|truncate|copy|delta_check|begin txn|counting)\b/)
        "applying_changes"
      else
        "unknown"
      end
    when /^Onetimecopy\s+:\s+(.+)/
      copy_raw = $1.strip
      result["initial_copy_phase_raw"] = copy_raw
      # "Yes" => copy still running; anything else (incl. "No") => finished.
      result["initial_copy_phase"] = copy_raw.match?(/\AYes\b/i) ? "in-progress" : "finished"
    when /^Rows deleted\/inserted\s+:\s+([\d,]+)\s+\/\s+([\d,]+)/
      deleted = $1.to_s.delete(",").to_i
      inserted = $2.to_s.delete(",").to_i
      result["rows_deleted_last_sync"] = deleted
      result["rows_inserted_last_sync"] = inserted
      result["rows_changed_last_sync"] = deleted + inserted
    when /^Last good\s+:\s+(.+)/
      result["last_good_sync"] = $1.strip
    when /^Last error\s*:\s*(.*)$/

      error = $1.to_s.strip.sub(/\A:+\s*/, "").strip
      result["last_error"] = error unless error.empty?
    when /^Tables in sync\s+:\s+(\d+)/
      result["tables_in_sync"] = $1.to_i
    end
  end

  # No Onetimecopy line (some builds drop it when done): a sync with a real
  # current state has finished its initial copy.
  if result["initial_copy_phase"].nil?
    result["initial_copy_phase"] =
      if result["current_state"] && result["current_state"] != "not-yet-started"
        "finished"
      else
        "unknown"
      end
  end

  result
rescue StandardError => e
  { "error" => e.message }
end

def read_copy_progress_file
  return nil unless File.exist?(COPY_PROGRESS_FILE)
  JSON.parse(File.read(COPY_PROGRESS_FILE))
rescue JSON::ParserError
  nil
end

def write_copy_progress_file(data)
  File.write(COPY_PROGRESS_FILE, JSON.generate(data))
rescue StandardError => e
  $stderr.puts "Failed to write copy progress file: #{e.message}"
end

def parse_time_safe(value)
  return nil if value.nil? || value.to_s.strip.empty?
  Time.parse(value.to_s)
rescue StandardError
  nil
end

def normalize_table_name(value)
  return nil if value.nil?
  table = value.to_s.strip
  table = table.gsub(/\A"+|"+\z/, "")
  table = table.gsub(/\Apublic\./i, "")
  table.empty? ? nil : table
end

# SQL predicate for the relations this migrator actually replicates.
# Keep in sync with the NOT_REPLICATABLE query in scripts/mk-bucardo-repl.sh,
# which is its complement.
MIGRATED_SCHEMA_SCOPE_SQL = <<~SQL.freeze
  n.nspname NOT IN ('pg_catalog', 'information_schema', 'bucardo', '_ps_migrator', 'pscale_extensions')
  AND left(n.nspname, 3) <> 'pg_'
  AND n.nspname NOT IN (
    SELECT en.nspname FROM pg_extension e
    JOIN pg_namespace en ON en.oid = e.extnamespace
    WHERE en.nspname NOT IN ('public', 'pg_catalog')
  )
SQL

MIGRATED_RELATION_SCOPE_SQL = <<~SQL.freeze
  #{MIGRATED_SCHEMA_SCOPE_SQL}
  AND NOT EXISTS (
    SELECT 1 FROM pg_depend d
    WHERE d.classid = 'pg_class'::regclass
      AND d.objid = c.oid AND d.deptype = 'e'
  )
SQL

def relation_privilege_cmd(statement, username)
  gen = "SELECT format('#{statement}', n.nspname, c.relname, '#{username}') " \
        "FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace " \
        "WHERE #{MIGRATED_RELATION_SCOPE_SQL.gsub("\n", " ")} " \
        "AND c.relkind IN ('r', 'p') ORDER BY n.nspname, c.relname;"
  "psql \"#{HEROKU_URL}\" -A -t -c \"#{gen}\" | psql \"#{HEROKU_URL}\" -v ON_ERROR_STOP=1 -1"
end

def partman_template_exclusion_sql
  return "" unless HEROKU_URL
  pm = `psql "#{HEROKU_URL}" -A -t -c "SELECT quote_ident(n.nspname) FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = 'pg_partman';" 2>/dev/null`.strip
  return "" if pm.empty?
  " AND (n.nspname || '.' || c.relname) NOT IN " \
  "(SELECT template_table FROM #{pm}.part_config WHERE template_table IS NOT NULL)"
rescue StandardError
  ""
end

def list_public_tables
  return [] unless HEROKU_URL
  output = `psql "#{HEROKU_URL}" -A -t -c "SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename;" 2>/dev/null`.strip
  return [] if output.empty?
  output.split("\n").map { |t| normalize_table_name(t) }.compact.uniq
rescue StandardError
  []
end

# Returns migrated tables that have no primary key and no unique index.
# Bucardo needs at least one to reliably identify rows during replication.
def check_tables_without_pk_or_unique
  return [] unless HEROKU_URL

  query = "SELECT n.nspname || '.' || c.relname FROM pg_class c " \
          "JOIN pg_namespace n ON n.oid = c.relnamespace " \
          "WHERE #{MIGRATED_RELATION_SCOPE_SQL.gsub("\n", " ")} AND c.relkind = 'r' " \
          "#{partman_template_exclusion_sql} " \
          "AND NOT EXISTS (" \
          "  SELECT 1 FROM pg_index i " \
          "  WHERE i.indrelid = c.oid " \
          "  AND (i.indisprimary OR i.indisunique)" \
          ") ORDER BY n.nspname, c.relname;"
  output = `psql "#{HEROKU_URL}" -A -t -c "#{query}" 2>/dev/null`.strip
  return [] if output.empty?
  output.split("\n").map { |t| normalize_table_name(t) }.compact.uniq
rescue StandardError
  []
end

# Returns tables that contain at least one generated column,
# along with the names of those columns. Bucardo 5.6 cannot include generated
# columns in COPY, so the migrator's setup script registers customcols overrides
# for them automatically. 
def check_tables_with_generated_columns
  return [] unless HEROKU_URL

  query = "SELECT n.nspname, c.relname, a.attname " \
          "FROM pg_attribute a " \
          "JOIN pg_class c ON c.oid = a.attrelid " \
          "JOIN pg_namespace n ON n.oid = c.relnamespace " \
          "WHERE n.nspname <> 'information_schema' " \
          "  AND n.nspname <> 'bucardo' " \
          "  AND left(n.nspname, 3) <> 'pg_' " \
          "  AND c.relkind = 'r' " \
          "  AND a.attnum > 0 AND NOT a.attisdropped " \
          "  AND a.attgenerated <> '' " \
          "ORDER BY n.nspname, c.relname, a.attnum;"
  output = `psql "#{HEROKU_URL}" -A -t -F"|" -c "#{query}" 2>/dev/null`.strip
  return [] if output.empty?

  by_table = {}
  output.split("\n").each do |line|
    parts = line.strip.split("|")
    next unless parts.length == 3
    schema = parts[0].to_s.strip
    table = parts[1].to_s.strip
    column = parts[2].to_s.strip
    next if schema.empty? || table.empty? || column.empty?
    # Schema-qualify non-public tables so a table name that exists in more than
    # one schema does not collide into a single entry.
    display = schema == "public" ? table : "#{schema}.#{table}"
    (by_table[display] ||= []) << column
  end

  by_table.map { |table, columns| { "table" => table, "columns" => columns.uniq } }
rescue StandardError
  []
end

def capture_table_size_estimates
  return nil unless HEROKU_URL

  query = "SELECT c.relname, pg_total_relation_size(c.oid)::bigint FROM pg_class c " \
          "JOIN pg_namespace n ON n.oid = c.relnamespace " \
          "WHERE n.nspname = 'public' AND c.relkind = 'r' ORDER BY c.relname;"
  output = `psql "#{HEROKU_URL}" -A -t -c "#{query}" 2>/dev/null`.strip
  return nil if output.empty?

  sizes = {}
  output.split("\n").each do |line|
    parts = line.strip.split("|")
    next unless parts.length == 2
    table = normalize_table_name(parts[0])
    next unless table
    sizes[table] = parts[1].to_i
  end
  return nil if sizes.empty?

  {
    "captured_at" => Time.now.utc.iso8601,
    "table_sizes" => sizes,
    "total_tables" => sizes.length,
    "total_bytes" => sizes.values.reduce(0, :+),
    "completed_tables" => [],
    "history" => [],
    "last_progress_at" => Time.now.utc.iso8601,
  }
rescue StandardError
  nil
end

def get_table_size_estimates(db_url)
  return {} unless db_url
  query = "SELECT c.relname, pg_total_relation_size(c.oid)::bigint FROM pg_class c " \
          "JOIN pg_namespace n ON n.oid = c.relnamespace " \
          "WHERE n.nspname = 'public' AND c.relkind = 'r' ORDER BY c.relname;"
  output = `psql "#{db_url}" -A -t -c "#{query}" 2>/dev/null`.strip
  return {} if output.empty?

  sizes = {}
  output.split("\n").each do |line|
    parts = line.strip.split("|")
    next unless parts.length == 2
    table = normalize_table_name(parts[0])
    next unless table
    sizes[table] = parts[1].to_i
  end
  sizes
rescue StandardError
  {}
end

def tail_bucardo_log(lines = 300)
  return "" unless File.exist?(BUCARDO_LOG_FILE)
  `tail -#{lines} "#{BUCARDO_LOG_FILE}" 2>/dev/null`
rescue StandardError
  ""
end

def extract_tables_from_text(text, patterns, known_tables)
  return [] unless text && !text.empty?
  found = []
  patterns.each do |pattern|
    text.scan(pattern) do |match|
      table_raw = match.is_a?(Array) ? match[0] : match
      table = normalize_table_name(table_raw)
      next unless table
      next if known_tables.any? && !known_tables.include?(table)
      found << table
    end
  end
  found.uniq
end

def extract_current_table(log_text, known_tables)
  return nil if log_text.nil? || log_text.empty?
  patterns = [
    /copy(?:ing)?\s+table\s+("?[\w.]+")/i,
    /table\s+("?[\w.]+")\s+copy\s+started/i,
    /onetimecopy.*\b("?[\w.]+")\b/i,
  ]
  table = extract_tables_from_text(log_text, patterns, known_tables).last
  return table if table

  # Fallback: derive from Bucardo status raw lines that mention a table name.
  raw_table = log_text.lines.reverse.find { |line| line =~ /\btable\b/i && line =~ /\bcopy\b/i }
  return nil unless raw_table
  extract_tables_from_text(raw_table, [/"?([\w.]+)"?/], known_tables).last
end

def extract_completed_tables(log_text, known_tables)
  patterns = [
    /(?:finished|completed|done with|copied)\s+table\s+("?[\w.]+")/i,
    /table\s+("?[\w.]+")\s+(?:done|finished|completed)/i,
  ]
  extract_tables_from_text(log_text, patterns, known_tables)
end

def compute_backlog_trend(history)
  points = Array(history).last(6).map { |h| h["rows_changed_last_sync"] }.select { |v| v.is_a?(Numeric) }
  return "unknown" if points.length < 3
  deltas = points.each_cons(2).map { |a, b| b - a }
  return "growing" if deltas.all? { |d| d >= 0 } && deltas.any? { |d| d > 0 }
  return "shrinking" if deltas.all? { |d| d <= 0 } && deltas.any? { |d| d < 0 }
  "stable"
end

def compute_throughput_and_eta(history, total_bytes, copied_bytes)
  return nil unless total_bytes.to_i > 0 && copied_bytes.to_i >= 0
  points = Array(history).last(20).select { |h| h["copied_bytes"].is_a?(Numeric) && parse_time_safe(h["ts"]) }
  return nil if points.length < 2

  first = points.first
  last = points.last
  bytes_delta = last["copied_bytes"].to_i - first["copied_bytes"].to_i
  seconds_delta = parse_time_safe(last["ts"]).to_i - parse_time_safe(first["ts"]).to_i
  return nil if bytes_delta <= 0 || seconds_delta <= 0

  bytes_per_min = (bytes_delta.to_f / seconds_delta) * 60.0
  return nil if bytes_per_min <= 0

  remaining = [total_bytes.to_i - copied_bytes.to_i, 0].max
  eta_minutes = remaining / bytes_per_min
  {
    "bytes_per_min" => bytes_per_min.round,
    "mb_per_min" => (bytes_per_min / 1024.0 / 1024.0).round(2),
    "eta_min_minutes" => (eta_minutes * 0.7).round,
    "eta_max_minutes" => (eta_minutes * 1.3).round,
  }
end

def build_event_checklist(phase:, copy_phase:, readiness:, lag_health:)
  replication_healthy = lag_health["health_state"] == "healthy"

  steps = [
    { "id" => "schema_copied", "label" => "Schema copied", "status" => ["ready_to_copy", "copying", "replicating", "switched", "cleaning_up", "completed"].include?(phase) ? "complete" : "pending" },
    { "id" => "replication_configured", "label" => "Replication configured", "status" => ["ready_to_copy", "copying", "replicating", "switched", "cleaning_up", "completed"].include?(phase) ? "complete" : "pending" },
    { "id" => "initial_copy_running", "label" => "Initial copy running", "status" => copy_phase == "in-progress" ? "current" : (["replicating", "switched", "cleaning_up", "completed"].include?(phase) ? "complete" : "pending") },
    { "id" => "initial_copy_complete", "label" => "Initial copy complete", "status" => (copy_phase == "finished" || ["rebuilding_indexes", "index_rebuild_failed", "replicating", "switched", "cleaning_up", "completed"].include?(phase)) ? "complete" : "pending" },
    { "id" => "indexes_rebuilt", "label" => INDEX_DEFERRAL_DISABLED ? "Indexes in place" : "Indexes rebuilt", "status" => phase == "rebuilding_indexes" ? "current" : (phase == "index_rebuild_failed" ? "current" : (["replicating", "switched", "cleaning_up", "completed"].include?(phase) ? "complete" : "pending")) },
    { "id" => "replication_healthy", "label" => "Replication healthy", "status" => replication_healthy ? "complete" : (["replicating", "switched", "cleaning_up", "completed"].include?(phase) ? "current" : "pending") },
  ]

  {
    "steps" => steps,
    "completed" => steps.count { |s| s["status"] == "complete" },
    "total" => steps.length,
  }
end

def build_progress_signals(phase:, bucardo_status:, readiness:)
  state = read_copy_progress_file || {}
  if state["table_sizes"].nil? || state["table_sizes"].empty?
    captured = capture_table_size_estimates
    state = captured if captured
  end

  table_sizes = state["table_sizes"].is_a?(Hash) ? state["table_sizes"] : {}
  known_tables = table_sizes.keys
  if known_tables.empty?
    known_tables = list_public_tables
    state["table_sizes"] ||= {}
    known_tables.each { |t| state["table_sizes"][t] ||= 0 }
  end

  total_tables = state["total_tables"].to_i
  total_tables = known_tables.length if total_tables <= 0

  log_tail = tail_bucardo_log(500)
  detected_completed = extract_completed_tables(log_tail, known_tables)
  persisted_completed = Array(state["completed_tables"]).map { |t| normalize_table_name(t) }.compact
  completed_tables = (persisted_completed + detected_completed).uniq
  current_table = extract_current_table(log_tail, known_tables)
  tables_in_sync = bucardo_status.is_a?(Hash) ? bucardo_status["tables_in_sync"].to_i : 0
  copy_phase = bucardo_status.is_a?(Hash) ? bucardo_status["initial_copy_phase"] : "unknown"
  tables_completed = completed_tables.length
  # Bucardo "tables in sync" may include sequences and can overcount vs copy tables.
  # Only trust it when it is within the known table count.
  if tables_in_sync > 0 && total_tables > 0 && tables_in_sync <= total_tables
    tables_completed = [tables_completed, tables_in_sync].max
  end
  tables_completed = total_tables if copy_phase == "finished" && total_tables > 0
  tables_completed = [tables_completed, total_tables].min if total_tables > 0

  total_bytes = state["total_bytes"].to_i
  total_bytes = state["table_sizes"].values.reduce(0, :+) if total_bytes <= 0 && state["table_sizes"].is_a?(Hash)
  copied_bytes = completed_tables.reduce(0) { |sum, t| sum + state["table_sizes"].fetch(t, 0).to_i }
  byte_estimate_mode = "completed_tables"
  if copy_phase == "in-progress" && total_bytes > 0
    # Estimate partial progress by reading target relation sizes and clamping each
    # table at the source captured size. This provides non-zero movement before a
    # full table is marked complete.
    target_sizes = get_table_size_estimates(PLANETSCALE_URL)
    if target_sizes.any?
      estimated_copied = 0
      state["table_sizes"].each do |table, source_size|
        src = source_size.to_i
        dst = target_sizes[table].to_i
        next if src <= 0
        estimated_copied += [dst, src].min
      end
      if estimated_copied > copied_bytes
        copied_bytes = estimated_copied
        byte_estimate_mode = "target_size_estimate"
      end
    end
  end
  if copied_bytes <= 0 && total_bytes > 0 && total_tables > 0 && tables_completed > 0
    copied_bytes = ((tables_completed.to_f / total_tables) * total_bytes).round
    byte_estimate_mode = "table_ratio_estimate"
  end
  # Live relation sizes can move up/down during copy due to storage internals.
  # Keep progress monotonic so operators do not see regressions in UI.
  previous_max_copied = state["max_copied_bytes_seen"].to_i
  if copy_phase == "in-progress" && copied_bytes < previous_max_copied
    copied_bytes = previous_max_copied
    byte_estimate_mode = "target_size_estimate_monotonic" if byte_estimate_mode == "target_size_estimate"
  end
  state["max_copied_bytes_seen"] = [previous_max_copied, copied_bytes].max
  byte_percent = total_bytes > 0 ? ((copied_bytes.to_f / total_bytes) * 100.0).round(1) : 0.0

  now = Time.now.utc
  last_good = bucardo_status.is_a?(Hash) ? parse_time_safe(bucardo_status["last_good_sync"]) : nil
  last_good_age = last_good ? (now - last_good).to_i : nil

  state["history"] ||= []
  history = state["history"]
  rows_changed = bucardo_status.is_a?(Hash) ? bucardo_status["rows_changed_last_sync"] : nil
  history << {
    "ts" => now.iso8601,
    "tables_completed" => tables_completed,
    "copied_bytes" => copied_bytes,
    "rows_changed_last_sync" => rows_changed,
    "last_good_sync" => bucardo_status.is_a?(Hash) ? bucardo_status["last_good_sync"] : nil,
  }
  state["history"] = history.last(240)

  previous = state["history"][-2]
  progress_advanced = false
  if previous
    progress_advanced ||= tables_completed > previous["tables_completed"].to_i
    progress_advanced ||= copied_bytes > previous["copied_bytes"].to_i
    prev_good = previous["last_good_sync"]
    progress_advanced ||= prev_good != (bucardo_status.is_a?(Hash) ? bucardo_status["last_good_sync"] : nil)
  end
  state["last_progress_at"] = now.iso8601 if progress_advanced || state["last_progress_at"].nil?

  backlog_trend = compute_backlog_trend(state["history"])
  health_state = if bucardo_status.nil?
    "blocked"
  elsif bucardo_healthy_for_replication?(bucardo_status) && last_good_age && last_good_age <= 120
    "healthy"
  elsif bucardo_healthy_for_replication?(bucardo_status)
    "degraded"
  else
    "blocked"
  end

  blocker_reason = nil
  if readiness.is_a?(Hash) && readiness["hard_blockers"].is_a?(Array) && !readiness["hard_blockers"].empty?
    blocker_reason = readiness["hard_blockers"].first
  elsif health_state == "blocked"
    blocker_reason = "replication_not_healthy"
  end

  throughput = compute_throughput_and_eta(state["history"], total_bytes, copied_bytes)
  last_progress_at = parse_time_safe(state["last_progress_at"])
  no_progress_minutes = last_progress_at ? ((now - last_progress_at) / 60.0).round(1) : 0
  stall_warning = {
    "stalled" => ["copying", "replicating"].include?(phase) && no_progress_minutes >= 10,
    "no_progress_minutes" => no_progress_minutes,
    "message" => "No measurable progress for #{no_progress_minutes} minute(s). Check Bucardo logs, Bucardo status, and source DB load.",
    "next_steps" => [
      "Open Live Logs and inspect recent Bucardo output",
      "Confirm Bucardo status is Active and current state is good",
      "Check Heroku Postgres load and lock contention",
    ],
  }

  checklist = build_event_checklist(
    phase: phase,
    copy_phase: copy_phase,
    readiness: readiness || {},
    lag_health: { "health_state" => health_state },
  )

  state["completed_tables"] = completed_tables
  state["total_tables"] = total_tables
  state["total_bytes"] = total_bytes
  write_copy_progress_file(state)

  {
    "table_phase" => {
      "phase" => copy_phase,
      "current_table" => current_table,
      "tables_completed" => tables_completed,
      "total_tables" => total_tables,
    },
    "byte_weighted" => {
      "copied_bytes" => copied_bytes,
      "total_bytes" => total_bytes,
      "percent" => byte_percent,
      "estimate_mode" => byte_estimate_mode,
    },
    "replication_delay" => {
      "last_good_sync" => bucardo_status.is_a?(Hash) ? bucardo_status["last_good_sync"] : nil,
      "seconds_since_last_good" => last_good_age,
      "backlog_trend" => backlog_trend,
      "health_state" => health_state,
      "blocker_reason" => blocker_reason,
    },
    "throughput_eta" => throughput,
    "event_checklist" => checklist,
    "stall_detection" => stall_warning,
  }
end

def recent_good_sync?(bucardo_status, max_age_seconds = 120)
  last_good = parse_time_safe(bucardo_status["last_good_sync"])
  last_good && (Time.now.utc - last_good).to_i <= max_age_seconds
end

def bucardo_healthy_for_replication?(bucardo_status)
  return false unless bucardo_status.is_a?(Hash)

  current_state = bucardo_status["current_state"]
  known_healthy = ["good", "applying_changes"].include?(current_state)

  # If the state is unrecognized but syncs are completing, trust the evidence.
  return false unless known_healthy || recent_good_sync?(bucardo_status)

  last_error = bucardo_status["last_error"]&.to_s&.strip
  if last_error && !last_error.empty?
    return false unless recent_good_sync?(bucardo_status)
  end

  true
end

def build_cutover_readiness(phase:, bucardo_status:)
  unless ["copying", "replicating", "switched"].include?(phase)
    return {
      "level" => "not_ready",
      "can_force" => false,
      "message" => "Cutover is only available once replication is running.",
      "hard_blockers" => [],
      "soft_blockers" => [],
    }
  end

  hard_blockers = []
  soft_blockers = []

  if phase == "replicating" || phase == "copying"
    if bucardo_status.nil?
      hard_blockers << "bucardo_status_unavailable"
    else
      copy_phase = bucardo_status["initial_copy_phase"]
      if copy_phase != "finished"
        hard_blockers << "initial_copy_not_finished"
      end

      soft_blockers << "replication_not_healthy" unless bucardo_healthy_for_replication?(bucardo_status)
    end
  end

  if hard_blockers.any?
    {
      "level" => "blocked",
      "can_force" => false,
      "message" => "Cutover is blocked until safety checks pass.",
      "hard_blockers" => hard_blockers,
      "soft_blockers" => soft_blockers,
    }
  elsif soft_blockers.any?
    {
      "level" => "warning",
      "can_force" => true,
      "message" => "Cutover has warnings. You can override if replication appears healthy.",
      "hard_blockers" => hard_blockers,
      "soft_blockers" => soft_blockers,
    }
  else
    {
      "level" => "ready",
      "can_force" => true,
      "message" => "Cutover readiness checks passed.",
      "hard_blockers" => hard_blockers,
      "soft_blockers" => soft_blockers,
    }
  end
end

# ---------------------------------------------------------------------------
# HTML Dashboard (loaded from dashboard.html at startup)
# ---------------------------------------------------------------------------
DASHBOARD_HTML = File.read(File.join(__dir__, "dashboard.html"))

def render_dashboard
  DASHBOARD_HTML
end

def sync_exists?
  system("bucardo status planetscale_import > /dev/null 2>&1")
end

def ensure_sync_for_copy_start
  # After dyno restart, Bucardo can take a few seconds to expose sync state.
  # Give it a short grace window before attempting a rebuild.
  6.times do
    return true if sync_exists?
    sleep 2
  end

  # Rebuild sync metadata without copying schema again.
  output = `sh #{SCRIPTS_DIR}/mk-bucardo-repl.sh --primary "#{HEROKU_URL}" --replica "#{PLANETSCALE_URL}" --skip-schema 2>&1`
  File.write(SETUP_LOG_FILE, output)
  return true if $?.success?

  raise "Failed to rebuild missing Bucardo sync: #{output.split("\n").last(8).join(" ")}"
end

# Runs rm-bucardo-repl.sh to deregister the Heroku/PlanetScale databases from
# Bucardo's catalog and remove replication triggers. 
def run_bucardo_teardown
  output = `sh #{SCRIPTS_DIR}/rm-bucardo-repl.sh --primary "#{HEROKU_URL}" --replica "#{PLANETSCALE_URL}" 2>&1`
  [$?.success?, output]
end

# ---------------------------------------------------------------------------
# Deferred index rebuild orchestrator
#
# After the initial copy completes, delta apply is paused and the indexes that
# were dropped before the copy (recorded in _ps_migrator.dropped_indexes) are
# rebuilt in parallel. Pass 1 = secondary indexes + unique constraints; pass 2 =
# dependent foreign keys (recreated only after their uniques exist again). One
# failure never aborts the run; failures are surfaced only at the very end.
# ---------------------------------------------------------------------------
$index_rebuild_mutex = Mutex.new
$index_rebuild_running = false

# Verification run state (drives the dashboard "Run verification" modal).
$verify_mutex = Mutex.new
$verify_running = false
$verify_exit = nil

def sql_escape(value)
  value.to_s.gsub("'", "''")
end

def log_rebuild(message)
  line = "[#{Time.now.utc.iso8601}] #{message}"
  $stderr.puts "index-rebuild: #{message}"
  File.open(current_rebuild_log, "a") { |f| f.puts(line) }
rescue StandardError
  nil
end

# Returns aggregate counts from the rebuild registry, or nil if the registry does
# not exist (deferral disabled, or no indexes were dropped).
def index_rebuild_stats
  return nil unless PLANETSCALE_URL
  row = ps_migrate_query(
    "SELECT " \
    "count(*) FILTER (WHERE status='pending'), " \
    "count(*) FILTER (WHERE status='building'), " \
    "count(*) FILTER (WHERE status='done'), " \
    "count(*) FILTER (WHERE status='failed'), " \
    "count(*) FILTER (WHERE status='skipped'), " \
    "count(*) " \
    "FROM _ps_migrator.dropped_indexes"
  )
  return nil if row.nil? || row.empty?
  p = row.split("|", -1)
  return nil if p.length < 6
  pending, building, done, failed, skipped, total = p.map(&:to_i)
  {
    "pending" => pending, "building" => building, "done" => done,
    "failed" => failed, "skipped" => skipped, "total" => total,
    # Rebuildable = everything we actually intend to (re)create (excludes skipped).
    "rebuildable" => total - skipped,
  }
rescue StandardError
  nil
end

# Full status block for /status, including currently-building and failed objects.
def index_rebuild_detail
  stats = index_rebuild_stats
  return nil unless stats

  building = ps_migrate_query(
    "SELECT string_agg(tablename || '.' || objectname, '|' ORDER BY size_bytes DESC NULLS LAST) " \
    "FROM _ps_migrator.dropped_indexes WHERE status='building'"
  ).to_s.split("|").reject(&:empty?)

  failed_raw = `psql "#{PLANETSCALE_URL}" -A -t -F'\x1f' -c "SELECT tablename, objectname, replace(replace(coalesce(error,''), chr(10), ' '), chr(13), ' ') FROM _ps_migrator.dropped_indexes WHERE status='failed' ORDER BY tablename, objectname" 2>/dev/null`
  failed = failed_raw.each_line.map do |line|
    cols = line.chomp.split("\x1f", -1)
    next nil if cols.length < 3
    { "table" => cols[0], "name" => cols[1], "error" => cols[2].slice(0, 400) }
  end.compact

  stats.merge(
    "running" => $index_rebuild_running,
    "current" => building,
    "failed_objects" => failed,
  )
rescue StandardError
  nil
end

# True if there is real rebuild work recorded. Note: this intentionally does NOT
# consult DISABLE_INDEX_DEFERRAL -- that flag governs whether indexes get DROPPED
# (in drop-secondary-indexes.sh). If a registry with unfinished work exists, those
# indexes were already dropped and MUST be rebuilt regardless of the flag.
def index_rebuild_pending?
  stats = index_rebuild_stats
  return false unless stats
  stats["rebuildable"] > 0 && (stats["pending"] + stats["building"] + stats["failed"]) > 0
end

# Atomically claim the next index for a pass. Returns its id, or nil if none left.
# Claims ONLY 'pending' rows: a row that fails becomes 'failed' (terminal for this
# run) and must NOT be re-claimed, otherwise a permanently-failing index would be
# retried forever and the pass would never drain. /retry-indexes resets 'failed'
# back to 'pending' to re-attempt them as a fresh run.
def claim_next_index(pass)
  out = ps_migrate_query(
    "WITH c AS (" \
    "  SELECT id FROM _ps_migrator.dropped_indexes " \
    "  WHERE pass=#{pass} AND status = 'pending' " \
    "  ORDER BY size_bytes DESC NULLS LAST, id " \
    "  FOR UPDATE SKIP LOCKED LIMIT 1" \
    ") UPDATE _ps_migrator.dropped_indexes d SET status='building', started_at=now() " \
    "FROM c WHERE d.id = c.id RETURNING d.id"
  )
  id = out.to_s.each_line.map(&:strip).find { |l| l.match?(/\A\d+\z/) }
  id && id.to_i
end

def recreate_partman_config
  out = `sh #{SCRIPTS_DIR}/recreate-partman-config.sh --primary "#{HEROKU_URL}" --replica "#{PLANETSCALE_URL}" 2>&1`
  out.to_s.each_line { |l| log_rebuild("partman: #{l.rstrip}") unless l.strip.empty? }
  out
rescue StandardError => e
  log_rebuild("partman: #{e.class}: #{e.message}")
  ""
end

def rebuilt_object_present?(schema, name)
  out = `psql "#{PLANETSCALE_URL}" -A -t -c "SELECT 1 WHERE EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relname = '#{sql_escape(name)}' AND n.nspname = '#{sql_escape(schema)}') OR EXISTS (SELECT 1 FROM pg_constraint con JOIN pg_namespace n ON n.oid = con.connamespace WHERE con.conname = '#{sql_escape(name)}' AND n.nspname = '#{sql_escape(schema)}')" 2>/dev/null`.strip
  out == "1"
rescue StandardError
  false
end

def rebuild_one_index(id)
  meta_raw = `psql "#{PLANETSCALE_URL}" -A -t -F'\x1f' -c "SELECT schemaname, tablename, objectname, kind, coalesce(pg_size_pretty(size_bytes), '?') FROM _ps_migrator.dropped_indexes WHERE id=#{id}" 2>/dev/null`
  schema, table, name, kind, size = meta_raw.chomp.split("\x1f", -1)
  rebuild_sql = `psql "#{PLANETSCALE_URL}" -A -t -c "SELECT rebuild_sql FROM _ps_migrator.dropped_indexes WHERE id=#{id}" 2>/dev/null`.strip

  if rebuilt_object_present?(schema, name)
    ps_migrate_query("UPDATE _ps_migrator.dropped_indexes SET status='done', finished_at=now(), error=NULL WHERE id=#{id}")
    log_rebuild("SKIP   #{table}.#{name}: already present on the target")
    return
  end

  if rebuild_sql.empty?
    ps_migrate_query("UPDATE _ps_migrator.dropped_indexes SET status='failed', finished_at=now(), error='rebuild_sql was empty' WHERE id=#{id}")
    log_rebuild("FAILED #{table}.#{name}: rebuild_sql empty")
    return
  end

  started = Time.now
  log_rebuild("BUILD  #{schema}.#{name} on #{table} (#{kind}, #{size}) starting")

  script = +"SET statement_timeout = 0;\n"
  script << "DO $$ BEGIN PERFORM set_config('transaction_timeout','0',false); " \
            "EXCEPTION WHEN undefined_object THEN NULL; END $$;\n"
  script << "SET maintenance_work_mem = '#{MAINTENANCE_WORK_MEM}';\n"
  script << "SET max_parallel_maintenance_workers = #{PARALLEL_MAINTENANCE_WORKERS};\n"
  script << rebuild_sql
  script << ";\n"

  output = ""
  Tempfile.create(["ps_rebuild", ".sql"]) do |f|
    f.write(script)
    f.flush
    output = `psql "#{PLANETSCALE_URL}" -v ON_ERROR_STOP=1 -f "#{f.path}" 2>&1`
  end
  ok = $?.success?
  elapsed = (Time.now - started).round(1)

  if ok
    ps_migrate_query("UPDATE _ps_migrator.dropped_indexes SET status='done', finished_at=now(), error=NULL WHERE id=#{id}")
    st = index_rebuild_stats || {}
    log_rebuild("DONE   #{schema}.#{name} in #{elapsed}s  [#{st['done']}/#{st['rebuildable']} done, " \
                "#{st['building']} building, #{st['pending']} pending, #{st['failed']} failed]")
  else
    err = output.to_s.strip.split("\n").last(4).join(" ").slice(0, 480)
    ps_migrate_query("UPDATE _ps_migrator.dropped_indexes SET status='failed', finished_at=now(), error='#{sql_escape(err)}' WHERE id=#{id}")
    log_rebuild("FAILED #{schema}.#{name} on #{table} (#{kind}, #{size}) after #{elapsed}s")
    log_rebuild("       reason: #{err}")
    log_rebuild("       retry by hand with: #{rebuild_sql.gsub(/\s+/, ' ').slice(0, 400)}")
  end
rescue StandardError => e
  ps_migrate_query("UPDATE _ps_migrator.dropped_indexes SET status='failed', finished_at=now(), error='#{sql_escape(e.message)}' WHERE id=#{id}") rescue nil
  log_rebuild("FAILED id=#{id}: #{e.message}")
end

# Number of parallel index builds to use: a dashboard override (persisted in the
# state dir) wins over the INDEX_REBUILD_WORKERS env default, so it can be tuned
# per server without a redeploy.
def effective_rebuild_workers
  if File.exist?(REBUILD_WORKERS_FILE)
    n = File.read(REBUILD_WORKERS_FILE).to_i
    return n.clamp(1, REBUILD_WORKERS_MAX) if n > 0
  end
  INDEX_REBUILD_WORKERS
rescue StandardError
  INDEX_REBUILD_WORKERS
end

# Run all objects for a pass with `effective_rebuild_workers` parallel workers. The
# DB (FOR UPDATE SKIP LOCKED) is the work queue, so workers never collide.
def rebuild_pass(pass)
  workers = Array.new(effective_rebuild_workers) do
    Thread.new do
      loop do
        id = claim_next_index(pass)
        break unless id
        rebuild_one_index(id)
      end
    end
  end
  workers.each(&:join)
end

# Launch (or resume) the rebuild. 
def start_index_rebuild(started_at)
  $index_rebuild_mutex.synchronize do
    return if $index_rebuild_running
    $index_rebuild_running = true
  end

  Thread.new do
    begin
      log_rebuild("=== Index rebuild started (workers=#{effective_rebuild_workers}, maintenance_work_mem=#{MAINTENANCE_WORK_MEM}) ===")

      # Hold delta apply until every index is back in place.
      `bucardo pause planetscale_import 2>&1`

      File.write(STATUS_FILE, JSON.generate({
        phase: "rebuilding_indexes",
        state: "rebuilding",
        message: "Initial copy complete. Rebuilding indexes before replication resumes...",
        error: nil,
        started_at: started_at,
      }))
      write_persistent_state("rebuilding_indexes", started_at: started_at)

      # Recover orphaned claims: a row left 'building' means a worker was
      # interrupted (crash/restart) before finishing. Reset it to 'pending' so it
      # is re-attempted (and so the run can't mistake it for a success). Safe here
      # because the mutex guarantees no workers are running yet.
      ps_migrate_query("UPDATE _ps_migrator.dropped_indexes SET status='pending' WHERE status='building'")

      # Order by real (now-populated) target table sizes: biggest work first.
      ps_migrate_query(
        "UPDATE _ps_migrator.dropped_indexes d SET size_bytes = GREATEST(" \
        "pg_total_relation_size((quote_ident(d.schemaname) || '.' || quote_ident(d.tablename))::regclass), " \
        "(SELECT coalesce(sum(pg_total_relation_size(t.relid)), 0) " \
        " FROM pg_partition_tree((quote_ident(d.schemaname) || '.' || quote_ident(d.tablename))::regclass) t)) " \
        "WHERE status = 'pending'"
      )

      rebuild_pass(1)
      rebuild_pass(2)

      stats = index_rebuild_stats
      failed = stats ? stats["failed"] : 0

      if failed.to_i > 0
        log_rebuild("=== Index rebuild finished with #{failed} failure(s); holding for user ===")
        File.write(STATUS_FILE, JSON.generate({
          phase: "index_rebuild_failed",
          state: "rebuild_failed",
          message: "#{failed} index(es) failed to rebuild. Delta replication is paused. Fix and retry, or proceed anyway.",
          error: nil,
          started_at: started_at,
        }))
        write_persistent_state("index_rebuild_failed", started_at: started_at)
      else
        recreate_partman_config
        log_rebuild("=== Index rebuild complete; resuming delta apply ===")
        `bucardo resume planetscale_import 2>&1`
        `bucardo kick planetscale_import 0 2>&1`
        File.write(STATUS_FILE, JSON.generate({
          phase: "replicating",
          state: "running",
          message: "Indexes rebuilt. Real-time replication is active.",
          error: nil,
          started_at: started_at,
        }))
        write_persistent_state("replicating", started_at: started_at)
      end
    rescue StandardError => e
      log_rebuild("ERROR orchestrator: #{e.message}")
      File.write(STATUS_FILE, JSON.generate({
        phase: "index_rebuild_failed",
        state: "rebuild_error",
        message: "Index rebuild encountered an error. Delta replication is paused.",
        error: e.message.to_s.slice(0, 500),
        started_at: started_at,
      }))
      write_persistent_state("index_rebuild_failed", started_at: started_at, error: e.message.to_s.slice(0, 500))
    ensure
      $index_rebuild_mutex.synchronize { $index_rebuild_running = false }
    end
  end
end


# ---------------------------------------------------------------------------
# Server setup
# ---------------------------------------------------------------------------
server = WEBrick::HTTPServer.new(Port: PORT, Logger: WEBrick::Log.new($stderr, WEBrick::Log::INFO))

# GET /health (no auth)
server.mount_proc "/health" do |req, res|
  res.content_type = "application/json"
  res.body = JSON.generate({ ok: true, timestamp: Time.now.utc.iso8601 })
end

# GET /preflight-checks - automated pre-migration validation
server.mount_proc "/preflight-checks" do |req, res|
  require_auth(req, res)
  res.content_type = "application/json"

  tables = check_tables_without_pk_or_unique
  generated = check_tables_with_generated_columns
  res.body = JSON.generate({
    tables_without_pk_or_unique: tables,
    all_tables_valid: tables.empty?,
    tables_with_generated_columns: generated,
  })
end

# GET / (dashboard)
server.mount_proc "/" do |req, res|
  # Only handle exact root path; let other routes handle themselves
  if req.path == "/"
    require_auth(req, res)
    res.content_type = "text/html; charset=utf-8"
    res.body = render_dashboard
  end
end

# GET /status
# Serialises phase evaluation between GET /status and the phase watcher.
$phase_transition_mutex = Mutex.new
$last_status_eval_at = nil

# Phase transitions driven by Bucardo's own state:
#   ready_to_copy -> copying   when the copy is already running
#   copying        -> rebuilding_indexes / replicating once the copy is done
def apply_auto_transitions(combined, bucardo_status, persisted_phase)
  return combined unless bucardo_status

  copy_phase = bucardo_status["initial_copy_phase"]
  current_state = bucardo_status["current_state"]
  started_at = combined["started_at"]

  already_beyond_copy = ["replicating", "switched", "cleaning_up", "completed"].include?(combined["phase"]) ||
    ["replicating", "switched", "cleaning_up", "completed"].include?(persisted_phase)

  if ["starting", "configuring", "ready_to_copy"].include?(combined["phase"]) &&
     copy_phase == "in-progress" &&
     current_state != "not-yet-started" &&
     !already_beyond_copy
    File.write(STATUS_FILE, JSON.generate({
      phase: "copying",
      state: "initial_copy",
      message: "Copying all rows from Heroku to PlanetScale...",
      error: nil,
      started_at: started_at,
    }))
    combined["phase"] = "copying"
    combined["state"] = "initial_copy"
    combined["message"] = "Copying all rows from Heroku to PlanetScale..."
  end

  if combined["phase"] == "copying"
    if copy_phase == "finished" && bucardo_healthy_for_replication?(bucardo_status)
      if index_rebuild_pending?
        # Rebuild deferred indexes first; reflect the phase now so concurrent
        # /status polls don't retrigger the copy->replicate path.
        start_index_rebuild(started_at)
        combined["phase"] = "rebuilding_indexes"
        combined["state"] = "rebuilding"
        combined["message"] = "Initial copy complete. Rebuilding indexes before replication resumes..."
      else
        recreate_partman_config
        File.write(STATUS_FILE, JSON.generate({
          phase: "replicating",
          state: "running",
          message: "Initial copy complete. Real-time replication is active.",
          error: nil,
          started_at: started_at,
        }))
        write_persistent_state("replicating", started_at: started_at)
        combined["phase"] = "replicating"
        combined["state"] = "running"
        combined["message"] = "Initial copy complete. Real-time replication is active."
      end
    elsif copy_phase == "finished"
      combined["state"] = "copy_health_check_failed"
      combined["message"] = "Initial copy appears complete, but replication health checks are not passing yet."
    elsif copy_phase == "unknown"
      combined["state"] = "copy_status_ambiguous"
      combined["message"] = "Copy status is ambiguous after Bucardo restart/output change. Waiting for a clear copy completion signal."
    end
  end

  # Resume the rebuild orchestrator if a restart interrupted it mid-rebuild.
  if combined["phase"] == "rebuilding_indexes" && !$index_rebuild_running && index_rebuild_pending?
    start_index_rebuild(started_at)
  end

  combined
end

server.mount_proc "/status" do |req, res|
  require_auth(req, res)

  res.content_type = "application/json"

  base_status = read_status_file
  bucardo_status = get_bucardo_status
  persisted = read_persistent_state
  persisted_phase = persisted.is_a?(Hash) ? persisted["phase"] : nil

  combined = base_status.merge("bucardo" => bucardo_status, "timestamp" => Time.now.utc.iso8601)

  # Evaluated under a mutex so a /status poll and the phase watcher can never
  # transition concurrently and double-write the status file.
  $phase_transition_mutex.synchronize do
    $last_status_eval_at = Time.now
    apply_auto_transitions(combined, bucardo_status, persisted_phase)
  end

  # Attach rebuild progress whenever a registry exists (drives the dashboard).
  if ["copying", "rebuilding_indexes", "index_rebuild_failed", "replicating"].include?(combined["phase"])
    detail = index_rebuild_detail
    combined["index_rebuild"] = detail if detail
  end

  # Current index-rebuild parallelism config (drives the dashboard tuning control).
  combined["rebuild_config"] = {
    "workers" => effective_rebuild_workers,
    "workers_default" => INDEX_REBUILD_WORKERS,
    "overridden" => File.exist?(REBUILD_WORKERS_FILE),
    "parallel_maintenance_workers" => PARALLEL_MAINTENANCE_WORKERS,
    "maintenance_work_mem" => MAINTENANCE_WORK_MEM,
    "max_workers" => REBUILD_WORKERS_MAX,
    "deferral_disabled" => INDEX_DEFERRAL_DISABLED,
  }

  combined["cutover_readiness"] = build_cutover_readiness(
    phase: combined["phase"],
    bucardo_status: bucardo_status,
  )
  combined["progress_signals"] = build_progress_signals(
    phase: combined["phase"],
    bucardo_status: bucardo_status,
    readiness: combined["cutover_readiness"],
  )

  # Check for milestone transitions and send Slack notifications
  check_milestone_notifications(combined)

  res.body = JSON.generate(combined)
end

# POST /start-migration - begins the migration (schema copy + replication setup)
server.mount_proc "/start-migration" do |req, res|
  require_auth(req, res)

  unless req.request_method == "POST"
    res.status = 405
    res.content_type = "application/json"
    res.body = JSON.generate({ error: "Method not allowed" })
    next
  end

  res.content_type = "application/json"

  # Check if migration is already running or completed
  current = read_status_file
  unless current["phase"] == "waiting" || current["phase"] == "unknown"
    res.body = JSON.generate({ success: false, message: "Migration already in progress or completed (phase: #{current["phase"]})" })
    next
  end

  start_new_rebuild_log

  # Block if any tables lack a primary key or unique index
  bad_tables = check_tables_without_pk_or_unique
  unless bad_tables.empty?
    res.body = JSON.generate({
      success: false,
      message: "Cannot start migration: #{bad_tables.length} table(s) have no primary key or unique index. " \
               "Bucardo requires one to track rows. Add a primary key or unique index to: #{bad_tables.join(', ')}",
      tables_without_pk_or_unique: bad_tables,
    })
    next
  end

  started_at = Time.now.utc.iso8601
  FileUtils.rm_f(COPY_PROGRESS_FILE)
  # Start each migration from the configured default parallelism; the dashboard
  # control writes a fresh per-migration override at the ready_to_copy step.
  FileUtils.rm_f(REBUILD_WORKERS_FILE)

  # Update local status
  File.write(STATUS_FILE, JSON.generate({
    phase: "starting",
    state: "initializing",
    message: "Starting migration...",
    error: nil,
    started_at: started_at,
  }))

  # Persist to PlanetScale
  write_persistent_state("starting", started_at: started_at)

  # Run setup in a background thread
  Thread.new do
    begin
      # Update to configuring
      File.write(STATUS_FILE, JSON.generate({
        phase: "configuring",
        state: "copying_schema",
        message: "Copying schema from Heroku to PlanetScale and configuring Bucardo replication...",
        error: nil,
        started_at: started_at,
      }))
      write_persistent_state("configuring", started_at: started_at)

      # Run the replication setup script
      output = `sh #{SCRIPTS_DIR}/mk-bucardo-repl.sh --primary "#{HEROKU_URL}" --replica "#{PLANETSCALE_URL}" 2>&1`
      File.write(SETUP_LOG_FILE, output)
      success = $?.success?

      if success
        # Pause the sync so data copy doesn't start until the user is ready
        `bucardo pause planetscale_import 2>&1`

        File.write(STATUS_FILE, JSON.generate({
          phase: "ready_to_copy",
          state: "schema_copied",
          message: "Schema and replication configured. Ready to start data copy.",
          error: nil,
          started_at: started_at,
        }))
        write_persistent_state("ready_to_copy", started_at: started_at)
      else
        error_msg = output.split("\n").last(5).join(" ").slice(0, 500)
        File.write(STATUS_FILE, JSON.generate({
          phase: "error",
          state: "setup_failed",
          message: "Replication setup failed.",
          error: error_msg,
          started_at: started_at,
        }))
        write_persistent_state("error", started_at: started_at, error: error_msg)
      end
    rescue => e
      File.write(STATUS_FILE, JSON.generate({
        phase: "error",
        state: "setup_failed",
        message: "Replication setup failed with exception.",
        error: e.message,
        started_at: started_at,
      }))
      write_persistent_state("error", started_at: started_at, error: e.message)
    end
  end

  res.body = JSON.generate({ success: true, message: "Migration started." })
end

# POST /start-copy - kicks off the initial data copy (user must explicitly trigger this)
server.mount_proc "/start-copy" do |req, res|
  require_auth(req, res)

  unless req.request_method == "POST"
    res.status = 405
    res.content_type = "application/json"
    res.body = JSON.generate({ error: "Method not allowed" })
    next
  end

  res.content_type = "application/json"

  current = read_status_file
  unless current["phase"] == "ready_to_copy"
    res.body = JSON.generate({ success: false, message: "Not in ready_to_copy phase (current: #{current["phase"]})" })
    next
  end

  started_at = current["started_at"]
  copy_state = capture_table_size_estimates
  write_copy_progress_file(copy_state) if copy_state

  # Persist copy start immediately, then run potentially slow Bucardo commands
  # in the background so the request does not hit Heroku's 30s router timeout.
  File.write(STATUS_FILE, JSON.generate({
    phase: "copying",
    state: "initial_copy",
    message: "Copying all rows from Heroku to PlanetScale...",
    error: nil,
    started_at: started_at,
  }))
  write_persistent_state("copying", started_at: started_at)

  Thread.new do
    begin
      ensure_sync_for_copy_start
    rescue => e
      error_msg = e.message.to_s.slice(0, 500)
      File.write(STATUS_FILE, JSON.generate({
        phase: "error",
        state: "copy_start_failed",
        message: "Failed to start initial data copy.",
        error: error_msg,
        started_at: started_at,
      }))
      write_persistent_state("error", started_at: started_at, error: error_msg)
      next
    end

    resume_output = `bucardo resume planetscale_import 2>&1`
    resume_success = $?.success?
    kick_output = ""
    kick_success = false

    if resume_success
      kick_output = `bucardo kick planetscale_import 0 2>&1`
      kick_success = $?.success?
    end

    copy_started = resume_success && kick_success

    unless copy_started
      # Bucardo kick can return non-zero (e.g. "KILLED!") while copy still starts.
      # Confirm by checking live sync state before marking copy start as failed.
      sleep 1
      bucardo_status = get_bucardo_status
      copy_started = resume_success && (
        kick_output.include?("KILLED!") ||
        (bucardo_status.is_a?(Hash) && bucardo_status["initial_copy_phase"] == "in-progress")
      )
    end

    unless copy_started
      output = [resume_output, kick_output].join("\n").strip
      error_msg = output.split("\n").last(8).join(" ").slice(0, 500)
      File.write(STATUS_FILE, JSON.generate({
        phase: "error",
        state: "copy_start_failed",
        message: "Failed to start initial data copy.",
        error: error_msg,
        started_at: started_at,
      }))
      write_persistent_state("error", started_at: started_at, error: error_msg)
    end
  end

  res.body = JSON.generate({ success: true, message: "Data copy request accepted." })
end

# POST /pause-sync - pauses Bucardo replication (triggers still track changes)
server.mount_proc "/pause-sync" do |req, res|
  require_auth(req, res)

  unless req.request_method == "POST"
    res.status = 405
    res.content_type = "application/json"
    res.body = JSON.generate({ error: "Method not allowed" })
    next
  end

  res.content_type = "application/json"

  output = `bucardo pause planetscale_import 2>&1`
  success = $?.success?

  if success
    started_at = read_status_file["started_at"]
    File.write(STATUS_FILE, JSON.generate({
      phase: "replicating",
      state: "paused",
      message: "Replication is paused. Triggers are still active on Heroku -- every write still has trigger overhead. To fully remove triggers, use Abort Migration.",
      error: nil,
      started_at: started_at,
    }))
  end

  res.body = JSON.generate({ success: success, output: output.strip })
end

# POST /resume-sync - resumes Bucardo replication
server.mount_proc "/resume-sync" do |req, res|
  require_auth(req, res)

  unless req.request_method == "POST"
    res.status = 405
    res.content_type = "application/json"
    res.body = JSON.generate({ error: "Method not allowed" })
    next
  end

  res.content_type = "application/json"

  output = `bucardo resume planetscale_import 2>&1`
  success = $?.success?

  if success
    started_at = read_status_file["started_at"]
    File.write(STATUS_FILE, JSON.generate({
      phase: "replicating",
      state: "running",
      message: "Bucardo replication is active.",
      error: nil,
      started_at: started_at,
    }))
  end

  res.body = JSON.generate({ success: success, output: output.strip })
end

# POST /retry-indexes - re-run the rebuild over failed indexes only (after the
# user has fixed whatever caused them to fail). Only valid while held.
server.mount_proc "/retry-indexes" do |req, res|
  require_auth(req, res)

  unless req.request_method == "POST"
    res.status = 405
    res.content_type = "application/json"
    res.body = JSON.generate({ error: "Method not allowed" })
    next
  end

  res.content_type = "application/json"

  current = read_status_file
  unless current["phase"] == "index_rebuild_failed"
    res.status = 409
    res.body = JSON.generate({ success: false, error: "Retry is only available while index rebuild is held (current phase: #{current["phase"]})." })
    next
  end

  if $index_rebuild_running
    res.body = JSON.generate({ success: false, message: "A rebuild is already running." })
    next
  end

  # Reset failed rows back to pending so the orchestrator re-attempts them as a
  # fresh run (claim_next_index only picks 'pending')
  ps_migrate_query("UPDATE _ps_migrator.dropped_indexes SET status='pending', error=NULL WHERE status='failed'")
  start_index_rebuild(current["started_at"])
  res.body = JSON.generate({ success: true, message: "Retrying failed indexes." })
end

# POST /proceed-after-rebuild - knowingly continue to replication while some
# indexes remain failed (those tables will seq-scan during delta apply until the
# index is added manually).
server.mount_proc "/proceed-after-rebuild" do |req, res|
  require_auth(req, res)

  unless req.request_method == "POST"
    res.status = 405
    res.content_type = "application/json"
    res.body = JSON.generate({ error: "Method not allowed" })
    next
  end

  res.content_type = "application/json"

  current = read_status_file
  unless current["phase"] == "index_rebuild_failed"
    res.status = 409
    res.body = JSON.generate({ success: false, error: "Not in index_rebuild_failed phase (current: #{current["phase"]})." })
    next
  end

  started_at = current["started_at"]
  resume_output = `bucardo resume planetscale_import 2>&1`
  `bucardo kick planetscale_import 0 2>&1`

  File.write(STATUS_FILE, JSON.generate({
    phase: "replicating",
    state: "running",
    message: "Proceeding to replication with some indexes unbuilt. Real-time replication is active.",
    error: nil,
    started_at: started_at,
  }))
  write_persistent_state("replicating", started_at: started_at)

  res.body = JSON.generate({ success: true, message: "Resuming replication.", output: resume_output.strip })
end

# POST /set-rebuild-workers?n=N - set how many indexes are rebuilt in parallel.
# Persisted in the state dir; read by the orchestrator when a rebuild starts, so
# it can be tuned per server without a redeploy. Takes effect on the next rebuild
# (or the next batch of an ongoing one; already-running workers are not changed).
server.mount_proc "/set-rebuild-workers" do |req, res|
  require_auth(req, res)
  res.content_type = "application/json"

  unless req.request_method == "POST"
    res.status = 405
    res.body = JSON.generate({ error: "Method not allowed" })
    next
  end

  params = WEBrick::HTTPUtils.parse_query(req.query_string || "")
  n = (params["n"] || params["workers"]).to_i
  if n < 1 || n > REBUILD_WORKERS_MAX
    res.status = 400
    res.body = JSON.generate({ success: false, error: "Parallel jobs must be an integer between 1 and #{REBUILD_WORKERS_MAX}." })
    next
  end

  File.write(REBUILD_WORKERS_FILE, n.to_s)
  res.body = JSON.generate({
    success: true,
    workers: n,
    message: "Index rebuild parallelism set to #{n}. It applies to the next rebuild (and to new work in an in-progress one).",
  })
end

# /count-rows is intentionally disabled to avoid expensive full-table scans.
server.mount_proc "/count-rows" do |req, res|
  require_auth(req, res)
  res.status = 410
  res.content_type = "application/json"
  res.body = JSON.generate({
    success: false,
    error: "Row count checks are disabled for safety on large databases.",
    code: "row_counts_disabled",
  })
end

# GET /logs
server.mount_proc "/logs" do |req, res|
  require_auth(req, res)

  res.content_type = "application/json"
  lines = (req.query["lines"] || "100").to_i
  lines = [lines, 1000].min

  logs = {}

  if File.exist?(BUCARDO_LOG_FILE)
    logs["bucardo"] = `tail -#{lines} #{BUCARDO_LOG_FILE} 2>/dev/null`
  end

  if File.exist?(SETUP_LOG_FILE)
    logs["setup"] = File.read(SETUP_LOG_FILE) rescue "Unable to read setup log"
  end

  rebuild_log = current_rebuild_log
  if File.exist?(rebuild_log)
    logs["rebuild"] = `tail -#{lines} #{rebuild_log} 2>/dev/null`
    logs["rebuild_log_file"] = File.basename(rebuild_log)
  end

  res.body = JSON.generate(logs)
end

# POST /switch-traffic
server.mount_proc "/switch-traffic" do |req, res|
  require_auth(req, res)

  unless req.request_method == "POST"
    res.status = 405
    res.content_type = "application/json"
    res.body = JSON.generate({ error: "Method not allowed" })
    next
  end

  res.content_type = "application/json"

  current = read_status_file
  unless current["phase"] == "replicating"
    res.status = 409
    res.body = JSON.generate({ success: false, error: "Switch traffic is only allowed during replicating phase.", phase: current["phase"] })
    next
  end

  readiness = build_cutover_readiness(
    phase: current["phase"],
    bucardo_status: get_bucardo_status,
  )

  query_params = WEBrick::HTTPUtils.parse_query(req.query_string || "")
  force_override = %w[1 true yes].include?(query_params["force"]&.to_s&.downcase)
  if readiness["level"] == "blocked"
    res.status = 409
    res.body = JSON.generate({
      success: false,
      error: "Cutover is blocked by replication health checks.",
      code: "cutover_blocked",
      readiness: readiness,
    })
    next
  end

  if readiness["level"] == "warning" && !force_override
    res.status = 409
    res.body = JSON.generate({
      success: false,
      error: "Cutover requires explicit override due to incomplete verification warnings.",
      code: "cutover_override_required",
      readiness: readiness,
    })
    next
  end

  if HEROKU_URL.nil? || HEROKU_URL.empty?
    res.status = 500
    res.body = JSON.generate({ error: "HEROKU_URL not configured" })
    next
  end

  # Extract the Heroku username from the URL for the REVOKE command
  username = HEROKU_URL.split("/")[2]&.split(":")&.first
  if username.nil?
    res.status = 500
    res.body = JSON.generate({ error: "Could not parse username from HEROKU_URL" })
    next
  end

  cmd = relation_privilege_cmd(
    "REVOKE INSERT, UPDATE, DELETE ON %I.%I FROM %I;", username
  )
  output = `#{cmd} 2>&1`
  success = $?.success?

  if success
    switched_at = Time.now.utc.iso8601
    started_at = read_status_file["started_at"]
    File.write(STATUS_FILE, JSON.generate({
      phase: "switched",
      state: "writes_revoked",
      message: "Write access revoked on Heroku. Waiting for final replication to complete.",
      error: nil,
      started_at: started_at,
      switched_at: switched_at,
    }))
    write_persistent_state("switched", started_at: started_at, switched_at: switched_at)
  end

  res.body = JSON.generate({ success: success, output: filter_harmless_pg_warnings(output).strip })
end

# POST /revert-switch
server.mount_proc "/revert-switch" do |req, res|
  require_auth(req, res)

  unless req.request_method == "POST"
    res.status = 405
    res.content_type = "application/json"
    res.body = JSON.generate({ error: "Method not allowed" })
    next
  end

  res.content_type = "application/json"

  username = HEROKU_URL&.split("/")&.dig(2)&.split(":")&.first
  if username.nil?
    res.status = 500
    res.body = JSON.generate({ error: "Could not parse username from HEROKU_URL" })
    next
  end

  cmd = relation_privilege_cmd(
    "GRANT INSERT, UPDATE, DELETE ON %I.%I TO %I;", username
  )
  output = `#{cmd} 2>&1`
  success = $?.success?

  if success
    started_at = read_status_file["started_at"]
    File.write(STATUS_FILE, JSON.generate({
      phase: "replicating",
      state: "running",
      message: "Write access restored on Heroku. Replication continues.",
      error: nil,
      started_at: started_at,
    }))
    write_persistent_state("replicating", started_at: started_at)
  end

  res.body = JSON.generate({ success: success, output: filter_harmless_pg_warnings(output).strip })
end

# POST /cleanup
server.mount_proc "/cleanup" do |req, res|
  require_auth(req, res)

  unless req.request_method == "POST"
    res.status = 405
    res.content_type = "application/json"
    res.body = JSON.generate({ error: "Method not allowed" })
    next
  end

  res.content_type = "application/json"

  started_at = read_status_file["started_at"]

  File.write(STATUS_FILE, JSON.generate({
    phase: "cleaning_up",
    state: "removing_replication",
    message: "Removing Bucardo replication...",
    error: nil,
    started_at: started_at,
  }))
  write_persistent_state("cleaning_up", started_at: started_at)

  # Run cleanup in a thread so we can respond immediately
  Thread.new do
    success, output = run_bucardo_teardown
    completed_at = Time.now.utc.iso8601

    File.write(STATUS_FILE, JSON.generate({
      phase: success ? "completed" : "error",
      state: success ? "cleanup_complete" : "cleanup_failed",
      message: success ? "Migration complete. Bucardo replication and target migrator state removed." : "Cleanup failed.",
      error: success ? nil : output,
      started_at: started_at,
      completed_at: completed_at,
    }))
    # On success the rm script has dropped the _ps_migrator schema (incl. the
    # migration_state table) from the target -- do NOT write_persistent_state,
    # which would recreate it and leave an artifact behind. On failure the schema
    # is still there, so persist the error for restart recovery.
    unless success
      write_persistent_state("error", started_at: started_at, completed_at: completed_at, error: output&.slice(0, 500))
    end
  end

  res.body = JSON.generate({ success: true, message: "Cleanup started. Check /status for progress." })
end

# POST /retry - reset to waiting so the user can fix issues and start again
server.mount_proc "/retry" do |req, res|
  require_auth(req, res)

  unless req.request_method == "POST"
    res.status = 405
    res.content_type = "application/json"
    res.body = JSON.generate({ error: "Method not allowed" })
    next
  end

  res.content_type = "application/json"

  current = read_status_file
  unless current["phase"] == "error"
    res.status = 409
    res.body = JSON.generate({ success: false, error: "Retry is only available when the migration is in an error state (current phase: #{current["phase"]})." })
    next
  end

  started_at = current["started_at"]

  # A failed attempt may have already registered "heroku"/"planetscale" in
  # Bucardo's catalog. Tear that down before resetting to "waiting" so the
  # next attempt's mk-bucardo-repl.sh doesn't collide with a stale entry.
  File.write(STATUS_FILE, JSON.generate({
    phase: "cleaning_up",
    state: "removing_replication",
    message: "Removing Bucardo replication before retry...",
    error: nil,
    started_at: started_at,
  }))
  write_persistent_state("cleaning_up", started_at: started_at)

  # Run cleanup in a thread so we can respond immediately
  Thread.new do
    success, output = run_bucardo_teardown

    if success
      File.write(STATUS_FILE, JSON.generate({
        phase: "waiting",
        state: "ready",
        message: "Ready to start migration.",
        error: nil,
      }))
      write_persistent_state("waiting")
    else
      File.write(STATUS_FILE, JSON.generate({
        phase: "error",
        state: "retry_cleanup_failed",
        message: "Failed to remove Bucardo replication before retry.",
        error: output,
        started_at: started_at,
      }))
      write_persistent_state("error", started_at: started_at, error: output&.slice(0, 500))
    end
  end

  res.body = JSON.generate({ success: true, message: "Cleaning up previous attempt. Check /status for progress." })
end

# POST /reset - return the tool to a fresh "waiting" state after a finished run
# (aborted / completed / error) so a new migration can be started WITHOUT
# restarting the container. Drives the "Start a new migration" button.
server.mount_proc "/reset" do |req, res|
  require_auth(req, res)

  unless req.request_method == "POST"
    res.status = 405
    res.content_type = "application/json"
    res.body = JSON.generate({ error: "Method not allowed" })
    next
  end

  res.content_type = "application/json"

  current = read_status_file
  allowed_phases = %w[aborted completed error]
  unless allowed_phases.include?(current["phase"])
    res.status = 409
    res.body = JSON.generate({ success: false, error: "Start a new migration is only available after a migration has aborted, completed, or errored (current phase: #{current["phase"]})." })
    next
  end

  # Abort/Complete stop the Bucardo daemon; make sure it is running again so the
  # next migration can configure replication without a container restart.
  run_bucardo_teardown
  `bucardo start 2>/dev/null || bucardo restart 2>/dev/null`

  # Clear notification de-dupe and stale copy progress so the new run starts clean.
  $last_notified_phase = nil
  $last_notified_copy_phase = nil
  FileUtils.rm_f(COPY_PROGRESS_FILE)
  start_new_rebuild_log
  # Start each migration from the configured default parallelism; the dashboard
  # control writes a fresh per-migration override at the ready_to_copy step.
  FileUtils.rm_f(REBUILD_WORKERS_FILE)

  File.write(STATUS_FILE, JSON.generate({
    phase: "waiting",
    state: "ready",
    message: "Ready to start a new migration.",
    error: nil,
  }))
  write_persistent_state("waiting")

  res.body = JSON.generate({ success: true, message: "Reset complete. Ready to start a new migration." })
end

# POST /verify - run the source-vs-target verification (scripts/verify-migration.sh)
# in the background, streaming its output to VERIFY_FILE. Bucardo/migrator metadata
# is excluded by the script. GET /verify-output polls progress + result.
server.mount_proc "/verify" do |req, res|
  require_auth(req, res)
  res.content_type = "application/json"

  unless req.request_method == "POST"
    res.status = 405
    res.body = JSON.generate({ error: "Method not allowed" })
    next
  end

  # Only meaningful AFTER cutover: until writes are revoked on Heroku ("switched"),
  # the source keeps changing and the databases can never fully match, so exact
  # row-count checks would report spurious differences.
  current_phase = read_status_file["phase"]
  unless %w[switched cleaning_up completed].include?(current_phase)
    res.status = 409
    res.body = JSON.generate({ success: false, error: "Verification is available after you switch traffic (so the source is frozen and the databases can fully match). Current phase: #{current_phase}." })
    next
  end

  started = false
  $verify_mutex.synchronize do
    unless $verify_running
      $verify_running = true
      $verify_exit = nil
      started = true
    end
  end

  if started
    Thread.new do
      begin
        File.write(VERIFY_FILE, "Verifying migration — comparing source (Heroku) and target (PlanetScale)...\n\n")
        # Run with bash: the script uses process substitution / $'\t', which the
        # container's /bin/sh (dash) does not support.
        system("bash #{SCRIPTS_DIR}/verify-migration.sh >> #{VERIFY_FILE} 2>&1")
        $verify_exit = $?.exitstatus
      rescue => e
        File.open(VERIFY_FILE, "a") { |f| f.puts("\nERROR: #{e.message}") } rescue nil
        $verify_exit = 2
      ensure
        $verify_mutex.synchronize { $verify_running = false }
      end
    end
  end

  res.body = JSON.generate({ success: true, running: true, started: started })
end

# GET /verify-output - current verification output + running/result state.
server.mount_proc "/verify-output" do |req, res|
  require_auth(req, res)
  res.content_type = "application/json"
  output = File.exist?(VERIFY_FILE) ? File.read(VERIFY_FILE) : ""
  result = case $verify_exit
           when 0 then "passed"
           when 1 then "warnings"
           when nil then nil
           else "failed"
           end
  res.body = JSON.generate({ running: $verify_running, exit: $verify_exit, result: result, output: output })
end

# POST /abort - emergency stop: removes all Bucardo triggers and replication from any active phase
server.mount_proc "/abort" do |req, res|
  require_auth(req, res)

  unless req.request_method == "POST"
    res.status = 405
    res.content_type = "application/json"
    res.body = JSON.generate({ error: "Method not allowed" })
    next
  end

  res.content_type = "application/json"

  current = read_status_file
  allowed_phases = %w[configuring ready_to_copy copying rebuilding_indexes index_rebuild_failed replicating error]
  unless allowed_phases.include?(current["phase"])
    res.status = 409
    res.body = JSON.generate({ success: false, error: "Abort is not available in the current phase (#{current["phase"]})." })
    next
  end

  started_at = current["started_at"]

  File.write(STATUS_FILE, JSON.generate({
    phase: "cleaning_up",
    state: "aborting",
    message: "Aborting migration and removing Bucardo triggers...",
    error: nil,
    started_at: started_at,
  }))
  write_persistent_state("cleaning_up", started_at: started_at)
  notify_slack(":stop_sign: Migration aborted#{branch_tag}")

  Thread.new do
    success, output = run_bucardo_teardown
    completed_at = Time.now.utc.iso8601

    File.write(STATUS_FILE, JSON.generate({
      phase: success ? "aborted" : "error",
      state: success ? "aborted" : "abort_failed",
      message: success ? "Migration aborted. All Bucardo triggers have been removed from your Heroku database. We recommend running ANALYZE on your Heroku database to refresh query plan statistics." : "Abort cleanup failed.",
      error: success ? nil : output,
      started_at: started_at,
      completed_at: completed_at,
    }))
    # On success the rm script dropped the _ps_migrator schema (incl. migration_state)
    # from the target -- do NOT recreate it via write_persistent_state. On failure
    # the schema remains, so persist the error for restart recovery.
    unless success
      write_persistent_state("error", started_at: started_at, completed_at: completed_at, error: output&.slice(0, 500))
    end
  end

  res.body = JSON.generate({ success: true, message: "Abort started. Removing triggers and replication. Check /status for progress." })
end

# ---------------------------------------------------------------------------
# Signal handlers and start
# ---------------------------------------------------------------------------
trap("INT") { server.shutdown }
trap("TERM") { server.shutdown }

# ---------------------------------------------------------------------------
# Phase watcher
# ---------------------------------------------------------------------------
# drives the copy -> rebuilding_indexes transition 
PHASE_WATCHER_INTERVAL = 30       # seconds between ticks
PHASE_WATCHER_STATUS_GRACE = 20   # skip a tick if /status just evaluated

PHASE_WATCHER_PHASES = ["ready_to_copy", "copying", "rebuilding_indexes"].freeze

def phase_watcher_tick
  base = read_status_file
  phase = base.is_a?(Hash) ? base["phase"] : nil
  return unless PHASE_WATCHER_PHASES.include?(phase)

  last = $last_status_eval_at
  return if last && (Time.now - last) < PHASE_WATCHER_STATUS_GRACE

  $phase_transition_mutex.synchronize do
    bucardo_status = get_bucardo_status
    return unless bucardo_status

    persisted = read_persistent_state
    persisted_phase = persisted.is_a?(Hash) ? persisted["phase"] : nil
    combined = base.merge("bucardo" => bucardo_status)

    before = combined["phase"]
    apply_auto_transitions(combined, bucardo_status, persisted_phase)
    after = combined["phase"]
    $stderr.puts "[phase-watcher] #{before} -> #{after}" if after != before
  end
end

Thread.new do
  loop do
    sleep PHASE_WATCHER_INTERVAL
    begin
      phase_watcher_tick
    rescue StandardError => e
      $stderr.puts "[phase-watcher] #{e.class}: #{e.message}"
    end
  end
end

puts "Status server listening on port #{PORT}..."
server.start
