# frozen_string_literal: true

# A heard form of a glossary term. Invented words only.
FactoryBot.define do
  factory :term_correction do
    sequence(:heard) { |n| "bei spiel wort #{n}" }
    glossary_term { association :glossary_term, organisation: organisation }
    association :organisation
  end
end
