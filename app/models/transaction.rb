# frozen_string_literal: true

# A precedent M&A transaction. Named Transaction for parity with the schema;
# it has nothing to do with database transactions.
class Transaction < ApplicationRecord
  validates :announced_on, :target, :acquirer, presence: true
  scope :newest_first, -> { order(announced_on: :desc) }
end
