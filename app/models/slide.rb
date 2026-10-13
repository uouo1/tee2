# frozen_string_literal: true

class Slide < ApplicationRecord
  belongs_to :pitchbook
  has_many :evidences, dependent: :nullify
  validates :seq, :kind, :title, presence: true

  # Payloads are stored as JSON text and handled as symbol-keyed hashes in Ruby.
  def payload_hash
    JSON.parse(payload.presence || "{}", symbolize_names: true)
  rescue JSON::ParserError
    {}
  end

  def payload_hash=(hash)
    self.payload = JSON.generate(hash || {})
  end
end
