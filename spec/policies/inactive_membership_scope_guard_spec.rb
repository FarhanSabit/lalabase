# frozen_string_literal: true

require 'rails_helper'

# Guard for #603: a DEACTIVATED membership yields no rows from any policy scope.
#
# The per-record path refuses such a member on its first line
# (ProjectPolicy#area_access? → active_member_of_record_organisation?). The list
# scopes went through AccessCheck::ProjectAccessService, which did not look at
# membership.active at all, so the same rule answered differently depending on
# which door you came through, and every caller that wanted it right enforced it
# by hand (ChatPolicy::Scope, Lalabase::Tools::Scope, Chats::OwnerBackfill).
# The rule now has ONE owner; this table is what holds it there.
#
# Every cell has BOTH halves. The active member must SEE the row first: without
# that flow anchor an empty result proves nothing, because a broken fixture is
# empty too.
RSpec.describe 'Policy scopes and a deactivated membership', :ci_guard, type: :policy do
  let(:organisation) { create(:organisation) }

  # Declared BEFORE the let! fixtures on purpose: every let! registers a
  # before-hook where it stands, and they run in declaration order, so a tenant
  # set further down would arrive after the records it is meant to stamp.
  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  let(:role) { create(:role, title: 'Standard User', organisation: organisation) }
  let(:user) { create(:user) }
  let!(:membership) { create(:membership, user: user, organisation: organisation, role: role, active: true) }
  let(:project) { create(:project, organisation: organisation) }

  # Reach comes from an explicit per-project grant, not from a role permission:
  # that is the constellation the #602 review probed (a deactivated member whose
  # ProjectPermission rows outlive the deactivation).
  let!(:project_permission) do
    create(:project_permission,
           user: user, project: project,
           tickets_access: :read_only, notes_access: :read_only,
           documents_access: :read_only, meetings_access: :read_only,
           chats_access: :read_only)
  end

  let(:author) { create(:user) }
  let!(:ticket) { create(:ticket, project: project, organisation: organisation) }
  let!(:note) { create(:note, project: project, organisation: organisation, creator: author) }
  let!(:document) { create(:document, project: project, organisation: organisation, creator: author) }
  let!(:meeting) { create(:meeting, project: project, organisation: organisation, creator: author) }
  let!(:post) { create(:post, ticket: ticket, user: author, organisation: organisation) }
  let!(:meeting_analysis) { create(:meeting_analysis, :published, meeting: meeting, organisation: organisation, creator: author) }

  # User#active_member_of_organisation? memoises a TRUE answer per instance
  # (request-level cache). The positive half of every cell would poison it for
  # the negative half, so the second question is asked of a freshly loaded user,
  # which is also what a real request does.
  def rows(policy_scope, model)
    policy_scope.new(User.find(user.id), model).resolve
  end

  {
    'TicketPolicy::Scope' => [TicketPolicy::Scope, Ticket, :ticket],
    'NotePolicy::Scope' => [NotePolicy::Scope, Note, :note],
    'DocumentPolicy::Scope' => [DocumentPolicy::Scope, Document, :document],
    'MeetingPolicy::Scope' => [MeetingPolicy::Scope, Meeting, :meeting],
    'PostPolicy::Scope' => [PostPolicy::Scope, Post, :post],
    'MeetingAnalysisPolicy::Scope' => [MeetingAnalysisPolicy::Scope, MeetingAnalysis, :meeting_analysis],
    'ProjectPolicy::Scope' => [ProjectPolicy::Scope, Project, :project]
  }.each do |label, (policy_scope, model, record_name)|
    it "#{label} drops the row once the membership is deactivated" do
      record = public_send(record_name)

      expect(rows(policy_scope, model)).to include(record),
                                           "flow anchor failed: the ACTIVE member did not see the #{record_name}"

      membership.update!(active: false)

      expect(rows(policy_scope, model)).to be_empty
    end
  end

  # The admin shortcut is the reason the check sits BEFORE it. role_in_organisation
  # does not filter on membership.active, so a deactivated account_admin used to be
  # handed scope.all by every list, no ProjectPermission needed, the widest possible
  # leak of the four. Its own cell, because the standard-member cells above run past
  # the shortcut and would stay green if it were moved back below.
  describe 'a deactivated account_admin' do
    let(:admin_role) { create(:role, title: 'account_admin', organisation: organisation) }
    let(:admin) { create(:user) }
    let!(:admin_membership) { create(:membership, user: admin, organisation: organisation, role: admin_role, active: true) }

    it 'loses the admin shortcut in TicketPolicy::Scope, holding no project permission at all' do
      expect(ProjectPermission.exists?(user: admin)).to be(false)
      expect(TicketPolicy::Scope.new(User.find(admin.id), Ticket).resolve).to include(ticket)

      admin_membership.update!(active: false)

      expect(TicketPolicy::Scope.new(User.find(admin.id), Ticket).resolve).to be_empty
    end
  end

  # The org-wide assistant threads have no project, so they never pass through
  # accessible_project_ids. ChatPolicy::Scope keeps its own check for that branch;
  # this cell is what says so out loud.
  # The people directory has no project either: PersonPolicy::Scope asks the
  # membership itself (PersonPolicy.view_allowed?).
  describe 'PersonPolicy::Scope' do
    let!(:person) { create(:person, organisation: organisation) }

    it 'drops the rows once the membership is deactivated' do
      create(:permission, role: role, category: 'people', action: 'view_people', allowed: true)

      expect(PersonPolicy::Scope.new(User.find(user.id), Person).resolve).to include(person)

      membership.update!(active: false)

      expect(PersonPolicy::Scope.new(User.find(user.id), Person).resolve).to be_empty
    end
  end

  # The glossary (K4a) has no project either: GlossaryPolicy::Scope asks the
  # membership itself (GlossaryPolicy.view_allowed?), for terms and heard forms.
  describe 'GlossaryPolicy::Scope' do
    let!(:term) { create(:glossary_term, organisation: organisation) }
    let!(:correction) { create(:term_correction, organisation: organisation, glossary_term: term, project: project) }

    it 'drops the terms and heard forms once the membership is deactivated' do
      create(:permission, role: role, category: 'glossary', action: 'view_glossary', allowed: true)

      expect(rows(GlossaryPolicy::Scope, GlossaryTerm)).to include(term)
      expect(rows(GlossaryPolicy::Scope, TermCorrection)).to include(correction)

      membership.update!(active: false)

      expect(rows(GlossaryPolicy::Scope, GlossaryTerm)).to be_empty
      expect(rows(GlossaryPolicy::Scope, TermCorrection)).to be_empty
    end
  end

  describe 'ChatPolicy::Scope' do
    let!(:org_thread) { create(:chat, user: user, organisation: organisation) }

    it 'drops an org-wide thread of a deactivated member, without any project involved' do
      allow(organisation).to receive(:code_indexing_enabled?).and_return(true)
      allow(ChatPolicy).to receive(:assistant_gate_open?).and_return(true)

      expect(ChatPolicy::Scope.new(User.find(user.id), Chat).resolve).to include(org_thread)

      membership.update!(active: false)

      expect(ChatPolicy::Scope.new(User.find(user.id), Chat).resolve).to be_empty
    end
  end
end
