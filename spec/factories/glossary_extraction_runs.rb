# frozen_string_literal: true

# A run of the glossary extraction over the whole organisation, queued.
FactoryBot.define do
  factory :glossary_extraction_run do
    association :organisation
    sequence(:job_id) { |n| "glossary-extraction-job-#{n}" }
    scope { { 'kind' => 'organisation', 'everything' => true, 'since' => nil } }

    trait :running do
      status { 'running' }
    end

    trait :succeeded do
      status { 'succeeded' }
      finished_at { Time.current }
    end

    trait :failed do
      status { 'failed' }
      error_code { 'internal_error' }
      finished_at { Time.current }
    end
  end
end
