# frozen_string_literal: true

class Chunk < ApplicationRecord
  belongs_to :document
  has_many :kpis, dependent: :destroy
  validates :text, presence: true
end
