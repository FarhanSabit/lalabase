# frozen_string_literal: true

require 'rails_helper'

# Importing many glossary terms at once from the text of a textarea (K5): one
# line per term, "Term" or "Term;Category", or a tab between term and
# category. A new term is confirmed with manage_glossary and proposed with
# only view_glossary; a term the glossary already has is skipped and keeps
# its status; a dry run reports the same numbers and writes nothing.
# Invented words and names only.
RSpec.describe Actors::ImportGlossaryTerms, :ci_guard, type: :service do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  let(:manager) { member_with(role_with('manage_glossary')) }
  let(:viewer) { member_with(role_with('view_glossary')) }

  def role_with(*glossary_actions)
    role = create(:role, organisation: organisation)
    glossary_actions.each { |action| create(:permission, role: role, category: 'glossary', action: action, allowed: true) }
    role
  end

  def member_with(role)
    user = create(:user, first_name: 'Anna', last_name: "Beispiel#{SecureRandom.hex(2)}")
    create(:membership, user: user, organisation: organisation, role: role)
    user
  end

  # The actor before its call: the example calls it and then reads its
  # report, as the controller does.
  def importer(text, user: manager, dry_run: false)
    described_class.new(organisation: organisation, text: text, current_user: user, dry_run: dry_run)
  end

  # Every count of a report: the ones named, the others zero.
  def counts(**named)
    { new: 0, existing: 0, rejected: 0, duplicate: 0, invalid: 0, created: 0, proposed: 0, categorized: 0 }.merge(named)
  end

  def category_name(key, locale)
    I18n.t(key, scope: 'views.organisations.glossary.categories', locale: locale)
  end

  # The terms of one organisation, whatever the current tenant is.
  def terms_of(owner)
    GlossaryTerm.unscoped.where(organisation_id: owner.id)
  end

  describe 'new terms' do
    it 'writes 200 lines as 200 confirmed terms with their category and creator, with manage_glossary' do
      categories = GlossaryTerm::CATEGORIES
      lines = (1..200).to_h { |n| ["Zorbel #{n}", categories[n % categories.size]] }
      actor = importer(lines.map { |term, category| "#{term};#{category}" }.join("\n"))

      result = actor.call

      expect(result).to be_success
      expect(result.resource).to eq(organisation)
      expect(terms_of(organisation).to_h { |term| [term.term, term.category] }).to eq(lines)
      expect(terms_of(organisation).distinct.pluck(:status, :created_by_id)).to eq([['confirmed', manager.id]])
      expect(actor.report.counts).to eq(counts(new: 200, created: 200))
    end

    it 'proposes new terms with only view_glossary, with their creator' do
      actor = importer("Zorbel;product\nWub", user: viewer)

      expect(actor.call).to be_success
      expect(terms_of(organisation).order(:normalized_term).pluck(:term, :category, :status, :created_by_id))
        .to eq([['Wub', nil, 'proposed', viewer.id], ['Zorbel', 'product', 'proposed', viewer.id]])
      expect(actor.report.lines.map(&:category_applied)).to eq([true, false])
      expect(actor.report.counts).to eq(counts(new: 2, proposed: 2))
    end

    # A failure at one term leaves none of the others written.
    it 'writes all lines or none' do
      allow_any_instance_of(GlossaryTerm).to receive(:save!).and_wrap_original do |original, *args, **options|
        raise ActiveRecord::StatementInvalid, 'Wub fails' if original.receiver.term == 'Wub'

        original.call(*args, **options)
      end

      expect { importer("Quarnix\nWub\nZorbel").call }.to raise_error(ActiveRecord::StatementInvalid)
      expect(terms_of(organisation).count).to eq(0)
    end
  end

  describe 'the lines of a textarea' do
    it 'splits at each kind of line break and at the first semicolon, and cleans each part' do
      actor = importer("  Zorbel ;  product \r\n\r\nWub;company;x\rQuarnix Hub\n")

      expect(actor.call).to be_success
      expect(actor.report.lines).to eq(
        [
          described_class::Line.new(number: 1, text: 'Zorbel ; product', term: 'Zorbel', category: 'product',
                                    category_applied: true, verdict: :new, existing_status: nil),
          described_class::Line.new(number: 3, text: 'Wub;company;x', term: 'Wub', category: nil,
                                    category_applied: false, verdict: :new, existing_status: nil),
          described_class::Line.new(number: 4, text: 'Quarnix Hub', term: 'Quarnix Hub', category: nil,
                                    category_applied: false, verdict: :new, existing_status: nil)
        ]
      )
    end

    # Review round 2 of #128: two columns of a spreadsheet. Cleaning turns a
    # tab into a space, so a line is split before it is cleaned. The first
    # ";" or tab wins, and the rest of the line is the category.
    it 'takes a tab between term and category like a semicolon, whichever comes first' do
      actor = importer("Zorbel\tperson\nWub\t\tproduct\nQuarnix\tplace;x\nZorbel-Hub;company\tx\nQuarnix-Hub\t")

      expect(actor.call).to be_success
      expect(actor.report.lines.map { |line| [line.number, line.term, line.category] }).to eq(
        [[1, 'Zorbel', 'person'], [2, 'Wub', 'product'], [3, 'Quarnix', nil], [4, 'Zorbel-Hub', nil], [5, 'Quarnix-Hub', nil]]
      )
      expect(terms_of(organisation).order(:normalized_term).pluck(:term, :category)).to eq(
        [['Quarnix', nil], ['Quarnix-Hub', nil], %w[Wub product], %w[Zorbel person], ['Zorbel-Hub', nil]]
      )
    end

    # Pasted from a word processor: a manual line break (VT), a page break
    # (FF), NEL and the Unicode line and paragraph separators each end a line,
    # as CR and LF do; CR LF stays one break.
    it 'ends a line at VT, FF, NEL, U+2028 and U+2029 as at CR and LF' do
      actor = importer("Zorbel\vWub\fQuarnix\u0085Zorbel-Hub\u2028Wub-Hub\u2029Quarnix-Hub\r\nZorbel 7")

      expect(actor.call).to be_success
      expect(actor.report.lines.map { |line| [line.number, line.term] }).to eq(
        [[1, 'Zorbel'], [2, 'Wub'], [3, 'Quarnix'], [4, 'Zorbel-Hub'], [5, 'Wub-Hub'], [6, 'Quarnix-Hub'], [7, 'Zorbel 7']]
      )
    end
  end

  describe 'the limit' do
    def numbered_terms(count)
      (1..count).map { |n| "Quarnix #{n}" }
    end

    # Between two terms a line of a space and a zero-width space: blank once cleaned.
    it 'takes 500 lines that are not blank; blank lines do not count and the others keep their numbers' do
      actor = importer("#{numbered_terms(500).join("\n ​\n")}\n\n")

      expect(actor.call).to be_success
      expect(terms_of(organisation).count).to eq(500)
      expect(actor.report.lines.map(&:number)).to eq((1..999).step(2).to_a)
    end

    # The 501st line is invalid: the limit counts lines, not terms.
    it 'refuses 501 lines that are not blank as a whole, and writes nothing' do
      result = importer([*numbered_terms(500), ';product'].join("\n")).call

      expect(result).not_to be_success
      expect(result.code).to eq(:too_many_lines)
      expect(terms_of(organisation).count).to eq(0)
    end

    it 'refuses 501 lines in a dry run too' do
      actor = importer(numbered_terms(501).join("\n"), dry_run: true)

      expect(actor.call.code).to eq(:too_many_lines)
      expect(actor.report).to be_nil
      expect(terms_of(organisation).count).to eq(0)
    end

    it 'refuses a text without a line that is not blank' do
      expect(importer(" \n​\n\t\r\n").call.code).to eq(:empty)
      expect(importer(nil).call.code).to eq(:empty)
    end
  end

  describe 'duplicates in the list' do
    it 'are lines of a form already in the list: the first spelling wins' do
      actor = importer("ZorBel Hub;product\nzorbel hub\nZorbel​ Hub;company\nZorbel  Hub\nWub")

      expect(actor.call).to be_success
      expect(terms_of(organisation).order(:normalized_term).pluck(:term, :category))
        .to eq([['Wub', nil], ['ZorBel Hub', 'product']])
      # The category of a duplicate line is dropped (line 3).
      expect(actor.report.lines.map { |line| [line.number, line.term, line.verdict, line.category_applied] }).to eq(
        [[1, 'ZorBel Hub', :new, true], [2, 'zorbel hub', :duplicate, false], [3, 'Zorbel Hub', :duplicate, false],
         [4, 'Zorbel Hub', :duplicate, false], [5, 'Wub', :new, false]]
      )
      expect(actor.report.counts).to eq(counts(new: 2, created: 2, duplicate: 3))
    end
  end

  describe 'terms the glossary has' do
    it 'skips a term of each status and counts it; a rejected one stays rejected' do
      create(:glossary_term, organisation: organisation, term: 'Zorbel')
      create(:glossary_term, :proposed, organisation: organisation, term: 'Wub')
      create(:glossary_term, :rejected, organisation: organisation, term: 'Quarnix')
      actor = importer("ZORBEL\nwub\nQuarnix\nZorbel-Hub")

      expect(actor.call).to be_success
      expect(actor.report.lines.map { |line| [line.term, line.verdict, line.existing_status] }).to eq(
        [['ZORBEL', :existing, 'confirmed'], ['wub', :existing, 'proposed'], ['Quarnix', :rejected, 'rejected'],
         ['Zorbel-Hub', :new, nil]]
      )
      # Spelling and status as they were; only the new term is added.
      expect(terms_of(organisation).order(:normalized_term).pluck(:term, :status))
        .to eq([%w[Quarnix rejected], %w[Wub proposed], %w[Zorbel confirmed], %w[Zorbel-Hub confirmed]])
      expect(actor.report.counts).to eq(counts(new: 1, created: 1, existing: 2, rejected: 1))
    end

    it 'gives a term without a category the category of its line, with manage_glossary' do
      create(:glossary_term, organisation: organisation, term: 'Zorbel')
      create(:glossary_term, organisation: organisation, term: 'Wub', category: 'company')
      create(:glossary_term, :rejected, organisation: organisation, term: 'Quarnix')
      actor = importer("zorbel;product\nWub;product\nQuarnix;place")

      expect(actor.call).to be_success
      # A category a term has stays; a rejected term stays rejected.
      expect(terms_of(organisation).order(:normalized_term).pluck(:term, :category, :status))
        .to eq([%w[Quarnix place rejected], %w[Wub company confirmed], %w[Zorbel product confirmed]])
      expect(actor.report.lines.map(&:category_applied)).to eq([true, false, true])
      expect(actor.report.counts).to eq(counts(existing: 2, rejected: 1, categorized: 2))
    end

    it 'leaves a term without a category as it is with only view_glossary' do
      term = create(:glossary_term, organisation: organisation, term: 'Zorbel')
      actor = importer('Zorbel;product', user: viewer)

      expect(actor.call).to be_success
      expect(term.reload.slice(:category, :lock_version)).to eq('category' => nil, 'lock_version' => 0)
      expect(actor.report.lines.map(&:category_applied)).to eq([false])
      expect(actor.report.counts).to eq(counts(existing: 1))
    end
  end

  describe 'the category of a line' do
    it 'is a key, or a display name in German or English, in any case; an unknown one is none' do
      text = [
        'Zorbel 1;product',
        "Zorbel 2;#{category_name(:company, :de)}",
        "Zorbel 3;#{category_name(:domain, :en)}",
        "Zorbel 4;#{category_name(:place, :de).upcase}",
        "Zorbel 5; #{category_name(:foreign, :en).downcase} ",
        'Zorbel 6;PRODUCT',
        'Zorbel 7;Planet',
        'Zorbel 8;'
      ].join("\n")
      actor = importer(text)

      expect(actor.call).to be_success
      expected = ['product', 'company', 'domain', 'place', 'foreign', 'product', nil, nil]
      expect(actor.report.lines.map(&:category)).to eq(expected)
      expect(terms_of(organisation).order(:normalized_term).pluck(:category)).to eq(expected)
      expect(actor.report.counts).to eq(counts(new: 8, created: 8))
    end

    # The keys go first: a display name that reads like the key of another
    # category never takes that key over. Here both names of foreign read
    # "Product". foreign is the last category and English the last language,
    # so its name is the last one read: if a later name won, this one would.
    it 'is the category of a key, also where the display name of another one reads like it' do
      allow(I18n).to receive(:t).and_wrap_original do |original, key = nil, **options|
        stubbed = key == 'foreign' && options[:scope] == described_class::CATEGORY_SCOPE
        stubbed ? 'Product' : original.call(key, **options)
      end
      actor = importer("Zorbel;product\nWub;PRODUCT")

      expect(actor.call).to be_success
      expect(I18n).to have_received(:t).with('foreign', hash_including(scope: described_class::CATEGORY_SCOPE)).at_least(:once)
      expect(actor.report.lines.map(&:category)).to eq(%w[product product])
    end
  end

  describe 'invalid lines' do
    it 'are a blank term and one over the maximum length; nothing is written for them' do
      longest = 'Q' * GlossaryTerm::MAX_LENGTH
      actor = importer(";product\n#{'Z' * (GlossaryTerm::MAX_LENGTH + 1)}\n#{longest}")

      expect(actor.call).to be_success
      expect(actor.report.lines.map { |line| [line.number, line.verdict, line.term] })
        .to eq([[1, :invalid, nil], [2, :invalid, nil], [3, :new, longest]])
      expect(terms_of(organisation).pluck(:term)).to eq([longest])
      expect(actor.report.counts).to eq(counts(invalid: 2, new: 1, created: 1))
    end
  end

  describe 'a dry run' do
    it 'writes nothing and reports what the import of the same text then does' do
      uncategorized = create(:glossary_term, organisation: organisation, term: 'Zorbel')
      create(:glossary_term, :rejected, organisation: organisation, term: 'Quarnix')
      text = "Zorbel;product\nWub;company\nwub\nQuarnix\n;place\nZorbel-Hub"

      dry = importer(text, dry_run: true)
      expect(dry.call).to be_success
      expect(terms_of(organisation).count).to eq(2)
      expect(uncategorized.reload.slice(:category, :lock_version)).to eq('category' => nil, 'lock_version' => 0)
      expect(dry.report.counts)
        .to eq(counts(new: 2, created: 2, existing: 1, rejected: 1, duplicate: 1, invalid: 1, categorized: 1))

      real = importer(text)
      expect(real.call).to be_success
      expect(real.report).to eq(dry.report)
      expect(terms_of(organisation).count).to eq(4)
      expect(uncategorized.reload.category).to eq('product')
    end
  end

  # Someone saves the same term between the read of the glossary and the
  # insert: the read misses it, the insert meets it.
  describe 'a term created at the same moment by someone else' do
    it 'counts as existing when the validation sees it' do
      other = create(:glossary_term, organisation: organisation, term: 'Wub')
      allow_any_instance_of(described_class).to receive(:existing_terms).and_return({})
      actor = importer("Wub\nZorbel")

      expect(actor.call).to be_success
      expect(actor.report.lines.map { |line| [line.term, line.verdict, line.existing_status] })
        .to eq([['Wub', :existing, 'confirmed'], ['Zorbel', :new, nil]])
      expect(terms_of(organisation).where(normalized_term: 'wub').pluck(:id)).to eq([other.id])
      expect(actor.report.counts).to eq(counts(existing: 1, new: 1, created: 1))
    end

    it 'counts as existing when the unique index reports it, and the import goes on' do
      other = create(:glossary_term, organisation: organisation, term: 'Wub')
      allow_any_instance_of(described_class).to receive(:existing_terms).and_return({})
      allow_any_instance_of(GlossaryTerm).to receive(:term_not_taken)
      actor = importer("Wub\nZorbel")

      expect(actor.call).to be_success
      expect(actor.report.lines.map { |line| [line.term, line.verdict, line.existing_status] })
        .to eq([['Wub', :existing, 'confirmed'], ['Zorbel', :new, nil]])
      expect(terms_of(organisation).order(:normalized_term).pluck(:term)).to eq(%w[Wub Zorbel])
      expect(terms_of(organisation).find_by(normalized_term: 'wub').id).to eq(other.id)
      expect(actor.report.counts).to eq(counts(existing: 1, new: 1, created: 1))
    end

    # Found only at its insert, after the locks (the lock order): it is not
    # locked, so it keeps the category it has and the line's is dropped.
    it 'keeps its own category, without the one of the line' do
      other = create(:glossary_term, organisation: organisation, term: 'Wub')
      allow_any_instance_of(described_class).to receive(:existing_terms).and_return({})
      actor = importer("Wub;product\nZorbel;place")

      expect(actor.call).to be_success
      expect(actor.report.lines.map { |line| [line.term, line.verdict, line.category_applied] })
        .to eq([['Wub', :existing, false], ['Zorbel', :new, true]])
      expect(other.reload.slice(:category, :lock_version)).to eq('category' => nil, 'lock_version' => 0)
      expect(actor.report.counts).to eq(counts(existing: 1, new: 1, created: 1))
    end
  end

  # Review round 1 of #128: the one lock order of the glossary writes
  # (Glossary::TermLock, the term row first). An import that inserted its new
  # terms first held their index entries while it waited for the lock of a
  # term it gives a category; a rename of that term into one of the new
  # spellings waited for such an entry, and PostgreSQL aborted one of the two.
  # The same case with two connections is the last group of this file.
  describe 'the lock order' do
    it 'locks the terms it gives a category in one statement by id, before it inserts a new term' do
      create(:glossary_term, organisation: organisation, term: 'Zorbel')
      create(:glossary_term, organisation: organisation, term: 'Quarnix')
      statements = []
      callback = ->(*, payload) { statements << payload[:sql] }

      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
        expect(importer("Wub\nZorbel;product\nQuarnix;place").call).to be_success
      end

      locking = ->(sql) { sql.include?('FROM "glossary_terms"') && sql.include?('FOR UPDATE') }
      lock = statements.index(&locking)
      insert = statements.index { |sql| sql.start_with?('INSERT INTO "glossary_terms"') }
      expect(statements.count(&locking)).to eq(1)
      expect(statements[lock]).to include('ORDER BY "glossary_terms"."id" ASC')
      expect(insert).not_to be_nil
      expect(lock).to be < insert
    end

    # Two imports of overlapping lists then wait for each other at their first
    # common term, instead of each holding a term the other one waits for. The
    # lines are in neither that order nor the order of their spelling.
    it 'inserts the new terms in the order of their compared form, not of the lines' do
      inserted = []
      callback = lambda do |*, payload|
        next unless payload[:sql].start_with?('INSERT INTO "glossary_terms"')

        inserted << payload[:binds].find { |bind| bind.name == 'normalized_term' }.value_for_database
      end

      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
        expect(importer("Zorbel\nWub\nQuarnix-Hub\nquarnix").call).to be_success
      end

      expect(inserted).to eq(%w[quarnix quarnix-hub wub zorbel])
    end
  end

  # Someone changes a term between the read of the glossary and the lock that
  # gives it a category: the import works on the row as it is stored under
  # the lock. Quarnix shows that the other terms still get theirs.
  describe 'a term changed by someone else before the lock' do
    [%w[confirmed rejected], %w[rejected confirmed]].each do |before_status, after_status|
      [nil, 'company'].each do |category_before_lock|
        [false, true].each do |dry_run|
          it "reports #{after_status} after #{before_status}, with category #{category_before_lock.inspect} before the lock (dry_run: #{dry_run})" do
            term = create(:glossary_term, organisation: organisation, term: 'Zorbel', status: before_status)
            actor = importer("Zorbel;product\nzorbel;place", dry_run: dry_run)
            # Change the stored row after classification's read. This change
            # is in the import's transaction, so a dry run rolls it back too.
            allow(actor).to receive(:existing_terms).and_wrap_original do |original, *arguments|
              original.call(*arguments).tap { term.update!(status: after_status, category: category_before_lock) }
            end

            expect(actor.call).to be_success
            verdict = after_status == 'rejected' ? :rejected : :existing
            categorized = category_before_lock.nil?
            expect(actor.report.lines.map { |line| [line.verdict, line.existing_status, line.category_applied] })
              .to eq([[verdict, after_status, categorized], [:duplicate, nil, false]])
            expect(actor.report.counts).to eq(counts(**{ verdict => 1, duplicate: 1, categorized: categorized ? 1 : 0 }))
            expected_state = if dry_run
                               { 'status' => before_status, 'category' => nil, 'lock_version' => 0 }
                             else
                               { 'status' => after_status, 'category' => category_before_lock || 'product', 'lock_version' => categorized ? 2 : 1 }
                             end
            expect(term.reload.slice(:status, :category, :lock_version)).to eq(expected_state)
          end
        end
      end
    end

    it 'still categorizes a spelling change that keeps the same normalized form' do
      term = create(:glossary_term, organisation: organisation, term: 'Zorbel Hub')
      actor = importer('Zorbel Hub;product')
      allow(actor).to receive(:existing_terms).and_wrap_original do |original, *arguments|
        original.call(*arguments).tap { term.update!(term: '  ZORBEL   HUB  ') }
      end

      expect(actor.call).to be_success
      expect(term.reload.slice(:term, :category)).to eq('term' => 'ZORBEL HUB', 'category' => 'product')
      expect(actor.report.lines.map(&:category_applied)).to eq([true])
      expect(actor.report.counts).to eq(counts(existing: 1, categorized: 1))
    end

    it 'keeps a category set in the meantime and leaves out a term deleted in the meantime' do
      changed = create(:glossary_term, organisation: organisation, term: 'Zorbel')
      deleted = create(:glossary_term, organisation: organisation, term: 'Wub')
      create(:glossary_term, organisation: organisation, term: 'Quarnix')
      actor = importer("Zorbel;product\nWub;product\nQuarnix;place")
      # Right after the read of the glossary, the last statement before the lock.
      allow(actor).to receive(:existing_terms).and_wrap_original do |original, *arguments|
        original.call(*arguments).tap do
          GlossaryTerm.where(id: changed.id).update_all(category: 'company')
          GlossaryTerm.where(id: deleted.id).delete_all
        end
      end

      expect(actor.call).to be_success
      expect(terms_of(organisation).order(:normalized_term).pluck(:term, :category))
        .to eq([%w[Quarnix place], %w[Zorbel company]])
      expect(actor.report.lines.map(&:category_applied)).to eq([false, false, true])
      expect(actor.report.counts).to eq(counts(existing: 3, categorized: 1))
    end
  end

  describe 'another organisation' do
    it 'neither blocks the import nor is touched by it' do
      foreign = ActsAsTenant.with_tenant(other_organisation) do
        create(:glossary_term, organisation: other_organisation, term: 'Zorbel')
      end
      actor = importer('zorbel;product')

      expect(actor.call).to be_success
      expect(actor.report.lines.map(&:verdict)).to eq([:new])
      expect(terms_of(organisation).pluck(:term, :category)).to eq([%w[zorbel product]])
      expect(terms_of(other_organisation).sole.slice(:id, :term, :category, :lock_version))
        .to eq('id' => foreign.id, 'term' => 'Zorbel', 'category' => nil, 'lock_version' => 0)
    end

    # A tenant hides the other organisation's term by itself: the one set
    # above, and the one the actor sets for itself ('with a foreign tenant
    # set'). With no current tenant and the actor's own left out, only its
    # own organisation filter keeps the term out.
    it 'is kept out by the actor itself, without a current tenant' do
      foreign = ActsAsTenant.with_tenant(other_organisation) do
        create(:glossary_term, organisation: other_organisation, term: 'Zorbel')
      end
      actor = importer('zorbel;product')
      allow(ActsAsTenant).to receive(:with_tenant).and_wrap_original do |_original, _tenant, &block|
        block.call
      end

      expect(ActsAsTenant.without_tenant { actor.call }).to be_success
      expect(actor.report.lines.map(&:verdict)).to eq([:new])
      expect(terms_of(organisation).pluck(:term, :category)).to eq([%w[zorbel product]])
      expect(terms_of(other_organisation).sole.slice(:id, :term, :category, :lock_version))
        .to eq('id' => foreign.id, 'term' => 'Zorbel', 'category' => nil, 'lock_version' => 0)
    end
  end

  # Review round 2 of #128: the caller's tenant does not move the import. Under
  # another tenant the scope hid Zorbel, acts_as_tenant wrote the new terms into
  # that tenant, and the manager's role was read there, so they came in as
  # proposals.
  describe 'with a foreign tenant set' do
    it 'imports into the given organisation as its member, leaves the other one untouched and gives the tenant back' do
      create(:glossary_term, organisation: organisation, term: 'Zorbel')
      foreign = ActsAsTenant.with_tenant(other_organisation) do
        create(:glossary_term, organisation: other_organisation, term: 'Quarnix')
      end
      actor = importer("Zorbel;product\nWub")
      tenant_after = nil

      result = ActsAsTenant.with_tenant(other_organisation) do
        actor.call.tap { tenant_after = ActsAsTenant.current_tenant }
      end

      expect(result).to be_success
      expect(actor.report.lines.map { |line| [line.term, line.verdict, line.category_applied] })
        .to eq([['Zorbel', :existing, true], ['Wub', :new, false]])
      expect(terms_of(organisation).order(:normalized_term).pluck(:term, :category, :status, :created_by_id))
        .to eq([['Wub', nil, 'confirmed', manager.id], ['Zorbel', 'product', 'confirmed', nil]])
      expect(terms_of(other_organisation).pluck(:id, :term, :category, :lock_version)).to eq([[foreign.id, 'Quarnix', nil, 0]])
      expect(tenant_after).to eq(other_organisation)
    end
  end
