# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Tickets::Filter do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  # The query touches tenant-scoped models. Set the tenant in a before hook, not
  # an around block — around interferes with acts_as_tenant's own per-example reset.
  before { ActsAsTenant.current_tenant = organisation }

  def ticket(**attrs)
    create(:ticket, **{ project: project, organisation: organisation, creator: user }.merge(attrs))
  end

  def tag_ticket(record, name)
    tag = create(:tag, name: name, organisation: organisation)
    create(:tagging, tag: tag, taggable: record)
    record
  end

  def tag_with(record, *tags)
    tags.each { |tag| create(:tagging, tag: tag, taggable: record) }
    record
  end

  def filter(params)
    described_class.new(params, current_user: user)
  end

  describe '#filtered' do
    it 'returns everything when no filter keys are present' do
      a = ticket
      b = ticket
      expect(filter({}).filtered(project.tickets)).to contain_exactly(a, b)
    end

    it 'filters by status case-insensitively' do
      open_ticket = ticket(custom_attributes: { 'status' => 'Open' })
      ticket(custom_attributes: { 'status' => 'done' })
      expect(filter(status: 'open').filtered(project.tickets)).to contain_exactly(open_ticket)
    end

    it 'resolves assignee "me" to the current user' do
      mine = ticket
      mine.assignees << user
      ticket # unassigned
      expect(filter(assignee: 'me').filtered(project.tickets)).to contain_exactly(mine)
    end

    it 'filters by tag name' do
      tagged = tag_ticket(ticket, 'bug')
      ticket # untagged
      expect(filter(tag: 'bug').filtered(project.tickets)).to contain_exactly(tagged)
    end

    it 'ignores an unparseable date range rather than erroring' do
      a = ticket
      expect { filter(from: 'not-a-date').filtered(project.tickets).to_a }.not_to raise_error
      expect(filter(from: 'not-a-date').filtered(project.tickets)).to contain_exactly(a)
    end

    # Date.parse takes any number of digits for the year; PostgreSQL stores four.
    # A bound it cannot store used to reach the query and answer a 500.
    it 'ignores a date bound PostgreSQL cannot store, like any other unusable one' do
      a = ticket
      %w[999999999-01-01 -9999-01-01].each do |value|
        expect(filter(from: value).filtered(project.tickets).to_a).to contain_exactly(a)
        expect(filter(to: value).filtered(project.tickets).to_a).to contain_exactly(a)
      end
    end

    it 'still applies a four-digit date bound' do
      old = ticket
      old.update_columns(updated_at: Time.zone.parse('2026-01-10 12:00'))
      recent = ticket
      recent.update_columns(updated_at: Time.zone.parse('2026-03-10 12:00'))
      expect(filter(from: '2026-02-01').filtered(project.tickets)).to contain_exactly(recent)
      expect(filter(to: '2026-02-01').filtered(project.tickets)).to contain_exactly(old)
    end

    it 'filters by several tags with AND' do
      bug = create(:tag, name: 'bug', organisation: organisation)
      ui = create(:tag, name: 'ui', organisation: organisation)
      both = tag_with(ticket, bug, ui)
      tag_with(ticket, bug)
      expect(filter(tag: %w[bug ui]).filtered(project.tickets)).to contain_exactly(both)
    end
  end

  describe '#ordered' do
    it 'orders by updated_at descending by default' do
      older = ticket
      newer = ticket
      older.update!(updated_at: 2.days.ago)
      newer.update!(updated_at: 1.hour.ago)
      expect(filter({}).ordered(project.tickets).to_a).to eq([newer, older])
    end

    # The tag filter used to GROUP BY the ticket id, and the search's rank column
    # is not in that group: PG::GroupingError, a 500 for q plus tag.
    it 'combines the search with a tag filter' do
      bug = create(:tag, name: 'bug', organisation: organisation)
      match = tag_with(ticket(title: 'Login schlägt fehl'), bug)
      tag_with(ticket(title: 'Datenbank-Migration'), bug)
      ticket(title: 'Login ohne Tag')
      f = filter(q: 'Login', tag: 'bug')
      scope = f.ordered(f.filtered(project.tickets))
      expect(f.paginate(scope).map(&:id)).to eq([match.id])
      expect(f.total(scope)).to eq(1)
    end

    it 'uses full-text search when q is present' do
      match = ticket(title: 'Login schlägt fehl')
      ticket(title: 'Datenbank-Migration')
      ids = filter(q: 'Login').ordered(project.tickets).map(&:id)
      expect(ids).to eq([match.id])
    end
  end

  describe '#total' do
    it 'returns an integer for an ungrouped scope' do
      ticket
      ticket
      expect(filter({}).total(project.tickets)).to eq(2)
    end

    it 'returns the distinct-ticket count for a grouped (tag) scope' do
      tag_ticket(ticket, 'bug')
      ticket # untagged
      scope = filter(tag: 'bug').filtered(project.tickets)
      expect(filter(tag: 'bug').total(scope)).to eq(1)
    end
  end

  describe 'pagination' do
    it 'clamps page to at least 1' do
      expect(filter(page: 0).page).to eq(1)
      expect(filter(page: 3).page).to eq(3)
    end

    it 'defaults and caps per_page' do
      expect(filter({}).per_page).to eq(described_class::DEFAULT_PER_PAGE)
      expect(filter(per_page: 10).per_page).to eq(10)
      expect(filter(per_page: 9_999).per_page).to eq(described_class::MAX_PER_PAGE)
    end

    # A page so far out that the offset leaves PostgreSQL's bigint, and a value
    # that is a list or a hash: both used to raise past the callers into a 500.
    it 'refuses a page no list has and a page or per_page that is no single value' do
      expect { filter(page: '99999999999999999999').page }.to raise_error(ListPaging::InvalidArgument)
      expect { filter(page: ListPaging::MAX_PAGE + 1).page }.to raise_error(ListPaging::InvalidArgument)
      expect(filter(page: ListPaging::MAX_PAGE).page).to eq(ListPaging::MAX_PAGE)
      expect { filter(page: ['1']).page }.to raise_error(ListPaging::InvalidArgument)
      expect { filter(per_page: { 'x' => '1' }).per_page }.to raise_error(ListPaging::InvalidArgument)
    end

    it 'keeps reading a string that is no number the lenient way it always did' do
      expect(filter(page: 'abc').page).to eq(1)
      expect(filter(per_page: 'abc').per_page).to eq(described_class::DEFAULT_PER_PAGE)
    end

    it '#paginate limits and offsets the scope' do
      3.times { ticket }
      page2 = filter(page: 2, per_page: 2)
      expect(page2.paginate(project.tickets.order(:created_at)).size).to eq(1)
    end
  end
end
