# frozen_string_literal: true

class Document < ApplicationRecord
  belongs_to :company, optional: true
  has_many :chunks, -> { order(:seq) }, dependent: :destroy
  has_many :kpis, dependent: :destroy
  has_many :evidences, dependent: :nullify

  validates :title, :doc_type, :published_at, :body, presence: true
  validates :external_id, uniqueness: true, allow_nil: true

  scope :newest_first, -> { order(published_at: :desc, id: :desc) }
end
