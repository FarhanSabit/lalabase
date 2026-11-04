# frozen_string_literal: true

require 'rails_helper'

# Guard: the TWO account-erasure paths keep the same promise.
#
# A person erases their own account through User::DeletionLifecycle
# (AccountDeletionsController -> DeleteAccountService); an operator erases a
# customer's account through Admin::User#soft_delete_and_anonymize!
# (Admin::UsersController#destroy -> the same service). Both are SOFT deletes on
# the same users row, written by two classes that never share a save cycle, so a
# step present on only one of them is silent -- and the admin path is the one the
# operator uses for customers (found 2026-08-24: export archives and private
# meeting analyses survived an admin erasure).
#
# spec/models/admin_twin_concern_parity_guard_spec.rb checks that both classes
# INCLUDE the same concerns. It cannot see whether a hand-written method CALLS
# the same steps, which is the gap this file closes: every example below runs
# against both paths, and the last group compares the users row they leave
# behind column by column.
#
# Deliberate overlap: the ::User-path examples for exports, analyses and chats
# also live in spec/models/user/deletion_lifecycle_{export_purge,meeting_analyses,
# chats}_spec.rb, each deeper on its own subject. Those stay as the in-depth
# guards of one path; this file is the only one that runs every step on BOTH.
RSpec.describe 'Account erasure path parity', type: :model do
  include ActiveSupport::Testing::TimeHelpers

  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:user) { create(:user) }
  let(:colleague) { create(:user, organisation: organisation) }
  let(:meeting) { create(:meeting, organisation: organisation, project: project, creator: colleague) }

  before do
    ActiveJob::Base.queue_adapter = :test
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation,
                        role: create(:role, organisation: organisation), active: true)
  end

  after { ActsAsTenant.current_tenant = nil }

  # `record` is the object whose soft_delete_and_anonymize! runs; `last_step` is
  # the final write inside its transaction, stubbed to raise in the rollback
  # examples (soft_delete! on ::User, update_columns on Admin::User).
  shared_examples 'erases the personal data of the account' do
    describe 'GDPR export archives (plain-text snapshots with name, email, IPs)' do
      it 'destroys the export rows' do
        # Old failed export FIRST: it does not count towards the request
        # throttle, so the completed one afterwards passes the 24h validation.
        create(:user_data_export, :failed, user: user, created_at: 2.days.ago)
        create(:user_data_export, :completed, user: user)

        expect { record.soft_delete_and_anonymize! }
          .to change { UserDataExport.where(user_id: user.id).count }.from(2).to(0)
      end

      it 'enqueues the archive blob purge' do
        create(:user_data_export, :completed, user: user)

        expect { record.soft_delete_and_anonymize! }.to have_enqueued_job(ActiveStorage::PurgeJob)
      end

      it "leaves a colleague's export alone" do
        theirs = create(:user_data_export, :completed, user: colleague)

        record.soft_delete_and_anonymize!

        expect(UserDataExport.where(id: theirs.id).count).to eq(1)
      end

      # IO does not belong inside the transaction: the row goes with the
      # transaction, the blob only AFTER commit. If the erasure is moved outside
      # the transaction, or the purge fires inline, this example leaves either a
      # purged archive behind a user who was never erased or a job for a row
      # that still exists.
      it 'keeps rows and blob when a later step raises' do
        export = create(:user_data_export, :completed, user: user)
        allow(record).to receive(last_step).and_raise(ActiveRecord::ActiveRecordError, 'boom')

        expect { record.soft_delete_and_anonymize! }.to raise_error(ActiveRecord::ActiveRecordError, 'boom')

        expect(UserDataExport.where(id: export.id).count).to eq(1)
        expect(ActiveStorage::PurgeJob).not_to have_been_enqueued
      end
    end

    describe 'profile picture (a face is dead PII once the account is erased)' do
      # Soft deletes never fire the attachment's dependent purge, so
      # PersonalDataErasure#erase_avatar! must purge explicitly — on BOTH
      # paths, which is exactly what this shared example enforces. Queried via
      # ActiveStorage::Attachment because Admin::User deliberately has no
      # avatar association (user.rb).
      it 'enqueues the avatar blob purge and detaches it' do
        user.avatar.attach(
          io: Rails.root.join('spec/fixtures/files/test_avatar.png').open,
          filename: 'avatar.png', content_type: 'image/png'
        )
        user.save!

        expect { record.soft_delete_and_anonymize! }.to have_enqueued_job(ActiveStorage::PurgeJob)
        expect(ActiveStorage::Attachment.where(record_type: 'User', record_id: user.id, name: 'avatar'))
          .to be_empty
      end

      it "leaves a colleague's avatar alone" do
        colleague.avatar.attach(
          io: Rails.root.join('spec/fixtures/files/test_avatar.png').open,
          filename: 'avatar.png', content_type: 'image/png'
        )
        colleague.save!

        record.soft_delete_and_anonymize!

        expect(colleague.reload.avatar).to be_attached
      end
    end

    describe 'meeting analyses' do
      it 'destroys the PRIVATE analyses (their only permitted reader is gone)' do
        private_analysis = create(:meeting_analysis, meeting: meeting, creator: user, is_private: true)

        expect { record.soft_delete_and_anonymize! }
          .to change { MeetingAnalysis.where(id: private_analysis.id).count }.from(1).to(0)
      end

      it 'keeps PUBLISHED analyses but no longer points them at the erased account' do
        published = create(:meeting_analysis, :published, meeting: meeting, creator: user,
                                                          prompt_title: 'Org-Inhalt', content: 'bleibt')
        # Seed past the validation callback (which nulls visible_to_user on
        # public rows anyway): without this the be_nil below is true before the
        # erasure runs and asserts nothing about the update_all.
        published.update_column(:visible_to_user_id, user.id)

        record.soft_delete_and_anonymize!

        published.reload
        expect(published.creator_id).to be_nil
        expect(published.visible_to_user_id).to be_nil
        expect(published.prompt_title).to eq('Org-Inhalt')
        expect(published.content).to eq('bleibt')
      end

      it "leaves a colleague's private analysis alone" do
        theirs = create(:meeting_analysis, meeting: meeting, creator: colleague, is_private: true)

        record.soft_delete_and_anonymize!

        theirs.reload
        expect(theirs.creator_id).to eq(colleague.id)
        expect(theirs.is_private).to be(true)
      end

      # A person spans organisations and the erasure is not tenant-scoped. Without
      # the ActsAsTenant escape this would finish "successfully" having cleaned
      # exactly the organisation that happened to be the current tenant.
      it 'reaches the analyses in an organisation that is not the current tenant' do
        elsewhere = ActsAsTenant.with_tenant(other_organisation) do
          other_project = create(:project, organisation: other_organisation)
          other_meeting = create(:meeting, organisation: other_organisation, project: other_project,
                                           creator: create(:user, organisation: other_organisation))
          create(:meeting_analysis, meeting: other_meeting, creator: user, is_private: true)
        end

        record.soft_delete_and_anonymize!

        expect(ActsAsTenant.without_tenant { MeetingAnalysis.where(id: elsewhere.id).count }).to eq(0)
      end
    end

    # The chat examples proper live in spec/models/user/deletion_lifecycle_chats_spec.rb;
    # these two only pin that the step is reached through the shared entry point.
    describe 'own chat threads (PersonalChatErasure via the same entry point)' do
      it 'destroys the threads the account owned' do
        own = create(:chat, organisation: organisation, user: user)

        record.soft_delete_and_anonymize!

        expect(ActsAsTenant.without_tenant { Chat.where(id: own.id).count }).to eq(0)
      end

      it "leaves a colleague's thread alone" do
        theirs = create(:chat, organisation: organisation, user: colleague)

        record.soft_delete_and_anonymize!

        expect(ActsAsTenant.without_tenant { Chat.where(id: theirs.id).count }).to eq(1)
      end
    end

    describe 'private ticket posts (the E17 pattern the analyses copy)' do
      let(:ticket) { create(:ticket, project: project, organisation: organisation) }

      it 'destroys the private posts and keeps public ones as org content' do
        private_post = create(:post, ticket: ticket, organisation: organisation, user: user, is_private: true)
        public_post = create(:post, ticket: ticket, organisation: organisation, user: user, is_private: false)

        record.soft_delete_and_anonymize!

        ActsAsTenant.without_tenant do
          expect(Post.where(id: private_post.id)).not_to exist
          expect(Post.where(id: public_post.id)).to exist
        end
      end

      it "leaves a colleague's private post alone" do
        theirs = create(:post, ticket: ticket, organisation: organisation, user: colleague, is_private: true)

        record.soft_delete_and_anonymize!

        expect(ActsAsTenant.without_tenant { Post.where(id: theirs.id).count }).to eq(1)
      end
    end

    describe 'personal tasks (strictly private to the owner)' do
      it "deletes them and leaves a colleague's task alone" do
        own = create(:personal_task, user: user, organisation: organisation)
        theirs = create(:personal_task, user: colleague, organisation: organisation)

        record.soft_delete_and_anonymize!

        ActsAsTenant.without_tenant do
          expect(PersonalTask.where(id: own.id)).not_to exist
          expect(PersonalTask.where(id: theirs.id)).to exist
        end
      end
    end

    # The erasure runs BEFORE the memberships go: removing a membership drops
    # the link (PersonLinkRelease), and without the link the step would find
    # nothing and leave the row behind as a contact with the person's data.
    describe 'people directory rows linked to the account' do
      it 'deletes the linked rows in every organisation and keeps the unlinked ones' do
        create(:membership, user: user, organisation: other_organisation)
        linked = create(:person, organisation: organisation, user: user, phone: '1')
        elsewhere = ActsAsTenant.with_tenant(other_organisation) do
          create(:person, organisation: other_organisation, user: user)
        end
        namesake = create(:person, organisation: organisation, name: linked.name)

        record.soft_delete_and_anonymize!

        ActsAsTenant.without_tenant do
          expect(Person.where(id: [linked.id, elsewhere.id])).not_to exist
          expect(Person.where(id: namesake.id)).to exist
        end
      end
    end

    # K4a: the heard form stays as knowledge of the organisation, only the
    # speaker link to the erased account goes (plan §3.3, like a deleted person).
    describe 'glossary heard forms the account spoke' do
      it 'clears the speaker in every organisation and keeps the heard forms' do
        create(:membership, user: user, organisation: other_organisation)
        term = create(:glossary_term, organisation: organisation)
        spoken = create(:term_correction, organisation: organisation, glossary_term: term, user: user)
        spoken_elsewhere = ActsAsTenant.with_tenant(other_organisation) do
          create(:term_correction, organisation: other_organisation, user: user)
        end
        by_colleague = create(:term_correction, organisation: organisation, glossary_term: term, user: colleague)

        record.soft_delete_and_anonymize!

        ActsAsTenant.without_tenant do
          expect(TermCorrection.where(id: [spoken.id, spoken_elsewhere.id]).pluck(:user_id)).to eq([nil, nil])
          expect(TermCorrection.find(by_colleague.id).user_id).to eq(colleague.id)
        end
      end
    end

    describe 'personal access tokens (access revocation)' do
      it 'revokes the tokens so they stop authenticating' do
        raw = create(:personal_access_token, user: user, organisations: [organisation]).token
        expect(PersonalAccessToken.authenticate(raw)).to be_present

        record.soft_delete_and_anonymize!

        expect(PersonalAccessToken.authenticate(raw)).to be_nil
      end

      it "leaves a colleague's token working" do
        raw = create(:personal_access_token, user: colleague, organisations: [organisation]).token

        record.soft_delete_and_anonymize!

        expect(PersonalAccessToken.authenticate(raw)).to be_present
      end
    end

    describe 'user_activities written BY the erasure' do
      # The erasure must not record the address it is removing:
      # UserTrackable#track_email_change would store old_email in the activity
      # metadata, on the erased account, at the moment of erasure.
      it 'writes no activity carrying the erased address' do
        original_email = user.email

        record.soft_delete_and_anonymize!

        rows = UserActivity.where(user_id: user.id)
        expect(rows.select { |a| a.metadata.to_json.include?(original_email) }).to be_empty
      end
    end

    it 'still erases the users row itself' do
      record.soft_delete_and_anonymize!

      row = User.with_deleted.find(user.id)
      expect(row.email).to end_with("@#{User::DeletionLifecycle::ANONYMIZED_EMAIL_DOMAIN}")
      expect(row.deleted_at).to be_present
    end
  end

  context 'when the person erases their own account (User::DeletionLifecycle)' do
    let(:record) { user }
    let(:last_step) { :soft_delete! }

    include_examples 'erases the personal data of the account'
  end

  # Admin::UsersController#destroy goes through DeleteAccountService on an
  # Admin::User, not on User. Its soft_delete_and_anonymize! is a SEPARATE
  # implementation (see the header of app/models/user/deletion_lifecycle.rb).
  context 'when an operator erases the account (Admin::User)' do
    let(:record) { ActsAsTenant.without_tenant { Admin::User.find(user.id) } }
    let(:last_step) { :update_columns }

    include_examples 'erases the personal data of the account'

    # The backend runs with NO ambient tenant (Admin::ApplicationController sets
    # none, require_tenant is true): a step that touches a tenant-scoped model
    # outside its ActsAsTenant.without_tenant escape raises only there. The
    # shared examples above run under the before-hook's tenant and cannot see
    # that.
    it 'erases everything without an ambient tenant, the way the backend runs' do
      export = create(:user_data_export, :completed, user: user)
      analysis = create(:meeting_analysis, meeting: meeting, creator: user, is_private: true)
      chat = create(:chat, organisation: organisation, user: user)
      task = create(:personal_task, user: user, organisation: organisation)
      ActsAsTenant.current_tenant = nil

      expect { record.soft_delete_and_anonymize! }.not_to raise_error

      ActsAsTenant.without_tenant do
        expect(UserDataExport.where(id: export.id)).not_to exist
        expect(MeetingAnalysis.where(id: analysis.id)).not_to exist
        expect(Chat.where(id: chat.id)).not_to exist
        expect(PersonalTask.where(id: task.id)).not_to exist
      end
    end
  end

  # The users row after erasure must not depend on WHO erased it. Two accounts
  # with identical data, one erased per path; every column has to match except
  # the ones that are unique or random by construction. This is the mechanism
  # that catches a field cleared on one path only (2026-08-24: unconfirmed_email
  # and confirmation_token were nulled by ::User#anonymize! but survived the
  # admin path -- a pending e-mail change is a real, identifying address).
  describe 'the users row both paths leave behind' do
    # Frozen: every Time.current-derived column (confirmed_at, updated_at,
    # deleted_at) is then identical by construction instead of by luck.
    around { |example| travel_to(Time.zone.local(2026, 8, 24, 12, 0, 0)) { example.run } }

    let(:self_erased) { create(:user, email: 'max@example.com') }
    let(:admin_erased) { create(:user, email: 'moritz@example.com') }

    # Identical PII on both rows; the tokens carry a unique index, so they differ
    # per row BEFORE erasure and must be gone from both AFTER it.
    def identity_for(user)
      { first_name: 'Max', last_name: 'Mustermann', unconfirmed_email: 'max.neu@example.com',
        confirmation_token: "pending-#{user.id}", reset_password_token: "reset-#{user.id}",
        reset_password_sent_at: 1.hour.ago, remember_created_at: 1.day.ago,
        unlock_token: "unlock-#{user.id}", locked_at: 30.minutes.ago, failed_attempts: 3,
        email_visibility: 'contact', contact_email: 'max.kontakt@example.com' }
    end

    before do
      [self_erased, admin_erased].each { |u| u.update_columns(identity_for(u)) }
    end

    it 'is the same row column for column' do
      # One hour AFTER creation: updated_at then only matches if both paths
      # actually write it at erasure time (the frozen creation instant would
      # otherwise mask a path that never touches the timestamp).
      travel 1.hour

      self_erased.soft_delete_and_anonymize!
      ActsAsTenant.without_tenant { Admin::User.find(admin_erased.id) }.soft_delete_and_anonymize!

      # Two deliberate lookups of two rows, not a loop over an association.
      rows = Prosopite.pause { [self_erased, admin_erased].map { |u| User.with_deleted.find(u.id) } }
      # id and email are unique per row; the tombstone e-mail only has to share
      # the non-routable domain.
      expect(rows.map { |r| r.email.split('@').last }.uniq)
        .to eq([User::DeletionLifecycle::ANONYMIZED_EMAIL_DOMAIN])

      self_row, admin_row = rows.map { |r| r.attributes.except('id', 'email') }
      expect(admin_row).to eq(self_row)
    end

    # Equality alone would also hold if BOTH paths kept a field: pin the erasure
    # absolutely on each row, so a regression shared by the two paths still
    # turns this CI-run guard red (the in-depth ::User assertions live in
    # deletion_lifecycle_spec.rb, which is not in guards.yml).
    it 'clears the identifying fields on both rows, not merely equally' do
      self_erased.soft_delete_and_anonymize!
      ActsAsTenant.without_tenant { Admin::User.find(admin_erased.id) }.soft_delete_and_anonymize!

      rows = Prosopite.pause { [self_erased, admin_erased].map { |u| User.with_deleted.find(u.id) } }
      rows.each do |row|
        expect(row.attributes.slice('unconfirmed_email', 'confirmation_token', 'reset_password_token',
                                    'reset_password_sent_at', 'remember_created_at', 'unlock_token',
                                    'locked_at', 'contact_email').values).to all(be_nil)
        # An erased member shows no email at all, not even the tombstone address.
        expect(row.email_visibility).to eq('none')
        expect(row.failed_attempts).to eq(0)
        expect(row.encrypted_password).to eq('')
        expect([row.first_name, row.last_name]).to all(eq(User::DeletionLifecycle::ANONYMIZED_NAME))
      end
    end
  end
end
