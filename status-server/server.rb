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

HEROKU_URL = ENV["HEROKU_URL"]
PLANETSCALE_URL = ENV["PLANETSCALE_URL"]

PORT = (ENV["PORT"] || 8080).to_i

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

def ensure_migration_state_table
  ps_migrate_query("CREATE TABLE IF NOT EXISTS _ps_migration_state (id integer PRIMARY KEY DEFAULT 1, phase text NOT NULL, started_at text, switched_at text, completed_at text, error text, updated_at text)")
end

def read_persistent_state
  return nil unless PLANETSCALE_URL
  row = ps_migrate_query("SELECT phase, started_at, switched_at, completed_at, error FROM _ps_migration_state WHERE id = 1")
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

  ps_migrate_query("INSERT INTO _ps_migration_state (id, phase, started_at, switched_at, completed_at, error, updated_at) VALUES (1, '#{phase}', '#{started}', #{switched == 'NULL' ? 'NULL' : "'#{switched}'"}, #{completed == 'NULL' ? 'NULL' : "'#{completed}'"}, '#{error_val}', '#{now}') ON CONFLICT (id) DO UPDATE SET phase = '#{phase}', switched_at = #{switched == 'NULL' ? 'NULL' : "'#{switched}'"}, completed_at = #{completed == 'NULL' ? 'NULL' : "'#{completed}'"}, error = '#{error_val}', updated_at = '#{now}'")
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
  tmp_dir = Dir.mktmpdir
  status_file = File.join(tmp_dir, "status.out")

  system("bucardo status planetscale_import > #{status_file} 2>/dev/null")

  return nil unless File.exist?(status_file)
  raw = File.read(status_file)
  return nil if raw.strip.empty?

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
      elsif normalized.match?(/\A(insert|update|delete|truncate|copy)\b/)
        # Bucardo can report the current SQL action being replayed. This is a
        # normal in-flight replication state, not table deletion.
        "applying_changes"
      else
        "unknown"
      end
    when /^Onetimecopy\s+:\s+(.+)/
      copy_raw = $1.strip
      result["initial_copy_phase_raw"] = copy_raw
      result["initial_copy_phase"] = case copy_raw
      when "Yes" then "in-progress"
      when "No" then "finished"
      else "unknown"
      end
    when /^Rows deleted\/inserted\s+:\s+([\d,]+)\s+\/\s+([\d,]+)/
      deleted = $1.to_s.delete(",").to_i
      inserted = $2.to_s.delete(",").to_i
      result["rows_deleted_last_sync"] = deleted
      result["rows_inserted_last_sync"] = inserted
      result["rows_changed_last_sync"] = deleted + inserted
    when /^Last good\s+:\s+(.+)/
      result["last_good_sync"] = $1.strip
    when /^Last error\s*:\s*(.*)$/
      # Bucardo sometimes emits "Last error:              : " when there is no real
      # error. Normalize that placeholder to an empty value.
      error = $1.to_s.strip.sub(/\A:+\s*/, "").strip
      result["last_error"] = error unless error.empty?
    when /^Tables in sync\s+:\s+(\d+)/
      result["tables_in_sync"] = $1.to_i
    end
  end

  result
rescue StandardError => e
  { "error" => e.message }
ensure
  FileUtils.rm_rf(tmp_dir) if defined?(tmp_dir) && tmp_dir
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

def list_public_tables
  return [] unless HEROKU_URL
  output = `psql "#{HEROKU_URL}" -A -t -c "SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename;" 2>/dev/null`.strip
  return [] if output.empty?
  output.split("\n").map { |t| normalize_table_name(t) }.compact.uniq
rescue StandardError
  []
end

# Returns public tables that have no primary key and no unique index.
# Bucardo needs at least one to reliably identify rows during replication.
def check_tables_without_pk_or_unique
  return [] unless HEROKU_URL

  query = "SELECT c.relname FROM pg_class c " \
          "JOIN pg_namespace n ON n.oid = c.relnamespace " \
          "WHERE n.nspname = 'public' AND c.relkind = 'r' " \
          "AND NOT EXISTS (" \
          "  SELECT 1 FROM pg_index i " \
          "  WHERE i.indrelid = c.oid " \
          "  AND (i.indisprimary OR i.indisunique)" \
          ") ORDER BY c.relname;"
  output = `psql "#{HEROKU_URL}" -A -t -c "#{query}" 2>/dev/null`.strip
  return [] if output.empty?
  output.split("\n").map { |t| normalize_table_name(t) }.compact.uniq
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
    { "id" => "initial_copy_complete", "label" => "Initial copy complete", "status" => (copy_phase == "finished" || ["replicating", "switched", "cleaning_up", "completed"].include?(phase)) ? "complete" : "pending" },
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

