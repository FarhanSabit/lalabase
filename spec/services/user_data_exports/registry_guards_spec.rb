# frozen_string_literal: true

require 'rails_helper'

# Structural guards for the GDPR export registry (doc/user_data_export_plan.md).
#
# Guard 1 — secrets: the export must NEVER emit credential material. Whitelists
# are declared in UserDataExports::Registry; this spec breaks the build if any
# declared key looks like a secret, so "someone adds a column later and it
# leaks into the ZIP" is structurally impossible.
#
# Guard 2 — completeness: the export must not drift into silent incompleteness.
# Every table that references a user (real FK to users OR a user-ish column
# name — FK constraints are NOT reliable here, e.g. posts.user_id has none)
# must be classified: either a Registry source or an EXCLUDED entry with a
# reason. A new user-data table breaks the build until it is classified.
# Works on DB introspection (connection.foreign_keys/columns), NOT on parsing
# schema.rb text — dump formatting changes cannot break it.
# Secret shapes that must never appear as exported keys.
EXPORT_FORBIDDEN_KEY_PATTERN = /password|secret|token|_hash\z|\Ahash\z|session_id|otp|credential|api_key|encrypted/i
# Public identifier by design: the PAT prefix is shown in the UI so users can
# recognise their tokens; it grants no access.
EXPORT_ALLOWED_KEY_EXCEPTIONS = %w[token_prefix].freeze

# Column-name heuristic on top of real FKs: several user references carry no
# FK constraint (posts.user_id!), and *_by_id columns (archived_by_id,
# subscribed_by_id) reference users without the plain user_id name.
EXPORT_USER_REF_PATTERN = /
  \A(user_id|creator_id|actor_id|recipient_id|author_id|inviter_id|
     deleted_user_id|visible_to_user_id|updater_id|owner_id|assignee_id)\z
  | _by_user_id\z
  | _by_id\z
/x
EXPORT_GUARD_SKIP_TABLES = %w[schema_migrations ar_internal_metadata].freeze
EXPORT_GUARD_SKIP_PREFIXES = %w[active_storage_ action_text_ solid_queue_ solid_cache_ solid_cable_].freeze

