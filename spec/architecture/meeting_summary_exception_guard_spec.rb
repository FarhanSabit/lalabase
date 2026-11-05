# frozen_string_literal: true

require 'rails_helper'

# What: the AI summary of a meeting survives a change of its transcript in
#   one case only, a term correction (K4b, E4/E5). Meeting#invalidate_stale_summary
#   skips one save after Meeting#keep_summary_for_next_save!; only
#   Actors::SaveMeeting calls that, on its own instance, when its caller passes
#   keep_summary: true; and only Actors::CorrectMeetingTerm passes it.
# Why: everywhere else a summary of a changed transcript must go (GDPR erasure
#   consistency, review #235): a word removed from the transcript must not live
#   on in the summary. An exception that a second caller can set quietly would
#   undo that for whatever that caller writes.
# Not seen: a call built at run time (send, a keyword in a splatted hash
#   assembled elsewhere). Those are for the person who reads the diff.
module MeetingSummaryExceptionGuard
  ROOTS = %w[app lib].freeze

  SETTER = /\bkeep_summary_for_next_save!/
  SETTERS = {
    'app/models/meeting.rb' => 'defines it and takes it back in invalidate_stale_summary',
    'app/services/actors/save_meeting.rb' => 'sets it on its own instance, right before the one save'
  }.freeze

  KEYWORD = /\bkeep_summary:/
  KEYWORD_USERS = {
    'app/services/actors/save_meeting.rb' => 'takes the keyword',
    'app/services/actors/correct_meeting_term.rb' => 'the one caller that asks for it (K4b)'
  }.freeze

  # Files whose code (not their comments) matches the pattern.
  def self.files_with(pattern)
    ROOTS.flat_map { |root| Dir[Rails.root.join(root, '**', '*.{rb,erb}')] }.filter_map do |path|
      code = File.readlines(path).reject { |line| line.strip.start_with?('#', '<%#') }.join
      Pathname(path).relative_path_from(Rails.root).to_s if code.match?(pattern)
    end.sort
  end
end

RSpec.describe 'The AI summary survives a transcript change only for a term correction', type: :architecture do
  it 'is kept for the next save only through Actors::SaveMeeting' do
    expect(MeetingSummaryExceptionGuard.files_with(MeetingSummaryExceptionGuard::SETTER))
      .to eq(MeetingSummaryExceptionGuard::SETTERS.keys.sort)
  end

  it 'is asked of Actors::SaveMeeting by Actors::CorrectMeetingTerm alone' do
    expect(MeetingSummaryExceptionGuard.files_with(MeetingSummaryExceptionGuard::KEYWORD))
      .to eq(MeetingSummaryExceptionGuard::KEYWORD_USERS.keys.sort)
  end

  it 'sees the forms a call takes, and not a comment' do
    expect('meeting.keep_summary_for_next_save! if keep').to match(MeetingSummaryExceptionGuard::SETTER)
    expect('SaveMeeting.call(id: id, keep_summary: true)').to match(MeetingSummaryExceptionGuard::KEYWORD)
    expect('keep_summary_once = 1').not_to match(MeetingSummaryExceptionGuard::KEYWORD)
  end
end
