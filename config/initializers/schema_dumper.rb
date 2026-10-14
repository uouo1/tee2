# frozen_string_literal: true

# The FTS5 virtual table and its shadow tables cannot be expressed in
# schema.rb — the SQLite dumper aborts mid-file on them, leaving a truncated
# schema with no closing `end`. SearchIndex.ensure! recreates them idempotently
# (migration, test helper, seeder), so they are excluded from the dump.
ActiveRecord::SchemaDumper.ignore_tables = [/\Achunks_fts/]
