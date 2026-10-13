# frozen_string_literal: true

class Pitchbook < ApplicationRecord
  belongs_to :target_company, class_name: "Company", optional: true
  has_many :slides, -> { order(:seq) }, dependent: :destroy
  has_many :comp_members, dependent: :destroy
  has_many :comp_companies, through: :comp_members, source: :company
  has_many :evidences, -> { order(:id) }, dependent: :destroy

  validates :title, presence: true

  def assumptions_hash
    JSON.parse(assumptions.presence || "{}", symbolize_names: true)
  rescue JSON::ParserError
    {}
  end

  def assumptions_hash=(hash)
    self.assumptions = JSON.generate(hash || {})
  end

  def comp_tickers
    comp_members.where(kind: "trading").joins(:company).order("companies.ticker").pluck("companies.ticker")
  end
end
