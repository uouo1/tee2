# frozen_string_literal: true

class CompMember < ApplicationRecord
  belongs_to :pitchbook
  belongs_to :company
end
