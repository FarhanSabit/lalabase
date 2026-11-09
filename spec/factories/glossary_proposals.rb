# frozen_string_literal: true

# An open proposal of the glossary extraction. Invented terms only.
FactoryBot.define do
  factory :glossary_proposal do
    sequence(:term) { |n| "Zorbelwort #{n}" }
    association :organisation

    trait :accepted do
      status { 'accepted' }
      decided_at { Time.current }
    end

    trait :dismissed do
      status { 'dismissed' }
      decided_at { Time.current }
    end
  end
end
