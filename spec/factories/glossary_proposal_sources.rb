# frozen_string_literal: true

# Where a proposal was found: by default a ticket of the same organisation and
# project. Invented words only.
FactoryBot.define do
  factory :glossary_proposal_source do
    association :organisation
    glossary_proposal { association :glossary_proposal, organisation: organisation }
    project { association :project, organisation: organisation }
    source { association :ticket, organisation: organisation, project: project }
    snippet { 'Der Zorbel Hub steht im Ticket.' }
  end
end
