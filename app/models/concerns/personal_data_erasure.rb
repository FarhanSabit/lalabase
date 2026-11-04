# frozen_string_literal: true

# Erases the personal records an account owns BEYOND the users row itself, for
# the account-erasure path: GDPR export archives, private meeting analyses,
# private ticket posts, personal tasks, linked people directory rows, the
# speaker link of glossary heard forms, the account's own chat threads (via
# PersonalChatErasure, which is included here so that both entry points get it
# through this ONE include) and, as access revocation, its personal access
# tokens.
#
# A concern rather than two methods, because the erasure has TWO entry points on
# the same table: User::DeletionLifecycle when a person deletes their own account,
# and Admin::User#soft_delete_and_anonymize! when an administrator does it from the
# backend. Those are separate implementations of the same promise (the separation
# is deliberate, see the header of user/deletion_lifecycle.rb), and a promise kept
# in only one of them is the failure mode this file exists to prevent. Found
# 2026-08-24: export archives and private analyses survived an admin erasure.
#
# ONE entry step, erase_personal_data! (private, called from inside each including
# class), and both paths call exactly that. A new kind of personal data is added
# here, once, and reaches both paths; a path that forgets the single call turns
# spec/models/user_erasure_path_parity_spec.rb red.
# spec/models/admin_twin_concern_parity_guard_spec.rb keeps the INCLUDE on both
# classes; it cannot see the call, which is why that second spec exists.
#
# Neither path ever runs a DELETE on users, both are soft deletes, so neither the
# FK (CASCADE on user_data_exports, NULLIFY on meeting_analyses) nor a
# `dependent:` option on an association would fire. Every step has to be explicit.
module PersonalDataErasure
  include PersonalChatErasure

  private

  def erase_personal_data!
    erase_data_exports!
    erase_avatar!
    erase_meeting_analyses!
    erase_private_posts!
    erase_personal_tasks!
    erase_personal_chats!
    erase_person_links!
    erase_term_correction_speakers!
    revoke_personal_access_tokens!
  end

  # GDPR export ZIPs are full plain-text snapshots (name, email, IPs) and must not
  # survive erasure. destroy_all, not delete_all: the archive blob goes through
  # ActiveStorage's after_destroy_commit purge_later, i.e. AFTER the surrounding
  # transaction commits. IO does not belong inside the transaction, and a purge
  # inside it would leave a purged archive behind a user who was never erased if a
  # later step rolls back. A class-level query rather than an association, so the
  # step reads the same on both classes (Admin::User has no user_data_exports).
  def erase_data_exports!
    UserDataExport.where(user_id: id).destroy_all
  end

  # The profile picture is a face — dead PII once the account is erased, and a
  # soft delete never fires the attachment's dependent purge. destroy (NOT
  # purge_later): the attachment row goes with the transaction, and the blob
  # purge fires through the attachment's own after_destroy_commit, i.e. only
  # AFTER commit — the same "row in the transaction, blob IO after commit"
  # property as the export archives above. Queried via
  # ActiveStorage::Attachment rather than the avatar association, so the step
  # reads the same on both classes (Admin::User deliberately has no avatar
  # association — see user.rb; the blobs live under record_type "User" either
  # way, which is also what routes the commit callback to ::User's
  # dependent: :purge_later reflection).
  def erase_avatar!
    ActiveStorage::Attachment.where(record_type: 'User', record_id: id, name: 'avatar')
                             .find_each(&:destroy)
  end

  # Meeting analyses (Gespraeche Slice 7a, D10): a PRIVATE analysis has exactly
  # one permitted reader, its creator. Once the account is erased there is no
  # legitimate reader left, so private analyses are destroyed (dead PII).
  # PUBLISHED analyses are org content and stay, with creator/visible_to_user
  # nulled so the row no longer points at the erased account. update_all on
  # purpose: no callbacks or broadcasts needed, and the consistency validation
  # (private => visible_to set) stays true because these are public rows.
  #
  # without_tenant because a person spans organisations and an erasure is not
  # tenant-scoped; without it this would clean exactly the organisation that
  # happened to be the current tenant.
  def erase_meeting_analyses!
    ActsAsTenant.without_tenant do
      MeetingAnalysis.where(creator_id: id, is_private: true).destroy_all
      MeetingAnalysis.where(creator_id: id).update_all(creator_id: nil, visible_to_user_id: nil)
    end
  end

  # Private ticket posts are the original E17 pattern MeetingAnalysis copies:
  # is_private + visible_to_user = creator, exactly one permitted reader. Once
  # the account is erased that reader is gone, so private posts are destroyed
  # (dead PII); public posts stay as org content. destroy_all so the dependent
  # rows (post_documents, fragments) go with them and the attachment blobs are
  # purged after commit.
  def erase_private_posts!
    ActsAsTenant.without_tenant do
      Post.where(user_id: id, is_private: true).destroy_all
    end
  end

  # Personal tasks are "STRICTLY private to the owner" (personal_task.rb); their
  # FK is ON DELETE CASCADE, which never fires on a soft delete. delete_all: the
  # model has no callbacks, attachments or dependent rows.
  def erase_personal_tasks!
    ActsAsTenant.without_tenant do
      PersonalTask.where(user_id: id).delete_all
    end
  end

  # The people directory rows linked to this account, in every organisation:
  # once the account is erased the row describes nobody the organisation still
  # works with through Lalabase, and its fields (phone, notes) are personal
  # data. Rows NOT linked to the account stay; they are the organisation's
  # contacts, even when they carry the same name. destroy_all so each row
  # leaves its anonymous person.deleted activity (PersonTrackable).
  def erase_person_links!
    ActsAsTenant.without_tenant do
      Person.where(user_id: id).destroy_all
    end
  end

  # The glossary heard forms this account spoke (term_corrections.user_id), in
  # every organisation. A heard form is knowledge of the organisation and stays,
  # as when a person of the directory is deleted (plan §3.3, K4a); only the link
  # to the erased account goes. A soft delete never fires the FK's
  # on_delete: :nullify, so the step is explicit. update_all: no callbacks, and
  # the one-speaker check holds (person_id stays as it is, empty).
  def erase_term_correction_speakers!
    ActsAsTenant.without_tenant do
      TermCorrection.where(user_id: id).update_all(user_id: nil, updated_at: Time.current)
    end
  end

  # Access revocation rather than erasure: a personal access token authenticates
  # by its hash alone (PersonalAccessToken.authenticate joins no users), so a
  # token surviving the erasure keeps answering the API for up to 90 days with
  # the memberships already gone. Revoked, not destroyed: the row carries an FK
  # from mcp_idempotency_keys, and a revoked token is dead for authenticate.
  # Api::TokenAuthenticatable additionally 401s when the token's owner row is
  # soft-deleted, as defence in depth. Not tenant-scoped, no escape needed.
  def revoke_personal_access_tokens!
    PersonalAccessToken.revoke_all_for!(self)
  end
end