RSpec.describe UserDataExports::Registry do
  describe 'secret guard' do
    it 'never exports keys that look like credential material' do
      offenders = described_class::SOURCES.flat_map do |source|
        source.exported_keys
              .reject { |key| EXPORT_ALLOWED_KEY_EXCEPTIONS.include?(key) }
              .select { |key| key.match?(EXPORT_FORBIDDEN_KEY_PATTERN) }
              .map { |key| "#{source.key}: #{key}" }
      end

      expect(offenders).to be_empty,
                           "Secret-looking keys in the export whitelist: #{offenders.join(', ')}"
    end

    it 'declares exported keys for every source (auditable surface)' do
      described_class::SOURCES.each do |source|
        expect(source.exported_keys).to be_present,
                                        "Source #{source.key} exposes no auditable key list"
      end
    end

    # Whitelist entries must be REAL: a typo or a later column rename would
    # otherwise only surface as a NoMethodError in the production job.
    it 'declares only attributes that exist on the model' do
      described_class::SOURCES.reject(&:serializer_class).each do |source|
        source.attributes.each do |attr|
          readable = source.model.column_names.include?(attr) ||
                     source.model.public_method_defined?(attr)
          expect(readable).to be(true),
                              "#{source.key}: attribute '#{attr}' does not exist on #{source.model.name}"
        end
      end
    end

    it 'keeps attributes and computed keys disjoint (no silent overwrite)' do
      described_class::SOURCES.each do |source|
        overlap = source.attributes & source.computed.keys.map(&:to_s)
        expect(overlap).to be_empty,
                           "#{source.key}: computed keys shadow attributes: #{overlap.join(', ')}"
      end
    end

    # Concrete anti-leak pin for the most sensitive source: the PAT prefix is
    # deliberately exported (public identifier), the hash must never be.
    it 'exports the PAT prefix but never the token hash' do
      api_tokens = described_class::SOURCES.find { |s| s.key == :api_tokens }
      expect(api_tokens.exported_keys).to include('token_prefix')
      expect(api_tokens.exported_keys).not_to include('token_hash')
    end

    # S3 KI-Kontingent: personal usage attribution is exported (what/when/credits),
    # internal cost/margin statistics (cost_cents, metadata, tokens) are NOT.
    it 'exports the AI usage action/credits but never the internal cost statistics' do
      ai_usages = described_class::SOURCES.find { |s| s.key == :ai_usages }
      expect(ai_usages.exported_keys).to include('action', 'credits_used', 'used_at')
      expect(ai_usages.exported_keys).not_to include('cost_cents', 'metadata', 'tokens_used')
    end
  end

  # Art. 15 does not stop at the messages: once a thread BELONGS to a person
  # (assistant plan §5.1), its frame is their data too. Exporting only chatposts
  # would hand somebody their questions without the threads they sit in — the
  # chat_title on a post is a convenience field, not the thread's own record.
  describe 'chats (the thread frame, not just its posts)' do
    it 'exports the chat frame as its own source' do
      expect(described_class.covered_tables).to include('chats')
    end

    it 'scopes it to the owner, never to everyone who posted in the thread' do
      source = described_class::SOURCES.find { |s| s.key == :chats }
      owner = create(:user)
      other = create(:user)
      organisation = create(:organisation)

      ActsAsTenant.with_tenant(organisation) do
        create(:project, organisation: organisation)
        mine = create(:chat, organisation: organisation, user: owner)
        theirs = create(:chat, organisation: organisation, user: other)
        # A post of mine in a thread that is not mine must not drag the frame along.
        create(:chatpost, chat: theirs, organisation: organisation, user: owner, content: 'Frage')

        expect(source.scope.call(owner).to_a).to eq([mine])
      end
    end
  end

  # K4a: the heard forms a member spoke are data about the account; who
  # corrected them and the glossary itself are org knowledge (EXCLUDED).
  describe 'term_corrections (the heard forms the account spoke)' do
    it 'exports the spoken forms only, with term and project, never who corrected them' do
      source = described_class::SOURCES.find { |s| s.key == :term_corrections }
      speaker = create(:user)
      corrector = create(:user)
      organisation = create(:organisation)

      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: speaker, organisation: organisation)
        create(:membership, user: corrector, organisation: organisation)
        project = create(:project, organisation: organisation, name: 'Beispielprojekt')
        term = create(:glossary_term, organisation: organisation, term: 'Lalabase')
        spoken = create(:term_correction, organisation: organisation, glossary_term: term, project: project,
                                          heard: 'lala bass', user: speaker, corrected_by: corrector)
        create(:term_correction, organisation: organisation, glossary_term: term, user: corrector)

        expect(source.scope.call(speaker).to_a).to eq([spoken])
        expect(source.computed[:term].call(spoken)).to eq('Lalabase')
        expect(source.computed[:project_name].call(spoken)).to eq('Beispielprojekt')
      end
      expect(source.exported_keys).not_to include('corrected_by_id', 'user_id', 'person_id')
      expect(described_class::EXCLUDED).to have_key('glossary_terms')
    end
  end

  describe 'completeness guard' do
    def user_referencing_tables
      connection = ActiveRecord::Base.connection
      connection.tables.filter_map do |table|
        next if EXPORT_GUARD_SKIP_TABLES.include?(table)
        next if EXPORT_GUARD_SKIP_PREFIXES.any? { |prefix| table.start_with?(prefix) }

        fk_to_users = connection.foreign_keys(table).any? { |fk| fk.to_table == 'users' }
        ref_column = connection.columns(table).any? { |c| c.name.match?(EXPORT_USER_REF_PATTERN) }
        table if fk_to_users || ref_column
      end
    end

    it 'classifies every table with a user reference (registry or EXCLUDED with reason)' do
      unclassified = user_referencing_tables -
                     described_class.covered_tables -
                     described_class::EXCLUDED.keys

      expect(unclassified).to be_empty, <<~MSG
        Tables with user references that are neither exported nor excluded:
          #{unclassified.join(', ')}
        Classify each one: add a Registry source (export) or an EXCLUDED entry
        (with a reason) in app/services/user_data_exports/registry.rb.
      MSG
    end

    it 'keeps EXCLUDED free of stale entries' do
      stale = described_class::EXCLUDED.keys - user_referencing_tables
      expect(stale).to be_empty,
                       "EXCLUDED entries without a user reference (drop them): #{stale.join(', ')}"
    end

    it 'gives every EXCLUDED entry a reason' do
      described_class::EXCLUDED.each do |table, reason|
        expect(reason).to be_present, "EXCLUDED #{table} has no reason"
      end
    end

    it 'does not classify a table as both exported and excluded' do
      overlap = described_class.covered_tables & described_class::EXCLUDED.keys
      expect(overlap).to be_empty, "Both exported and excluded: #{overlap.join(', ')}"
    end

    it 'marks tenant-scoped sources only on acts_as_tenant models' do
      # Column presence is not enough: a model with organisation_id but without
      # acts_as_tenant would silently return cross-org rows inside the
      # with_tenant loop (duplicated into every org folder).
      described_class.tenant_sources.each do |source|
        expect(source.model.scoped_by_tenant?).to be(true),
                                                  "#{source.key} is tenant_scoped but #{source.model.name} is not acts_as_tenant"
      end
    end
  end

  describe 'post acknowledgement sources' do
    it 'exports only the reactions and reads owned by the user' do
      organisation = create(:organisation)
      owner = create(:user)
      other_user = create(:user)

      ActsAsTenant.with_tenant(organisation) do
        project = create(:project, organisation: organisation)
        ticket = create(:ticket, organisation: organisation, project: project)
        post_record = create(:post, organisation: organisation, ticket: ticket, user: other_user)
        own_reaction = create(:post_reaction, organisation: organisation, post: post_record, user: owner)
        create(:post_reaction, organisation: organisation, post: post_record, user: other_user)
        own_read = create(:post_read, organisation: organisation, post: post_record, user: owner)
        create(:post_read, organisation: organisation, post: post_record, user: other_user)

        reactions = described_class::SOURCES.find { |source| source.key == :post_reactions }
        reads = described_class::SOURCES.find { |source| source.key == :post_reads }

        expect(reactions.scope.call(owner)).to contain_exactly(own_reaction)
        expect(reads.scope.call(owner)).to contain_exactly(own_read)
      end
    end
  end
end
