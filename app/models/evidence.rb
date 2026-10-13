# frozen_string_literal: true

class Evidence < ApplicationRecord
  belongs_to :pitchbook
  belongs_to :slide, optional: true
  belongs_to :document, optional: true
  belongs_to :chunk, optional: true
  validates :quote, presence: true
end
