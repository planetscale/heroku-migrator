#!/usr/bin/env ruby
# frozen_string_literal: true

# =============================================================================
# test_server_wrapper.rb -- run status-server/server.rb locally.
#
# Rewrites the hardcoded paths in server.rb so the status server runs against a
# temp directory, stub scripts and a fake `bucardo` binary. Not run directly;
# the shell tests launch it.
#
# Usage:
#   TEST_STATE_DIR=/tmp/test_state \
#   PASSWORD=test \
#   DISABLE_AUTH=true \
#   DISABLE_NOTIFICATIONS=true \
#     ruby tests/test_server_wrapper.rb
# =============================================================================

require "fileutils"

state_dir = ENV.fetch("TEST_STATE_DIR")
FileUtils.mkdir_p(state_dir)

scripts_dir = File.join(state_dir, "scripts")
FileUtils.mkdir_p(scripts_dir)

# No-op stand-ins for the real scripts. Each appends to a shared call_log so
# tests can assert which ran, and in what order.
File.write(File.join(scripts_dir, "rm-bucardo-repl.sh"), <<~SH)
  #!/bin/sh
  printf 'rm-bucardo-repl %s\\n' "$*" >> "$TEST_STATE_DIR/call_log"
  echo 'fake cleanup'
  touch "$TEST_STATE_DIR/rm_bucardo_repl_called"
SH

# Exit code comes from a file, so one stub covers both the success and the
# fail-closed paths.
File.write(File.join(scripts_dir, "mk-bucardo-repl.sh"), <<~SH)
  #!/bin/sh
  printf 'mk-bucardo-repl %s\\n' "$*" >> "$TEST_STATE_DIR/call_log"
  echo 'fake setup'
  touch "$TEST_STATE_DIR/mk_bucardo_repl_called"
  code=$(cat "$TEST_STATE_DIR/mk_bucardo_repl_exit" 2>/dev/null || echo 0)
  if [ "$code" != "0" ]; then
    echo "FAKE_SETUP_FAILURE: no bucardo.track_* tables exist on the source database." >&2
  fi
  exit "$code"
SH

File.write(File.join(scripts_dir, "stat-bucardo-repl.sh"), "#!/bin/sh\necho 'fake stat'\n")

# Write default status file if missing
unless File.exist?(File.join(state_dir, "status.json"))
  require "json"
  File.write(File.join(state_dir, "status.json"),
    JSON.generate({ phase: "waiting", state: "ready", message: "Ready", error: nil }))
end

# Patch the hardcoded paths, then evaluate it in place.
server_path = File.expand_path("../status-server/server.rb", __dir__)
source = File.read(server_path)

replacements = {
  'STATE_DIR = "/opt/bucardo/state"' => "STATE_DIR = #{state_dir.inspect}",
  'BUCARDO_LOG_FILE = "/var/log/bucardo/log.bucardo"' => "BUCARDO_LOG_FILE = #{File.join(state_dir, 'log.bucardo').inspect}",
  'SCRIPTS_DIR = "/opt/bucardo/scripts"' => "SCRIPTS_DIR = #{scripts_dir.inspect}",
}

replacements.each do |old, new_val|
  unless source.include?(old)
    $stderr.puts "WARNING: Could not find '#{old}' in server.rb"
  end
  source = source.sub(old, new_val)
end

# Stub out persistent state queries: there is no real target database.
source = source.sub(
  /^def ps_migrate_query\(sql\).*?^end/m,
  "def ps_migrate_query(sql)\n  \"\"\nend"
)

eval(source, binding, server_path, 1)
