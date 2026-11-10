# frozen_string_literal: true

class Organisations::DocumentsController < Organisations::BaseController
  include ActionView::RecordIdentifier
  include Sortable
  include Pageable
  include Searchable
  include ProjectController

  before_action :redirect_index_to_knowledge, only: [:index]
  before_action :set_documents
  before_action :set_document, only: %i[show edit update destroy download create_version destroy_version set_current_version download_plain_text preview]

  # Configure the Sortable functionality
  setup_sortable Document, 'documents.created_at'
  add_sortable_columns 'document_versions.title'

  # Configure the Pageable functionality
  setup_pagination 5

  # Configure the Searchable functionality
  setup_searchable Document, ['document_versions.title', 'document_versions.description', 'document_versions.plain_text_version']

  # The dedicated documents list view no longer exists —
  # redirect_index_to_knowledge (before_action) redirects all calls.
  def index; end

  def show
    @document = @project.documents.find(params[:id])
    authorize @document
    @current_version = @document.current_version
    @versions = @document.document_versions.listed
    @new_version = DocumentVersion.new

    # Handle frame=content requests from turbo frame src (HTML requests)
    # This must be before respond_to because turbo frame src sends HTML, not turbo_stream
    if params[:frame] == 'content'
      frame_id = detail_frame_id
      render html: helpers.turbo_frame_tag(frame_id) {
        # Force formats: [:html] — otherwise, on a turbo_stream request (e.g. the old
        # cancel path), the partial lookup searches for a .turbo_stream variant ->
        # "Missing partial". The content is always HTML.
        helpers.render(partial: 'organisations/documents/document_content_for_frame', formats: [:html], locals: {
                         document: @document,
                         versions: @versions,
                         current_version: @current_version,
                         new_version: @new_version,
                         # Pass the frame ID into the partial so that the edit pencil
                         # (and new version) target the same frame as the wrapper.
                         # Otherwise it defaults to 'document_display_frame' -> on click-to-
                         # load in the Knowledge view "Content missing".
                         detail_frame_id: frame_id
                       })
      }.html_safe, layout: false
      return
    end

    # Standalone calls land in the Knowledge view with the selected file —
    # a dedicated documents detail/list view no longer exists.
    redirect_to organisation_project_knowledge_index_path(
      @current_organisation, @project,
      document_id: @document.id,
      type: 'all'
    )
  end

  def new
    @document = @project.documents.build
    authorize @document
    @document.document_versions.build

    # Handle frame=content requests for inline rendering in Knowledge view
    return unless params[:frame] == 'content'

    # Only render frameless for Turbo Frame requests; a plain request (the
    # phone's "+", a bookmark) lands on the knowledge page with the form as a
    # state of its address (?new=document, KnowledgeController#set_new_type).
    unless turbo_frame_request?
      redirect_to organisation_project_knowledge_index_path(@current_organisation, @project, new: 'document')
      return
    end

    frame_id = detail_frame_id
    render html: helpers.turbo_frame_tag(frame_id) {
      helpers.render(partial: 'organisations/documents/document_new_for_frame',
                     locals: { document: @document, detail_frame_id: frame_id })
    }.html_safe, layout: false
    nil
  end

  def create
    @document = @project.documents.build
    authorize @document

    # First check whether a file was selected
    if document_params.dig(:document_versions_attributes, '0', :document_version_file).blank?
      @document = @project.documents.build(document_params)
      @document.document_versions.first&.errors&.add(:document_version_file, t('flash.documents.file_required'))
      respond_after_failed_create(t('flash.documents.no_file_selected'))
      return
    end

    actor = Actors::SaveDocument.new(project: @project, params: document_params, current_user: current_user)
    result = actor.call
    if result.success?
      # The inline form targets `_top`, so this redirect becomes a full page visit that
      # shows the list with the new document and its detail. knowledge#index must
      # answer HTML for that to work (see the note there).
      redirect_to organisation_project_knowledge_index_path(
        @current_organisation, @project, document_id: result.resource.id, type: 'all'
      ), notice: t('flash.documents.created')
    else
      @document = @project.documents.build(document_params)
      # Add the errors directly to the document object
      result.errors.each do |error|
        @document.errors.add(:base, error)
      end
      respond_after_failed_create(t('flash.documents.save_error_detail', errors: result.errors.join(', ')))
    end
  end

  def edit
    authorize @document
    respond_to do |format|
      format.turbo_stream do
        # Pass frame_id through — default is the frame of the Knowledge view
        # (the only remaining detail display for documents)
        render turbo_stream: [
          turbo_stream.update(detail_frame_id,
                              partial: 'organisations/documents/document_edit', locals: { document: @document })
        ]
      end
      format.html do
        render :edit
      end
    end
  end

  def update
    authorize @document

    result = Actors::SaveDocument.call(project: @project, params: document_params, id: @document.id, current_user: current_user)

    if result.success?
      respond_after_successfull_save(@project, @document)
    else
      respond_after_failed_update(result)
    end
  end

  def respond_after_successfull_save(project, document)
    @project = project
    @document = document

    # Load current versions and metadata
    @versions = @document.document_versions.listed
    @current_version = @document.current_version
    @new_version = DocumentVersion.new

    respond_to do |format|
      format.turbo_stream do
        # Update the detail frame of the Knowledge view (pass frame_id through)
        # and update the row in the Knowledge list along with it.
        frame_id = detail_frame_id
        render turbo_stream: [
          turbo_stream.update(frame_id, partial: 'organisations/documents/document_content_for_frame', locals: {
                                document: @document,
                                versions: @versions,
                                current_version: @current_version,
                                new_version: @new_version,
                                detail_frame_id: frame_id
                              }),
          turbo_stream.replace_all("tr[data-item-id='#{@document.id}']",
                                   partial: 'organisations/knowledge/knowledge_row',
                                   locals: { item: @document, selected_item: @document })
        ]
      end
      format.html do
        redirect_to organisation_project_document_path(@current_organisation, @project, @document), notice: t('flash.documents.updated')
      end
    end
  end

  def destroy
    authorize @document
    # Capture the id before deletion — the turbo_stream target references the
    # (now gone) document row.
    document_id = @document.id
    result = Actors::DestroyDocument.call(document: @document, current_user: current_user)

    if result.success?
      respond_after_successful_destroy(document_id)
    else
      respond_after_failed_destroy(result)
    end
  end

  def download
    # Download = read access: explicit :show? (DocumentPolicy has no :download?; without
    # an explicit action Pundit incorrectly derives `download?` -> NoMethodError).
    authorize @document, :show?
    version = if params[:version_id]
                @document.document_versions.find(params[:version_id])
              else
                @document.current_version
              end

    # Check whether the file is attached
    if version.document_version_file.attached?
      # Serve via the authorized proxy instead of the unprotected default blob route.
      redirect_to helpers.document_version_download_path(version)
    else
      flash[:alert] = t('flash.documents.no_file_for_version')
      redirect_to organisation_project_document_path(@current_organisation, @project, @document)
    end
  end

  def create_version
    # Creating a version = modifying the document: explicit :update? (no :create_version? in the
    # policy; the implicit Pundit action name would raise NoMethodError). In addition to the
    # area_access? check in authorize_project_access! (defense-in-depth).
    authorize @document, :update?
    actor = Actors::SaveDocumentVersion.new(document: @document, params: version_params, current_user: current_user)
    result = actor.call

    @document = actor.record

    if result.success?
      respond_after_successfull_save(@project, @document)
    else
      # Surface the real validation errors (result.errors) through the global
      # #flash container. The previous branch rendered a static label into a
      # non-existent Turbo target (`version-form-errors`) and fell back to
      # `render :show` against a template that does not exist (-> 500).
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.prepend(
            'flash',
            partial: 'layouts/flash',
            locals: { flash: { alert: result.errors.to_sentence } }
          ), status: :unprocessable_entity
        end
        format.html do
          redirect_to organisation_project_knowledge_index_path(
            @current_organisation, @project, document_id: @document.id, type: 'all'
          ), alert: result.errors.to_sentence
        end
      end
    end
  end

  # "als aktuell setzen" (doc/dokumentansicht_plan.md, S2): one pointer moves.
  # A trivial write, so it stays here (CLAUDE.md, the seam rule). The document's
  # title IS the current version's title, so the knowledge row is re-rendered
  # together with the frame, which respond_after_successfull_save already does.
  # Setting current = modifying the document: :update?, as create_version.
  def set_current_version
    authorize @document, :update?
    version = @document.document_versions.find_by(id: params[:version_id])
    if version.nil?
      redirect_to organisation_project_knowledge_index_path(@current_organisation, @project, document_id: @document.id, type: 'all'),
                  alert: t('flash.documents.version_not_found')
      return
    end

    @document.update!(current_version: version)
    respond_after_successfull_save(@project, @document)
  end

  # One version of the document in the lane (doc/dateivorschau_plan.md, S1).
  # Reading = :show?. A frame request renders the frame with the preview root, the
  # same root the knowledge page renders for ?document_id=X&preview=V; a plain
  # request lands on that page state. A version that is not this document's
  # answers 404, foreign and missing alike.
  def preview
    authorize @document, :show?
    version = @document.document_versions.find_by(id: params[:version_id])
    return head :not_found if version.nil?

    if params[:frame] == 'content'
      frame_id = detail_frame_id
      render html: helpers.turbo_frame_tag(frame_id) {
        helpers.render(partial: 'organisations/documents/preview', formats: [:html],
                       locals: { document: @document, version: version, detail_frame_id: frame_id })
      }.html_safe, layout: false
      return
    end

    redirect_to organisation_project_knowledge_index_path(
      @current_organisation, @project, document_id: @document.id, KnowledgeFilterHelper::PREVIEW_PARAM => version.id, type: 'all'
    )
  end

  def download_plain_text
    # Reading the text version = :show? (no :download_plain_text? in the policy).
    authorize @document, :show?
    @version = @document.document_versions.find(params[:version_id])
    if @version.plain_text_version.present?
      send_data @version.plain_text_version, filename: "#{@version.title}.txt", type: 'text/plain', disposition: 'attachment'
    else
      redirect_to organisation_project_document_path(@current_organisation, @project, @document), alert: t('flash.documents.no_text_version')
    end
  end

  # The small, viewer-specific fragment polled while its text or another run
  # is pending. Every refresh asks both rights again, as the start does.
  def glossary_source
    document = @project.documents.find(params[:id])
    authorize document, :show?
    return head :forbidden unless policy(GlossaryExtractionRun).start?

    raise ActiveRecord::RecordNotFound unless document.current_version

    render partial: 'organisations/documents/glossary_source', formats: [:html], locals: { document: document }
  end

  # K5c: a glossary run over this document, the button in its lane. Reading
  # the document is enough of it (authorize_project_access! answers a reader
  # without it as for every action here, :show? asks it again). The glossary
  # right is asked of the current organisation, as the glossary page asks it
  # (GlossaryPolicy#start?), and answered 403 as there. A document that is not
  # this project's, or has no current version, is none at all (404). The actor
  # asks both rights again under its lock, with the current version and its
  # text; it lands on the review list (303), a refusal on the document with
  # the actor's reason.
  def propose_glossary_terms
    document = @project.documents.find(params[:id])
    authorize document, :show?
    return render(plain: t('shared.errors.not_authorized'), status: :forbidden) unless policy(GlossaryExtractionRun).start?

    version = document.current_version
    raise ActiveRecord::RecordNotFound unless version

    result = Actors::StartGlossaryExtraction.call(organisation: @current_organisation, current_user: current_user,
                                                  document_version: version)
    if result.success?
      redirect_to organisation_glossary_terms_path(@current_organisation, view: Organisations::GlossaryController::PROPOSALS_VIEW),
                  status: :see_other, notice: t('controllers.documents.propose_glossary_terms.success', title: document.title)
    else
      redirect_to organisation_project_knowledge_index_path(@current_organisation, @project, document_id: document.id, type: 'all'),
                  status: :see_other, alert: result.errors.to_sentence
    end
  end

  def destroy_version
    # Deleting a version = :destroy? (no :destroy_version? in the policy).
    authorize @document, :destroy?

    # .new(...).call because we read the outcome (#document_destroyed?) after the
    # call to pick the redirect (three success outcomes, two redirect targets).
    actor = Actors::DestroyDocumentVersion.new(document: @document, version_id: params[:version_id], current_user: current_user)
    result = actor.call

    if result.success?
      if actor.document_destroyed?
        redirect_to organisation_project_documents_path(@current_organisation, @project), notice: t('flash.documents.all_versions_deleted')
      else
        redirect_to organisation_project_document_path(@current_organisation, @project, @document), notice: t('flash.documents.version_deleted')
      end
    else
      # A foreign/missing version_id (F2) carries a ready-made message; keep the
      # existing "Error deleting the version: …" wrapper for the (near-impossible)
      # re-hang validation failure so that path stays identical.
      alert = result.code == :not_found ? result.errors.to_sentence : t('flash.documents.version_delete_error', error: result.errors.to_sentence)
      redirect_to organisation_project_document_path(@current_organisation, @project, @document), alert: alert
    end
  end

  private

  # Detail frame of the Knowledge view, the only remaining detail display for
  # documents; callers may pass their own frame id through.
  def detail_frame_id
    params[:frame_id].presence || 'knowledge_display_frame'
  end

  # Rendering for a failed document create. On Turbo the upload form goes back into
  # the detail frame with the user's input and the flash carries the error; the HTML
  # path lands on the Knowledge page with the alert. Never `render :new`: that is the
  # legacy full-page template, and Turbo would render it as a whole page (the form
  # targets `_top`).
  def respond_after_failed_create(alert)
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.update(detail_frame_id,
                              partial: 'organisations/documents/document_new_for_frame',
                              locals: { document: @document, detail_frame_id: detail_frame_id }),
          turbo_stream.prepend('flash', partial: 'layouts/flash', locals: { flash: { alert: alert } })
        ], status: :unprocessable_entity
      end
      format.html do
        redirect_to organisation_project_knowledge_index_path(@current_organisation, @project, type: 'all'),
                    alert: alert
      end
    end
  end

  # Rendering for a failed document update. D6: a validation error (e.g. a blank
  # title) now surfaces here instead of a silent fake-success. On Turbo the edit
  # frame stays open with the user's input and the flash carries the error; the
  # HTML path re-renders the edit form with the error.
  def respond_after_failed_update(result)
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.prepend(
          'flash', partial: 'layouts/flash', locals: { flash: { alert: result.errors.to_sentence } }
        ), status: :unprocessable_entity
      end
      format.html do
        flash.now[:alert] = result.errors.to_sentence
        render :edit, status: :unprocessable_entity
      end
    end
  end

  # Rendering for a successful document destroy. Identical response to before the
  # actor extraction, only now it runs AFTER the write has committed (no rendering
  # inside a transaction anymore).
  def respond_after_successful_destroy(document_id)
    respond_to do |format|
      format.turbo_stream do
        # Remove the row from the Knowledge list, clear the detail, show flash.
        render turbo_stream: [
          turbo_stream.remove_all("tr[data-item-id='#{document_id}']"),
          turbo_stream.update(
            detail_frame_id,
            partial: 'shared/empty_content',
            locals: {
              message: t('views.organisations.knowledge.index.item_deleted_document'),
              description: t('views.organisations.knowledge.index.item_deleted_description'),
              icon_class: 'bi bi-file-earmark-text'
            }
          ),
          turbo_stream.prepend('flash',
                               partial: 'layouts/flash',
                               locals: { flash: { notice: t('flash.documents.deleted') } })
        ]
      end

      format.html do
        redirect_to organisation_project_knowledge_index_path(@current_organisation, @project, type: 'document'),
                    notice: t('flash.documents.deleted')
      end
    end
  end

  # Rendering for a failed document destroy. In dev/test an unexpected error
  # re-raises inside the actor (it never reaches here); in production the actor
  # maps it to a failure Result and we surface the raw message (F3).
  def respond_after_failed_destroy(result)
    alert = t('flash.documents.delete_error_detail', error: result.errors.to_sentence)
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.prepend(
          'flash', partial: 'layouts/flash', locals: { flash: { alert: alert } }
        )
      end
      format.html do
        redirect_to organisation_project_document_path(@current_organisation, @project, @document), alert: alert
      end
    end
  end

  # Redirect index to unified Knowledge view (unless Turbo Frame request)
  # The dedicated documents list view no longer exists (not even as a frame).
  def redirect_index_to_knowledge
    redirect_to organisation_project_knowledge_index_path(
      @current_organisation, @project, type: 'document'
    )
  end

  # Determines whether read or write permissions are required for the current action
  # Overrides ProjectController#determine_required_action for custom actions
  def determine_required_action
    write_actions = %w[new create edit update destroy create_version destroy_version set_current_version]
    write_actions.include?(action_name) ? :write : :read
  end

  def set_documents
    @documents = find_documents
  end

  def set_document
    @document = @project.documents.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    flash[:alert] = t('flash.documents.not_found')
    redirect_to organisation_project_documents_path(@current_organisation, @project)
  end

  def find_documents
    # Start with a base query without sorting
    base_query = @project.documents
                         .includes(:current_version, :document_versions)
                         .where.not(current_version_id: nil)

    # We need an explicit JOIN for searching in document_versions
    # and for sorting by document_versions.title
    query = if params[:search].present? || sort_column == 'document_versions.title'
              # Add a JOIN to the document_versions table
              base_query.joins('INNER JOIN document_versions ON document_versions.id = documents.current_version_id')
            else
              # Otherwise use the normal query
              base_query
            end

    # Apply the search if present
    search_query = apply_search(query)

    # Apply sorting based on the passed parameters
    apply_sorting(search_query || query)
  end

  def document_params
    # No create_embeddings on either level: indexing is automatic since
    # doc/notizen_immer_indexiert_plan.md; the summary stays a choice.
    params.require(:document).permit(:title, :description, :tag_list, document_versions_attributes: %i[document_version_file create_summary title description])
  end

  def version_params
    params.require(:document_version).permit(:title, :description, :document_version_file, :create_summary)
  end
end
