# frozen_string_literal: true

# What the glossary did to a meeting (K4d). Invented words only.
FactoryBot.define do
  factory :term_application do
    association :organisation
    meeting { association :meeting, organisation: organisation }
    glossary_term { association :glossary_term, organisation: organisation }
    term { glossary_term&.term || 'Beispielwort' }
    sequence(:heard) { |n| "bei spiel wort #{n}" }
    replaced_count { 1 }
  end
end
