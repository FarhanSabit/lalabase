# frozen_string_literal: true

# What: Request spec for the AI area's "Indexierung" page
#   (doc/ki_bereich_navigation_plan.md §3.5, slice S4).
# Type: Request spec — the SUMMARY states, plus the authorization around them.
# Why (philosophy): Before S4 this page was raw statistics: eight counters from which
#   the admin had to work out for themselves whether anything was broken. §3.5 turns the
#   top of the page into a statement in words plus the one action that helps, so what
#   has to be pinned is the STATEMENT, not that the page renders. A summary that reads
#   the same in all four situations would satisfy a "returns 200" test and be worth
#   nothing — which is why every example below asserts a state that differs from the
#   others.
# Contract: account_admin only; the summary reports clear / outstanding / failed from
#   Embeddings::IndexHealth (the hub's source, never a second count), states a running
#   staged switch as the REASON alongside the backlog rather than instead of it, names
#   the vector space the counts describe, and offers the reprocess action exactly when
#   there is something to catch up.

require 'rails_helper'

RSpec.describe 'Organisations::AiSyncStatuses', type: :request do
  let(:organisation) { create(:organisation, ai_enabled: true) }
  let(:admin) { create(:user) }
  let(:member) { create(:user) }

  let(:admin_role) { ActsAsTenant.with_tenant(organisation) { create(:admin_role, organisation: organisation) } }
  let(:member_role) { ActsAsTenant.with_tenant(organisation) { create(:role, organisation: organisation) } }

  let!(:admin_membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: admin, organisation: organisation, role: admin_role, active: true)
    end
  end

  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  def summary_state
    get organisation_ai_sync_status_path(organisation)
    response.body[/data-index-summary-state="(\w+)"/, 1]
  end

  def summary_text(key, **args)
    I18n.t("views.organisations.ai_overview.index_summary.#{key}", **args)
  end

  # A backlog only means PROGRESS while something is working on it, so every example that
  # expects the :working state has to say that a worker exists. It used to be an unstated
  # assumption of this file, and an unstated assumption is exactly how a queue that had
  # been dead for months kept rendering as "Verarbeitung läuft".
  def register_live_worker
    SolidQueue::Process.create!(kind: 'Worker', last_heartbeat_at: Time.current,
                                pid: 4242, name: "worker-#{SecureRandom.hex(4)}")
  end

  describe 'as account_admin' do
    before { sign_in admin }

    # The section's head (doc/verwaltung_seitennavigation_plan.md S3): the help stands
    # right of the title. Once on the page and that once in the head, so no row of its
    # own is left under the tab row.
    it 'puts its help into the head of the section' do
      get organisation_ai_sync_status_path(organisation)
      doc = Nokogiri::HTML(response.body)
      tabs = doc.at_css("main nav[aria-label='#{I18n.t('settings.ai')}']")
      expect(tabs).not_to be_nil, 'no tab row in main named after the section'
      head = tabs.previous_element
      help = "[data-controller='dropdown'] > [title='#{I18n.t('components.contextual_help.label')}']"

      expect(head.at_css('h1').text.squish).to eq(I18n.t('settings.ai'))
      expect(head.css(help).size).to eq(1)
      expect(doc.css("main #{help}").size).to eq(1)
    end

    # The table below the summary used to know four of nine types; the help text even
    # documented the gap. Derived from the registry so a tenth type is on the page the
    # day it is registered, and a helper without a row for it is a red test, not a blank.
    it 'renders a per-project row for every registered content type' do
      project
      get organisation_ai_sync_status_path(organisation)

      cards = Nokogiri::HTML(response.body).css('[data-type-card]')

      expect(cards.map { |card| card['data-type-card'] }).to eq(Embeddings::ContentTypes.keys.map(&:to_s))
      Embeddings::ContentTypes.entries.each do |entry|
        expect(cards.at_css("[data-type-card='#{entry.key}']").text)
          .to include(I18n.t("views.organisations.ai_sync_statuses.show.types.#{entry.key}")), entry.key.inspect
      end
    end

    # The numbers the project row states, read back off the RENDERED page. Nothing else
    # in the suite reads a per-project FIGURE from the HTML: the service specs pin the
    # service's own keys, so a view asking for a key the service no longer produces
    # renders "" and stays green. That is what totals[:total_content] did after the
    # rewrite renamed it to totals[:total].
    #
    # ⚠️ Through the page's own anchors, NOT a body substring: a check for "3 Inhalte"
    # is vacuous here, because the summary at the top of the same page says "3 Inhalte
    # sind vorgemerkt" (measured) and satisfies it over an empty project header.
    it 'names how much content the project holds' do
      ActsAsTenant.with_tenant(organisation) do
        3.times { create(:ticket, project: project, organisation: organisation, creator: admin) }
      end
      get organisation_ai_sync_status_path(organisation)
      page = Nokogiri::HTML(response.body)

      expect(page.at_css('[data-project-content-count]').text.strip)
        .to eq(I18n.t('views.organisations.ai_sync_statuses.show.content_count', count: 3))
      expect(page.at_css('[data-project-total]').text.strip).to eq('3')
    end

    # The card's own arithmetic. Since the pending/failed split, "Wartend" no longer
    # counts a failed record, so without an error row the card reads enabled 1,
    # verarbeitet 0, wartend 0 and nothing accounts for the difference — while the help
    # page promises the failure is counted in both places.
    it 'names a failed record on the type card it belongs to' do
      ActsAsTenant.with_tenant(organisation) do
        create(:note, project: project, organisation: organisation,
                      create_embeddings: true, embedding_creation_error: 'boom')
      end
      get organisation_ai_sync_status_path(organisation)
      card = Nokogiri::HTML(response.body).at_css("[data-type-card='notes']").text

      expect(card).to include(I18n.t('views.organisations.ai_sync_statuses.show.errors'))
      expect(card.gsub(/\s+/, ' ')).to include("#{I18n.t('views.organisations.ai_sync_statuses.show.errors')}: 1")
    end

    it 'reports a clean index as clear and says so in words' do
      expect(summary_state).to eq('ok')
      expect(response.body).to include(summary_text(:heading_clear))
      expect(response.body).to include(summary_text(:nothing_to_do))
    end

    # The action is the second half of §3.5 ("plus die eine Aktion, die hilft"), and its
    # ABSENCE on a clear index is as much a statement as its presence: a catch-up run
    # with nothing to catch up is a mass job for no reason.
    it 'offers no catch-up run while there is nothing outstanding' do
      get organisation_ai_sync_status_path(organisation)

      expect(response.body).not_to include(
        reprocess_embeddings_organisation_ai_sync_status_path(organisation)
      )
    end

    # ⚠️ Found by a mutation probe, not by design: replacing #in_progress? with a plain
    # presence check survived every other example in this file. Embeddings::SwitchProgress
    # ALWAYS answers with a Result — "no switch" is the STATE :none, never nil — so a
    # presence check is true for every organisation, and the page would head a box with
    # "Ein Modellwechsel läuft" over a text keyed to a state that has no translation at
    # all. The absence of the notice needs an example of its own; nothing else asserts it.
    it 'says nothing about a switch while none is running' do
      get organisation_ai_sync_status_path(organisation)

      expect(response.body).not_to include('data-switch-state')
      expect(response.body).not_to include(summary_text('switch.heading'))
    end

    context 'when content is outstanding' do
      before do
        ActsAsTenant.with_tenant(organisation) do
          create(:note, project: project, organisation: organisation,
                        create_embeddings: true, embeddings_creation_flag: nil)
        end
      end

      it 'names the backlog rather than leaving the admin to add up counters' do
        register_live_worker

        expect(summary_state).to eq('working')
        expect(response.body).to include(summary_text(:heading_pending))
        expect(response.body).to include(summary_text(:pending, count: 1))
      end

      it 'offers the catch-up run next to the sentence that motivates it' do
        register_live_worker
        get organisation_ai_sync_status_path(organisation)

        expect(response.body).to include(
          reprocess_embeddings_organisation_ai_sync_status_path(organisation)
        )
        expect(response.body).to include(summary_text(:action_hint))
      end

      # The reason this branch exists. Without a worker the page used to say the same
      # "Verarbeitung läuft" it says over a healthy queue — the admin was told to wait for
      # work nobody was doing, and the giveaway (25 jobs queued since February) lived only
      # in a table no page reads. Same counts as the example above, opposite statement.
      context 'and nothing is working on it' do
        it 'refuses to call an unattended backlog progress' do
          expect(summary_state).to eq('alert')
          expect(response.body).to include(summary_text(:heading_stalled))
          expect(response.body).to include(summary_text(:stalled))
        end

        # The counts are still true and must still be shown: the stall qualifies the
        # backlog, it does not replace it.
        it 'still names the backlog it is qualifying' do
          get organisation_ai_sync_status_path(organisation)

          expect(response.body).to include(summary_text(:pending, count: 1))
        end

        # "Es sind Fehler aufgetreten" would name a defect the counts do not show. A stall
        # is not a failure, and telling the admin to look for failed content sends them to
        # the one place with nothing in it.
        it 'does not claim failures it cannot show' do
          get organisation_ai_sync_status_path(organisation)

          expect(response.body).not_to include(summary_text(:heading_failed))
        end
      end

      # A stall must not silence the real thing. Failures outrank it: they name content
      # that needs attention, where a stall only says nobody is looking right now.
      context 'and content has also failed' do
        before do
          ActsAsTenant.with_tenant(organisation) do
            create(:note, project: project, organisation: organisation,
                          create_embeddings: true, embedding_creation_error: 'boom')
          end
        end

        it 'keeps the failure heading rather than reporting the stall instead' do
          get organisation_ai_sync_status_path(organisation)

          expect(response.body).to include(summary_text(:heading_failed))
          expect(response.body).not_to include(summary_text(:heading_stalled))
        end

        it 'still says the queue is not running, next to the failure' do
          get organisation_ai_sync_status_path(organisation)

          expect(response.body).to include(summary_text(:stalled))
        end
      end
    end

    # A clear index has nothing to wait for, so a missing worker is not news there. Saying
    # "nobody is working on this" over an empty backlog would be true and useless, and the
    # green state would stop meaning anything.
    it 'says nothing about a stall while there is no backlog to stall' do
      get organisation_ai_sync_status_path(organisation)

      expect(summary_state).to eq('ok')
      expect(response.body).not_to include(summary_text(:stalled))
    end

    # A failure is not a slower success. Outstanding work resolves by itself; a failed
    # item never does, so the two must not collapse into one "es läuft"-shaped state.
    context 'when content failed to embed' do
      before do
        ActsAsTenant.with_tenant(organisation) do
          create(:note, project: project, organisation: organisation,
                        create_embeddings: true, embedding_creation_error: 'boom')
        end
      end

      it 'reports the failure as its own state, not as outstanding work' do
        expect(summary_state).to eq('alert')
        expect(response.body).to include(summary_text(:heading_failed))
        expect(response.body).to include(summary_text(:failed, count: 1))
        expect(response.body).not_to include(summary_text(:heading_pending))
      end
    end

    # ⚠️ The addendum of 2026-08-05 to §3.5: during a staged switch this page said
    # "ausstehend" without the reason, and the admin reached for the one button that does
    # not help. The switch is stated ALONGSIDE the backlog, never instead of it.
    context 'while a staged switch is running' do
      before do
        allow(Embeddings::SwitchProgress).to receive(:call).and_return(
          Embeddings::SwitchProgress::Result.new(state: :building, remaining: 4, total: 10)
        )
        ActsAsTenant.with_tenant(organisation) do
          create(:note, project: project, organisation: organisation,
                        create_embeddings: true, embeddings_creation_flag: nil)
        end
      end

      it 'explains why the numbers are moving' do
        get organisation_ai_sync_status_path(organisation)

        expect(response.body).to include('data-switch-state="building"')
        expect(response.body).to include(summary_text('switch.heading'))
        expect(response.body).to include(
          summary_text('switch.building', completed: 6, total: 10, percent: 60)
        )
      end

      # Each of SwitchProgress's four in-progress states says something different, and
      # two of them say "this is stuck". A notice keyed to the wrong state, or hardcoded
      # to the happy one, would tell an admin whose rebuild has run out of quota that it
      # is progressing nicely — measured only in production. So a SECOND state is pinned
      # here; one example would let a constant pass for a lookup.
      it 'distinguishes a stalled build from a progressing one' do
        allow(Embeddings::SwitchProgress).to receive(:call).and_return(
          Embeddings::SwitchProgress::Result.new(state: :paused, remaining: 4, total: 10)
        )

        get organisation_ai_sync_status_path(organisation)

        expect(response.body).to include('data-switch-state="paused"')
        expect(response.body).to include(
          summary_text('switch.paused', completed: 6, total: 10, percent: 60)
        )
        expect(response.body).not_to include(
          summary_text('switch.building', completed: 6, total: 10, percent: 60)
        )
      end

      # The half that a naive "show the switch instead" implementation gets wrong: the
      # backlog statement and the reprocess action have to survive the switch notice.
      it 'keeps the backlog statement and the action alongside it' do
        register_live_worker

        expect(summary_state).to eq('working')
        expect(response.body).to include(summary_text(:pending, count: 1))
        expect(response.body).to include(
          reprocess_embeddings_organisation_ai_sync_status_path(organisation)
        )
      end
    end

    # "12 ausstehend" is no longer a complete statement without the space it holds for
    # (§3.5 addendum) — an organisation can hold several, and the counts describe one.
    describe 'the vector space the counts describe' do
      it 'names the space that is actually being served' do
        space = ActsAsTenant.with_tenant(organisation) do
          create(:embedding_space, organisation: organisation)
        end
        organisation.update!(active_embedding_space: space)

        get organisation_ai_sync_status_path(organisation)

        expect(response.body).to include(
          ERB::Util.html_escape(
            summary_text(:space, provider: space.embedding_provider,
                                 model: space.embedding_model, dims: space.embedding_dims)
          )
        )
      end

      # No credential, no answer — and the page still has to render, because the backlog
      # it shows is exactly what an admin came to look at when the AI stopped working.
      it 'says the space is unknown rather than failing, when it cannot be resolved' do
        get organisation_ai_sync_status_path(organisation)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(summary_text(:space_unknown))
      end
    end
  end

  describe 'as regular member (not account_admin)' do
    let!(:member_membership) do
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: member, organisation: organisation, role: member_role, active: true)
      end
    end

    before { sign_in member }

    it 'is denied, exactly like the hub that links here' do
      get organisation_ai_sync_status_path(organisation)

      expect(response).to have_http_status(:redirect)
      expect(flash[:alert]).to be_present
    end
  end
end
