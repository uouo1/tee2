# frozen_string_literal: true

# The FTS5 virtual table over chunks, plus the triggers that keep it in step.
#
# Rails' schema.rb cannot represent a virtual table or a trigger, so this is
# applied idempotently: by the migration, by the test helper after the schema
# loads, and by `argos:seed`. Every statement is CREATE ... IF NOT EXISTS.
module SearchIndex
  STATEMENTS = [
    <<~SQL,
      CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
        text, content='chunks', content_rowid='id', tokenize='porter unicode61'
      )
    SQL
    <<~SQL,
      CREATE TRIGGER IF NOT EXISTS chunks_ai AFTER INSERT ON chunks BEGIN
        INSERT INTO chunks_fts(rowid, text) VALUES (new.id, new.text);
      END
    SQL
    <<~SQL,
      CREATE TRIGGER IF NOT EXISTS chunks_ad AFTER DELETE ON chunks BEGIN
        INSERT INTO chunks_fts(chunks_fts, rowid, text) VALUES ('delete', old.id, old.text);
      END
    SQL
    <<~SQL,
      CREATE TRIGGER IF NOT EXISTS chunks_au AFTER UPDATE ON chunks BEGIN
        INSERT INTO chunks_fts(chunks_fts, rowid, text) VALUES ('delete', old.id, old.text);
        INSERT INTO chunks_fts(rowid, text) VALUES (new.id, new.text);
      END
    SQL
  ].freeze

  module_function

  def ensure!
    STATEMENTS.each { |sql| ActiveRecord::Base.connection.execute(sql) }
  end

  def drop!
    %w[chunks_au chunks_ad chunks_ai].each { |t| ActiveRecord::Base.connection.execute("DROP TRIGGER IF EXISTS #{t}") }
    ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS chunks_fts")
  end

  # Rebuild the index from the chunks table (after bulk loads that bypass triggers).
  def rebuild!
    ActiveRecord::Base.connection.execute("INSERT INTO chunks_fts(chunks_fts) VALUES ('rebuild')")
  end
end