def bucardo_healthy_for_replication?(bucardo_status)
  return false unless bucardo_status.is_a?(Hash)
  current_state = bucardo_status["current_state"]
  return false unless ["good", "applying_changes"].include?(current_state)

  last_error = bucardo_status["last_error"]&.to_s&.strip
  return false if last_error && !last_error.empty?

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

      hard_blockers << "replication_not_healthy" unless bucardo_healthy_for_replication?(bucardo_status)
    end
  end

  if hard_blockers.any?
    {
      "level" => "blocked",
      "can_force" => false,
      "message" => "Cutover is blocked until replication health checks pass.",
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
  res.body = JSON.generate({
    tables_without_pk_or_unique: tables,
    all_tables_valid: tables.empty?,
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
server.mount_proc "/status" do |req, res|
  require_auth(req, res)

  res.content_type = "application/json"

  base_status = read_status_file
  bucardo_status = get_bucardo_status
  persisted = read_persistent_state
  persisted_phase = persisted.is_a?(Hash) ? persisted["phase"] : nil

  combined = base_status.merge("bucardo" => bucardo_status, "timestamp" => Time.now.utc.iso8601)

  # Auto-recovery transitions based on Bucardo state:
  # - ready_to_copy -> copying if copy is already running (e.g. start-copy timed out)
  # - copying -> replicating when initial copy is complete and healthy
  if bucardo_status
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
      elsif copy_phase == "finished"
        combined["state"] = "copy_health_check_failed"
        combined["message"] = "Initial copy appears complete, but replication health checks are not passing yet."
      elsif copy_phase == "unknown"
        combined["state"] = "copy_status_ambiguous"
        combined["message"] = "Copy status is ambiguous after Bucardo restart/output change. Waiting for a clear copy completion signal."
      end
    end
  end

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

  force_override = %w[1 true yes].include?(req.query["force"]&.to_s&.downcase)
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

  cmd = "psql \"#{HEROKU_URL}\" -c \"REVOKE INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public FROM #{username};\""
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

  cmd = "psql \"#{HEROKU_URL}\" -c \"GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO #{username};\""
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
    output = `sh #{SCRIPTS_DIR}/rm-bucardo-repl.sh --primary "#{HEROKU_URL}" --replica "#{PLANETSCALE_URL}" 2>&1`
    success = $?.success?
    completed_at = Time.now.utc.iso8601

    File.write(STATUS_FILE, JSON.generate({
      phase: success ? "completed" : "error",
      state: success ? "cleanup_complete" : "cleanup_failed",
      message: success ? "Migration complete. Bucardo replication removed." : "Cleanup failed.",
      error: success ? nil : output,
      started_at: started_at,
      completed_at: completed_at,
    }))
    write_persistent_state(
      success ? "completed" : "error",
      started_at: started_at,
      completed_at: completed_at,
      error: success ? nil : output&.slice(0, 500)
    )
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

  File.write(STATUS_FILE, JSON.generate({
    phase: "waiting",
    state: "ready",
    message: "Ready to start migration.",
    error: nil,
  }))
  write_persistent_state("waiting")

  res.body = JSON.generate({ success: true, message: "Migration reset. You can start again when ready." })
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
  allowed_phases = %w[configuring ready_to_copy copying replicating error]
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
    output = `sh #{SCRIPTS_DIR}/rm-bucardo-repl.sh --primary "#{HEROKU_URL}" --replica "#{PLANETSCALE_URL}" 2>&1`
    success = $?.success?
    completed_at = Time.now.utc.iso8601

    File.write(STATUS_FILE, JSON.generate({
      phase: success ? "completed" : "error",
      state: success ? "aborted" : "abort_failed",
      message: success ? "Migration aborted. All Bucardo triggers have been removed from your Heroku database. We recommend running ANALYZE on your Heroku database to refresh query plan statistics." : "Abort cleanup failed.",
      error: success ? nil : output,
      started_at: started_at,
      completed_at: completed_at,
    }))
    write_persistent_state(
      success ? "completed" : "error",
      started_at: started_at,
      completed_at: completed_at,
      error: success ? nil : output&.slice(0, 500)
    )
  end

  res.body = JSON.generate({ success: true, message: "Abort started. Removing triggers and replication. Check /status for progress." })
end

# ---------------------------------------------------------------------------
# Signal handlers and start
# ---------------------------------------------------------------------------
trap("INT") { server.shutdown }
trap("TERM") { server.shutdown }

puts "Status server listening on port #{PORT}..."
server.start
