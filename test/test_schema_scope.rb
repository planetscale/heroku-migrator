#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "tmpdir"

PROJECT_DIR = File.expand_path("..", __dir__)
SERVER_PATH = File.join(PROJECT_DIR, "status-server", "server.rb")

$pass = 0
$fail = 0

def pass(message)
  $pass += 1
  puts "  PASS #{message}"
end

def fail(message)
  $fail += 1
  warn "  FAIL #{message}"
end

def assert_equal(expected, actual, message)
  if expected == actual
    pass(message)
  else
    fail("#{message}: expected #{expected.inspect}, got #{actual.inspect}")
  end
end

Dir.mktmpdir do |tmp|
  bin_dir = File.join(tmp, "bin")
  FileUtils.mkdir_p(bin_dir)
  query_log = File.join(tmp, "queries.log")

  File.write(File.join(bin_dir, "psql"), <<~SH)
    #!/bin/sh
    query=""
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "-c" ]; then
        shift
        query="$1"
      fi
      shift
    done
    printf "%s\\n---\\n" "$query" >> "$QUERY_LOG"
    case "$query" in
      *"NOT EXISTS"*)
        echo "public.accounts"
        ;;
      *"a.attgenerated"*)
        echo "analytics.events|generated_value"
        ;;
      *"n.nspname = 'partman' AND c.relname = 'part_config'"*)
        if [ "$PG_PARTMAN_DETECTED" = "true" ]; then
          echo "t"
        else
          echo "f"
        fi
        ;;
      *"SELECT parent_table FROM partman.part_config"*)
        echo "public.events_parent"
        ;;
      *"partman.dump_partitioned_table_definition(parent_table)"*)
        echo "CREATE TABLE public.events_parent (id bigint);"
        ;;
    esac
  SH
  File.chmod(0o755, File.join(bin_dir, "psql"))

  ENV["PATH"] = "#{bin_dir}:#{ENV.fetch("PATH")}"
  ENV["QUERY_LOG"] = query_log
  ENV["PASSWORD"] = "test"
  ENV["DISABLE_NOTIFICATIONS"] = "true"
  ENV["HEROKU_URL"] = "postgres://user:pass@localhost:5432/source"
  ENV["PLANETSCALE_URL"] = ""
  ENV["PG_PARTMAN_DETECTED"] = "true"

  DEFAULT_MIGRATION_SCHEMAS = "public"
  DEFAULT_MIGRATION_EXCLUDE_SCHEMAS = "heroku_ext,partman,pg_partman,bucardo,pg_catalog,information_schema"
  HEROKU_URL = ENV["HEROKU_URL"]

  source = File.read(SERVER_PATH)
  schema_helpers = source[/def parse_schema_list.*?(?=\n# Phase transition tracking)/m]
  preflight_helpers = source[/def normalize_table_name.*?(?=\ndef tail_bucardo_log)/m]
  eval([schema_helpers, preflight_helpers].join("\n"), binding, SERVER_PATH, 1)

  ENV.delete("MIGRATION_SCHEMAS")
  ENV.delete("MIGRATION_EXCLUDE_SCHEMAS")
  assert_equal(["public"], migration_schema_names, "default included schema is public")
  assert_equal(
    %w[heroku_ext partman pg_partman bucardo pg_catalog information_schema],
    migration_excluded_schemas,
    "default excluded schemas include internal schemas",
  )

  ENV["MIGRATION_SCHEMAS"] = " public, analytics, public, partman "
  ENV["MIGRATION_EXCLUDE_SCHEMAS"] = " partman, pg_partman "
  assert_equal(%w[public analytics], migration_schema_names, "configured schema lists are trimmed, deduped, and excluded")

  assert_equal(["public.accounts"], check_tables_without_pk_or_unique, "PK preflight returns scoped table names")
  generated = check_tables_with_generated_columns
  assert_equal([{ "table" => "analytics.events", "columns" => ["generated_value"] }], generated, "generated-column preflight returns scoped table names")

  pg_partman = check_pg_partman
  assert_equal(true, pg_partman["detected"], "pg_partman preflight detects partman config")
  assert_equal(["public.events_parent"], pg_partman["parent_tables"], "pg_partman preflight returns managed parents")
  assert_equal("CREATE TABLE public.events_parent (id bigint);", pg_partman["recreation_sql"], "pg_partman preflight returns generated SQL")

  ENV["PG_PARTMAN_DETECTED"] = "false"
  absent_pg_partman = check_pg_partman
  assert_equal(false, absent_pg_partman["detected"], "pg_partman preflight reports absent case")

  queries = File.read(query_log)
  if queries.include?("n.nspname IN ('public', 'analytics')") && !queries.include?("n.nspname = 'public'")
    pass("preflight SQL filters by included schemas")
  else
    fail("preflight SQL did not use expected schema filter")
  end
end

if $fail.positive?
  warn "\n#{$pass} passed, #{$fail} failed"
  exit 1
end

puts "\n#{$pass} passed, #{$fail} failed"
