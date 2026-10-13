# frozen_string_literal: true

class Kpi < ApplicationRecord
  belongs_to :document
  belongs_to :chunk, optional: true
  belongs_to :company, optional: true
  validates :metric, presence: true
end
