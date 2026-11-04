# frozen_string_literal: true

# Invented terms only (no real customers or products in fixtures).
FactoryBot.define do
  factory :glossary_term do
    sequence(:term) { |n| "Beispielwort #{n}" }
    status { 'confirmed' }
    association :organisation

    trait :proposed do
      status { 'proposed' }
    end

    trait :rejected do
      status { 'rejected' }
    end
  end
end
