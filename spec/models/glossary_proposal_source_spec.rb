# frozen_string_literal: true

require 'rails_helper'

# Where a proposal of the glossary extraction was found (K5b): a ticket, a
# comment, a file, a note or a document version of the same organisation,
# referenced by type and id without a foreign key, with a short snippet.
# Invented words only.
RSpec.describe GlossaryProposalSource, :ci_guard, type: :model do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }
  let(:connection) { ActiveRecord::Base.connection }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  let(:proposal) { create(:glossary_proposal, organisation: organisation, term: 'Zorbel Hub') }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, organisation: organisation, project: project) }

  # The ticket is the source unless the example names one (a source_id
  # override makes FactoryBot skip the source of the factory).
  def built_with(**attributes)
    attributes = { source: ticket, **attributes } unless attributes.key?(:source) || attributes.key?(:source_id)
    build(:glossary_proposal_source, organisation: organisation, glossary_proposal: proposal, project: project, **attributes)
  end

  def source_with(**attributes)
    built_with(**attributes).tap(&:save!)
  end

  # One row of each kind of text a run reads, in the given organisation.
  def rows_of(org)
    ActsAsTenant.with_tenant(org) do
      org_project = create(:project, organisation: org)
      org_ticket = create(:ticket, organisation: org, project: org_project)
      org_post = create(:post, organisation: org, ticket: org_ticket)
      document = create(:document, organisation: org, project: org_project)
      {
        'Ticket' => org_ticket,
        'Post' => org_post,
        'TicketDocument' => create(:ticket_document, organisation: org, ticket: org_ticket),
        'PostDocument' => create(:post_document, :without_embeddings, organisation: org, post: org_post),
        'Note' => create(:note, organisation: org, project: org_project),
        'DocumentVersion' => create(:document_version, organisation: org, document: document)
      }
    end
  end

  it 'is bound to the tenant' do
    mine = source_with
    theirs = ActsAsTenant.with_tenant(other_organisation) { create(:glossary_proposal_source, organisation: other_organisation) }

    expect(described_class.all).to contain_exactly(mine)
    expect(described_class.unscoped.where(id: theirs.id)).to exist
  end

  it 'points at its source by type and id' do
    source = source_with

    expect([source.source_type, source.source_id]).to eq(['Ticket', ticket.id])
    expect(described_class.find(source.id).source).to eq(ticket)
  end

  describe 'the source type' do
    it 'knows the six kinds of text a run reads, nothing else' do
      expect(described_class::SOURCE_TYPES).to eq(%w[Ticket Post TicketDocument PostDocument Note DocumentVersion])

      meeting = built_with(source_type: 'Meeting', source_id: SecureRandom.uuid)
      expect(meeting).not_to be_valid
      expect(meeting.errors.details[:source_type]).to include(a_hash_including(error: :inclusion))
    end

    it 'stores every known type in the database' do
      source = source_with

      Prosopite.pause do
        described_class::SOURCE_TYPES.each do |type|
          source.update_column(:source_type, type)
          expect(source.reload.source_type).to eq(type)
        end
      end
    end

    it 'is held by the database too' do
      source = source_with

      expect { source.update_column(:source_type, 'Meeting') }
        .to raise_error(ActiveRecord::StatementInvalid, /glossary_proposal_sources_source_type_known/)
    end
  end

  it 'requires a source id' do
    source = built_with(source_type: 'Ticket', source_id: nil)

    expect(source).not_to be_valid
    expect(source.errors.details[:source_id]).to include(error: :blank)
  end

  describe 'the source row' do
    # The check reads organisation_id from the row itself, so every table it
    # reads must have one; a new kind without it needs a check through its
    # parent instead.
    it 'is of a kind whose table carries the organisation itself' do
      described_class::SOURCE_TYPES.each do |type|
        column = type.constantize.columns_hash['organisation_id']

        expect(column&.null).to be(false), "#{type} has no organisation_id of its own"
      end
    end

    it 'may be a row of each kind of its own organisation' do
      rows = rows_of(organisation)

      Prosopite.pause do
        rows.each do |type, row|
          source = built_with(source: row)

          expect(source).to be_valid, "#{type}: #{source.errors.full_messages.to_sentence}"
          expect(source.source_type).to eq(type)
        end
      end
    end

    it 'may not be a row of another organisation, of any kind' do
      rows = rows_of(other_organisation)

      Prosopite.pause do
        rows.each do |type, row|
          source = built_with(source: row)

          expect(source).not_to be_valid, type
          expect(source.errors.details[:source]).to include(error: :invalid)
        end
      end
    end

    it 'may not be a row of another organisation without a tenant set either' do
      foreign = ActsAsTenant.with_tenant(other_organisation) do
        create(:note, organisation: other_organisation, project: create(:project, organisation: other_organisation))
      end
      source = ActsAsTenant.without_tenant { built_with(source: foreign).tap(&:validate) }

      expect(source.errors.details[:source]).to include(error: :invalid)
    end

    it 'must be there when the source is written' do
      source = built_with(source_type: 'Note', source_id: SecureRandom.uuid)

      expect(source).not_to be_valid
      expect(source.errors.details[:source]).to include(error: :invalid)
    end

    it 'may be gone later: the row stays and can still be changed' do
      note = create(:note, organisation: organisation, project: project)
      source = source_with(source: note)

      note.destroy!
      source.reload

      expect(source.source).to be_nil
      expect(source.update(snippet: 'ein Satz mit Zorbel Hub', occurrences: 2)).to be(true)
    end
  end

  describe 'references to rows of another organisation' do
    let(:foreign) do
      ActsAsTenant.with_tenant(other_organisation) do
        {
          glossary_proposal: create(:glossary_proposal, organisation: other_organisation),
          project: create(:project, organisation: other_organisation)
        }
      end
    end

    it 'names the proposal and the project' do
      expect(described_class::TENANT_REFERENCES).to eq(%i[glossary_proposal project])
    end

    GlossaryProposalSource::TENANT_REFERENCES.each do |name|
      it "refuses a #{name} of another organisation" do
        source = built_with
        source.public_send(:"#{name}_id=", foreign.fetch(name).id)

        expect(source).not_to be_valid
        expect(source.errors[name]).to be_present
      end

      it "refuses a #{name} of another organisation without a tenant set" do
        foreign_id = foreign.fetch(name).id
        source = ActsAsTenant.without_tenant do
          built = built_with
          built.public_send(:"#{name}_id=", foreign_id)
          built.validate
          built
        end

        expect(source.errors[name]).to be_present
      end
    end

    it 'needs no project' do
      expect(built_with(project: nil)).to be_valid
    end
  end

  describe 'the snippet' do
    it 'is empty unless set and at most MAX_SNIPPET characters' do
      expect(described_class.new.snippet).to eq('')
      expect(described_class::MAX_SNIPPET).to eq(240)
      expect(built_with(snippet: 'a' * described_class::MAX_SNIPPET)).to be_valid

      too_long = built_with(snippet: 'a' * (described_class::MAX_SNIPPET + 1))
      expect(too_long).not_to be_valid
      expect(too_long.errors.details[:snippet]).to include(a_hash_including(error: :too_long))
    end
  end

  describe 'the occurrences' do
    it 'is one unless set, a whole number and at least one' do
      expect(described_class.new.occurrences).to eq(1)
      expect(built_with(occurrences: 0)).not_to be_valid
      expect(built_with(occurrences: 2.5)).not_to be_valid
      expect(built_with(occurrences: 3)).to be_valid
    end

    it 'is held by the database too' do
      source = source_with

      expect { source.update_column(:occurrences, 0) }
        .to raise_error(ActiveRecord::StatementInvalid, /glossary_proposal_sources_occurrences_positive/)
    end
  end

  describe 'the indexes' do
    it 'keeps one row per proposal and source' do
      source_with

      expect { built_with.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'lets another proposal name the same source' do
      source_with
      other = create(:glossary_proposal, organisation: organisation, term: 'Quarnix')

      expect(built_with(glossary_proposal: other).save).to be(true)
    end

    it 'finds the rows of a source by its type and id' do
      indexes = connection.indexes('glossary_proposal_sources').to_h { |index| [index.columns, index.unique] }

      expect(indexes).to include(%w[source_type source_id] => false, %w[glossary_proposal_id source_type source_id] => true)
    end
  end

  describe 'deleting' do
    it 'says the delete rules in the foreign keys, and none for the source' do
      keys = connection.foreign_keys('glossary_proposal_sources').to_h { |key| [key.column, [key.to_table, key.on_delete]] }

      expect(keys).to eq(
        'organisation_id' => ['organisations', :cascade],
        'glossary_proposal_id' => ['glossary_proposals', :cascade],
        'project_id' => ['projects', :nullify]
      )
    end

    it 'the project leaves the source without it' do
      source = source_with(source: create(:note, organisation: organisation, project: project))

      project.destroy!
      source.reload

      expect(source.project_id).to be_nil
      expect(source.glossary_proposal_id).to eq(proposal.id)
    end
  end
end
