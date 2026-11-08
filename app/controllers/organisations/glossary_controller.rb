# frozen_string_literal: true

# The glossary of an organisation (K4a): GlossaryTerm with its heard forms
# (TermCorrection). One page with a lane, the shape of the people directory
# (PeopleController): the terms on the left, a term or the form in the lane
# frame on the right. The address carries the lane state, ?term_id= for a
# term, ?new=term for the form and ?new=import for the import of a pasted
# list, and the filters (LIST_PARAMS).
#
# show, new and edit answer the lane frame (a row click, the "+",
# "Bearbeiten"); a full visit of them lands on the index with the same lane
# state. The index answers a lane frame request with the lane alone.
#
# Writes go through the glossary actors and leave the frame (_top): they land
# on the list again, with the term open where one is left. An open heard form
# (K4b, E3: a correction in a meeting without manage_glossary) is confirmed or
# rejected here, form by form. A refused save
# renders the index with the form and its reason (422).
#
# The import (K5, Actors::ImportGlossaryTerms) is open to every reader of the
# glossary; the actor decides that new terms are confirmed with
# manage_glossary and proposed without. Its check runs in the lane frame as a
# dry run (a POST: the actor writes in a savepoint and rolls it back), the
# import leaves the frame and lands on the list with the counts as its notice.
# A refused list (empty, too many lines) shows the textarea again with the
# text kept and the reason (422).
#
# Rights: GlossaryPolicy (view_glossary / manage_glossary, account admins
# without a row). A denial answers 403, as on the people page: the page and
# its frame have nothing to show, and a redirect inside the lane frame loops.
# A term of another organisation is no term at all (404). The glossary shows
# heard forms from every project (E3), but the title and the link of a meeting
# only to a reader of that meeting, a speaker's name only to a reader who may
# see that speaker on the members or the people page, and the link to a
# speaker only with view_people as well (GlossaryHelper).
module Organisations
  class GlossaryController < Organisations::BaseController
    include ViewportSwitchable

    DETAIL_FRAME_ID = 'glossary_term_display_frame'
    LIST_FRAME_ID = 'glossary_results'
    NEW_STATE = 'term'
    IMPORT_STATE = 'import'
    # The filters the address, the lane's forms and the writes carry along.
    LIST_PARAMS = %w[project_id category status].freeze
    # The parts of the notice after an import, in this order, each only when
    # it is not zero (the counts of Actors::ImportGlossaryTerms#report).
    IMPORT_NOTICE_COUNTS = %i[created proposed categorized existing rejected duplicate invalid].freeze

    # What the import lane shows: the text so far and, once checked, the
    # report of the dry run.
    ImportDraft = Data.define(:text, :report) do
      def initialize(text:, report: nil)
        super
      end
    end

    rescue_from Pundit::NotAuthorizedError, with: :render_forbidden

    # Every action: the lane frames render the phone layout too, and only the
    # address knows which one.
    before_action :set_viewport_mode
    before_action :set_term, except: %i[index new create import_preview import]

    def index
      authorize GlossaryTerm
      @terms = policy_scope(GlossaryTerm)
      return render_lane_frame if lane_frame_request?

      load_list
      @lane_term = selected_term
      @form_term = new_term if @lane_term.nil? && new_term_requested?
      @import = ImportDraft.new(text: '') if @lane_term.nil? && import_requested?
    end

    def show
      authorize @term
      return redirect_to(index_path(term_id: @term.id)) unless turbo_frame_request?

      render_frame(:detail, term: @term)
    end

    def new
      @term = new_term
      authorize @term
      return redirect_to(index_path(new: NEW_STATE)) unless turbo_frame_request?

      render_frame(:form, term: @term)
    end

    def edit
      authorize @term
      return redirect_to(index_path(term_id: @term.id)) unless turbo_frame_request?

      render_frame(:form, term: @term)
    end

    def create
      authorize GlossaryTerm
      save_term(id: nil, flash_key: 'controllers.glossary.create.success')
    end

    def update
      authorize @term
      save_term(id: @term.id, flash_key: 'controllers.glossary.update.success')
    end

    def destroy
      authorize @term
      result = Actors::DestroyGlossaryTerm.call(term: @term, current_user: current_user)
      land(result, notice: 'controllers.glossary.destroy.success', lane: {}, failure_lane: { term_id: @term.id })
    end

    def confirm
      authorize @term
      change_status('confirmed', notice: 'controllers.glossary.confirm.success')
    end

    def reject
      authorize @term
      change_status('rejected', notice: 'controllers.glossary.reject.success')
    end

    # Into the target named by target_id, a term of this glossary found
    # through the policy scope, never a raw id. The lane of the target opens.
    def merge
      authorize @term
      target = merge_target
      return refuse_merge_without_target unless target

      result = Actors::MergeGlossaryTerms.call(source: @term, target: target, current_user: current_user)
      land(result, notice: 'controllers.glossary.merge.success', lane: { term_id: target.id }, failure_lane: { term_id: @term.id })
    end

    # One heard form of this term, learnt wrong, with every correction of it,
    # named by one of those corrections. The write right first (403 before the
    # correction is looked up), then only a correction of this term.
    def destroy_heard_form
      authorize @term, :update?
      correction = policy_scope(TermCorrection).where(glossary_term_id: @term.id).find(params[:correction_id])
      authorize correction, :destroy?
      result = Actors::DestroyHeardForm.call(correction: correction, current_user: current_user)
      land(result, notice: 'controllers.glossary.heard_form.destroy.success', lane: { term_id: @term.id },
                   failure_lane: { term_id: @term.id })
    end

    # An open heard form of this term (K4b, E3), named by one of its
    # corrections: its proposals confirmed (they work from then on), or
    # rejected (they go; a confirmed correction of the same form stays).
    def confirm_heard_form
      decide_heard_form(Actors::ConfirmHeardForm, notice: 'controllers.glossary.heard_form.confirm.success')
    end

    def reject_heard_form
      decide_heard_form(Actors::RejectHeardForm, notice: 'controllers.glossary.heard_form.reject.success')
    end

    # The check of a pasted list, in the lane frame: the import as a dry run,
    # nothing written. With edit (the way back from the check) the textarea
    # again, the text kept.
    def import_preview
      authorize GlossaryTerm, :index?
      text = import_text
      return render_frame(:import, import: ImportDraft.new(text: text)) if params[:edit].present?

      actor = import_actor(text, dry_run: true)
      result = actor.call
      if result.success?
        render_frame(:import_preview, import: ImportDraft.new(text: text, report: actor.report))
      else
        render_frame(:import, import: ImportDraft.new(text: text), message: result.errors.to_sentence,
                              status: :unprocessable_content)
      end
    end

    # The import of the checked list; it leaves the frame and lands on the
    # list, the counts in the notice.
    def import
      authorize GlossaryTerm, :index?
      text = import_text
      actor = import_actor(text, dry_run: false)
      result = actor.call
      if result.success?
        redirect_to index_path, status: :see_other, notice: import_notice(actor.report.counts)
      else
        render_refused_import(text, result)
      end
    end

    private

    # The write right first (403 before the correction is looked up), then
    # only a correction of this term.
    def decide_heard_form(actor, notice:)
      authorize @term, :update?
      correction = policy_scope(TermCorrection).where(glossary_term_id: @term.id).find(params[:correction_id])
      authorize correction, :update?
      result = actor.call(correction: correction, current_user: current_user)
      land(result, notice: notice, lane: { term_id: @term.id }, failure_lane: { term_id: @term.id })
    end

    # The right first (403 without it, before anything is looked up), then
    # through the policy scope: a term of another organisation is no term at
    # all (404).
    def set_term
      authorize GlossaryTerm, :index?
      @term = policy_scope(GlossaryTerm).find(params[:id])
    end

    def save_term(id:, flash_key:)
      result = Actors::SaveGlossaryTerm.call(organisation: current_organisation, params: term_params,
                                             current_user: current_user, id: id)
      if result.success?
        redirect_to index_path(term_id: result.resource.id), status: :see_other, notice: t(flash_key)
      else
        render_refused_save(result, id)
      end
    end

    # The index again, with the form open in the lane and the reason above it.
    # A stale save shows the CURRENT values (and their lock_version): the
    # other side's change stays, and the writer sees what they would
    # overwrite, as on the people page.
    def render_refused_save(result, id)
      @terms = policy_scope(GlossaryTerm)
      stale = result.code == :stale_object
      @form_term = stale ? @terms.find(id) : (result.resource || new_term)
      @form_message = stale ? t('controllers.glossary.update.stale') : result.errors.to_sentence
      load_list
      render :index, status: :unprocessable_content
    end

    # From the list the list stays as it was; from the lane (term_id sent
    # along) the lane stays open.
    def change_status(status, notice:)
      result = Actors::SetGlossaryTermStatus.call(term: @term, status: status, current_user: current_user)
      lane = params[:term_id] == @term.id ? { term_id: @term.id } : {}
      land(result, notice: notice, lane: lane, failure_lane: lane)
    end

    def land(result, notice:, lane:, failure_lane:)
      if result.success?
        redirect_to index_path(**lane), status: :see_other, notice: t(notice)
      else
        redirect_to index_path(**failure_lane), status: :see_other, alert: result.errors.to_sentence
      end
    end

    # expect, not require.permit: a glossary_term that is no hash (a hand-made
    # request) answers 400 instead of crashing.
    def term_params
      params.expect(glossary_term: Actors::SaveGlossaryTerm::ATTRIBUTES)
    end

    def refuse_merge_without_target
      redirect_to index_path(term_id: @term.id), status: :see_other, alert: t('controllers.glossary.merge.no_target')
    end

    # expect, as in term_params: an import that is no hash answers 400. A
    # text that is no string reaches the actor as none (refused as empty).
    def import_text
      params.expect(import: [:text])[:text]
    end

    def import_actor(text, dry_run:)
      Actors::ImportGlossaryTerms.new(organisation: current_organisation, text: text, current_user: current_user,
                                      dry_run: dry_run)
    end

    # "Liste importiert: 23 Begriffe angelegt, 4 schon vorhanden und 2 doppelt
    # in der Liste." A list that is not refused has a verdict for each of its
    # lines, so there is always a part.
    def import_notice(counts)
      parts = IMPORT_NOTICE_COUNTS.filter_map do |key|
        t("controllers.glossary.import.counts.#{key}", count: counts[key]) if counts[key].positive?
      end
      t('controllers.glossary.import.success', summary: parts.to_sentence)
    end

    # The page again, with the import open in the lane, the text kept and the
    # reason above it, as render_refused_save does for the form.
    def render_refused_import(text, result)
      @terms = policy_scope(GlossaryTerm)
      @import = ImportDraft.new(text: text)
      @form_message = result.errors.to_sentence
      load_list
      render :index, status: :unprocessable_content
    end

    # No right of its own: every reader of the glossary may import.
    def import_requested?
      params[:new] == IMPORT_STATE
    end

    def merge_target
      id = params[:target_id]
      policy_scope(GlossaryTerm).find_by(id: id) if id.is_a?(String) && id.present?
    end

    def new_term
      GlossaryTerm.new(organisation: current_organisation)
    end

    def new_term_requested?
      params[:new] == NEW_STATE && policy(GlossaryTerm).create?
    end

    def selected_term
      id = params[:term_id]
      @terms.find_by(id: id) if id.is_a?(String) && id.present?
    end

    # The terms of the list in their order (open proposals first), with what a
    # row shows of their heard forms: speaker and project, never the meeting.
    # Filtered by status, category and the project a heard form came from.
    def load_list
      @status_counts = @terms.group(:status).count
      @origin_projects = glossary_origin_projects
      @entries = filtered_terms.ordered.includes(term_corrections: %i[project person user]).to_a
    end

    def filtered_terms
      terms = @terms
      terms = terms.where(status: list_state['status']) if list_state['status']
      terms = terms.where(category: list_state['category']) if list_state['category']
      terms = terms.where(id: heard_in_project(list_state['project_id'])) if list_state['project_id']
      terms
    end

    def heard_in_project(project_id)
      policy_scope(TermCorrection).where(project_id: project_id).select(:glossary_term_id)
    end

    # The projects heard forms came from, by name: the choices of the project
    # filter. Their names are part of the glossary (E3), also for a reader
    # who cannot open the project.
    def glossary_origin_projects
      @glossary_origin_projects ||=
        Project.where(id: policy_scope(TermCorrection).where.not(project_id: nil).select(:project_id))
               .order(Arel.sql('LOWER(projects.name)'), :id).pluck(:id, :name)
    end

    def lane_frame_request?
      turbo_frame_request? && request.headers['Turbo-Frame'] == DETAIL_FRAME_ID
    end

    # The lane alone, as a full visit of the same address shows it.
    def render_lane_frame
      term = selected_term
      if term
        render_frame(:detail, term: term)
      elsif new_term_requested?
        render_frame(:form, term: new_term)
      elsif import_requested?
        render_frame(:import, import: ImportDraft.new(text: ''))
      else
        render_frame(:empty)
      end
    end

    def render_frame(state, term: nil, import: nil, message: nil, status: :ok)
      render html: helpers.turbo_frame_tag(DETAIL_FRAME_ID) {
        helpers.render(partial: 'organisations/glossary/lane', locals: { state: state, term: term, import: import, message: message })
      }, layout: false, status: status
    end

    def render_forbidden
      skip_authorization
      skip_policy_scope
      if turbo_frame_request?
        render html: helpers.turbo_frame_tag(request.headers['Turbo-Frame']) {
          helpers.tag.p(t('shared.errors.not_authorized'), class: 'py-10 text-center text-sm text-muted')
        }, layout: false, status: :forbidden
      else
        render plain: t('shared.errors.not_authorized'), status: :forbidden
      end
    end

    def index_path(**lane)
      organisation_glossary_terms_path(current_organisation, list_state.merge(lane.stringify_keys).compact_blank)
    end

    # The filters of this request (the address, or the hidden fields of a lane
    # form), each one only with a value it knows; anything else is no filter.
    # The phone view rides along (viewport=mobile), as on the people page.
    def list_state
      @list_state ||= begin
        given = request.query_parameters.merge(request.request_parameters)
        state = given.slice(*LIST_PARAMS).select { |_key, value| value.is_a?(String) && value.present? }
        state.delete('status') unless GlossaryTerm::STATUSES.include?(state['status'])
        state.delete('category') unless GlossaryTerm::CATEGORIES.include?(state['category'])
        state.delete('project_id') if state['project_id'] && glossary_origin_projects.none? { |id, _name| id == state['project_id'] }
        state['viewport'] = 'mobile' if given['viewport'] == 'mobile'
        state
      end
    end
    helper_method :list_state

    # Whether a speaker's name may link to the people page (view_people),
    # once per request: the lane asks it for every heard form.
    def glossary_people_linkable?
      return @glossary_people_linkable if defined?(@glossary_people_linkable)

      @glossary_people_linkable = PersonPolicy.view_allowed?(current_user, current_organisation)
    end
    helper_method :glossary_people_linkable?

    # The rows of the people directory the reader may see there
    # (PersonPolicy::Scope), once per request: a speaker who is one of them
    # shows its name and links to it. None without view_people, which the
    # people page needs (no query then).
    def glossary_visible_person_ids
      @glossary_visible_person_ids ||= policy_scope(Person).pluck(:id).to_set
    end
    helper_method :glossary_visible_person_ids

    # The members the reader may see on the members page
    # (MembershipPolicy::Scope, deactivated ones too), as user_id => active,
    # once per request and also without view_people: a speaker who is one of
    # them shows their name. Only an active one links to the people page,
    # which lists active members only (People::Directory#member_entries), so
    # the link never opens an empty lane.
    def glossary_visible_members
      @glossary_visible_members ||= policy_scope(Membership).where(organisation: current_organisation)
                                                            .pluck(:user_id, :active).to_h
    end
    helper_method :glossary_visible_members
  end
end