end

# Review round 1 of #128, with two connections and committed rows: a rename of
# Wub to Quarnix holds the row lock of Wub (Glossary::TermLock) while an
# import of "Quarnix" and "Wub;product" runs. With its inserts first, the
# import held the index entry of Quarnix and waited for Wub, the rename waited
# for that entry, and PostgreSQL aborted one of the two
# (ActiveRecord::Deadlocked). With its locks first, the import waits for the
# rename, then refuses the changed spelling instead of giving it the old
# spelling's category. Earlier category updates roll back too. A group of
# its own: the before hook of the group above
# creates its organisation inside the transaction this group has to leave.
RSpec.describe Actors::ImportGlossaryTerms, 'beside a rename of one of its terms', type: :service do
  self.use_transactional_tests = false

  before do
    DatabaseCleaner.clean
    DatabaseCleaner.strategy = :truncation
    DatabaseCleaner.start
    Prosopite.pause
  end

  after do
    Prosopite.resume
    ActsAsTenant.current_tenant = nil
  end

  # A deadlock is the answer of the thread, so the example names it.
  def in_thread(organisation, &block)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { ActsAsTenant.with_tenant(organisation, &block) }
    rescue ActiveRecord::Deadlocked => e
      e
    end
  end

  def wait_for_lock_waiter
    Timeout.timeout(10) do
      sleep 0.01 until ActiveRecord::Base.connection.select_value(
        "SELECT count(*) FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND datname = current_database()"
      ).to_i.positive?
    end
  end

  [false, true].each do |dry_run|
    it "rolls back a renamed spelling without deadlocking (dry_run: #{dry_run})" do
      organisation = create(:organisation)
      ActsAsTenant.current_tenant = organisation
      role = create(:role, organisation: organisation)
      create(:permission, role: role, category: 'glossary', action: 'manage_glossary', allowed: true)
      manager = create(:user, first_name: 'Anna', last_name: 'Beispiel')
      create(:membership, user: manager, organisation: organisation, role: role)
      wub = create(:glossary_term, organisation: organisation, term: 'Wub')
      zorbel = create(:glossary_term, organisation: organisation, term: 'Zorbel')
      import = described_class.new(organisation: organisation, text: "Zorbel;place\nQuarnix;company\nWub;product\nZorbel Hub",
                                   current_user: manager, dry_run: dry_run)
      held = Queue.new
      release = Queue.new
      # The rename stops right after its lock, until the import waits for a lock.
      allow(Glossary::TermLock).to receive(:call).and_wrap_original do |original, **arguments|
        original.call(**arguments).tap do
          held << true
          release.pop
        end
      end

      renaming = in_thread(organisation) do
        Actors::SaveGlossaryTerm.call(organisation: organisation, params: { term: 'Quarnix' }, current_user: manager, id: wub.id)
      end
      Timeout.timeout(10) { held.pop }
      importing = in_thread(organisation) { import.call }
      wait_for_lock_waiter
      release << true
      answers = Timeout.timeout(10) { [renaming.value, importing.value] }

      expect(answers.grep(ActiveRecord::Deadlocked).map(&:message)).to eq([])
      expect(answers.first).to be_success
      expect(answers.last).not_to be_success
      expect(answers.last.code).to eq(:stale_object)
      expect(answers.last.errors).to eq([I18n.t('services.actors.stale_object')])
      expect(import.report).to be_nil
      expect(wub.reload.slice(:term, :category, :lock_version)).to eq('term' => 'Quarnix', 'category' => nil, 'lock_version' => 1)
      expect(zorbel.reload.slice(:category, :lock_version)).to eq('category' => nil, 'lock_version' => 0)
      expect(GlossaryTerm.where(organisation_id: organisation.id).pluck(:id)).to match_array([wub.id, zorbel.id])
    ensure
      release&.push(true)
      [renaming, importing].compact.each { |thread| thread.join(5) || thread.kill }
    end
  end
end
