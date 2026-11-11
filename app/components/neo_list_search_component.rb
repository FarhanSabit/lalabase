# frozen_string_literal: true

# The search of a list head that has the bar of the ticket list without its
# filter bar (user, 2026-11-11): the inbox and "Personen". A magnifier at the
# right end of the row that grows into the field on a click and stays open
# while a term stands in it (F35); the field answers while typing.
#
# Markers and stylesheet are the filter bar's (data-fb-search,
# data-fb-search-open, data-fb-depth; components/filter_bar.css), so the row
# around it carries .filter-bar. The fold is search_disclosure_controller,
# Escape included (it folds an empty field before the lane behind it closes).
#
# The form submits itself (auto-submit: debounced while typing, at once on
# Enter) into the list frame, so the field keeps its focus and every letter
# typed meanwhile. What the page needs besides the term (its list state, and
# how the address follows) is the page's:
#   content       the hidden fields of the list state, rendered inside the form
#   turbo_action  'replace' where nothing else writes the address (the inbox);
#                 none where the lane's layout-toggle follows the list frame
#                 into the address and keeps the open object there
#                 (people_page_data: list_frame_ids, list_filter_params)
#
# Before this component the inbox carried the markup alone (PR #139); the
# people page would have been the second copy and the glossary the third.
class NeoListSearchComponent < ViewComponent::Base
  WRAPPER_CLASSES = 'relative flex-shrink-0 self-center'
  BUTTON_CLASSES = 'grid place-items-center h-7 w-7 rounded-md text-muted hover:bg-cream-100 hover:text-heading ' \
                   'transition-colors focus:outline-none focus-visible:ring-2 focus-visible:ring-ink'
  INPUT_CLASSES = 'w-full h-7 pl-7 pr-2 text-[13px] rounded-md border border-cream-300 bg-surface-raised text-body ' \
                  'placeholder:text-faint focus:outline-none focus:border-ink focus:ring-2 focus:ring-ink/10 transition-colors'

  # url: the list's index; name: the parameter of the term (the inbox says
  # search, the people page q); frame: the id of the list frame; label: the
  # field's accessible name; button_label: the magnifier's (title and
  # aria-label), the label unless given; wrapper_class / wrapper_data: extra
  # classes and data on the outer box (ms-auto where nothing stands before
  # it, the inbox's tool marker).
  def initialize(url:, name:, value:, input_id:, frame:, label:, placeholder:, form_class:, button_label: nil,
                 turbo_action: nil, wrapper_class: nil, wrapper_data: {})
    super()
    @url = url
    @name = name
    @value = value.is_a?(String) ? value : nil
    @input_id = input_id
    @frame = frame
    @label = label
    @placeholder = placeholder
    @form_class = form_class
    @button_label = button_label || label
    @turbo_action = turbo_action
    @wrapper_class = wrapper_class
    @wrapper_data = wrapper_data
  end

  private

  attr_reader :url, :name, :value, :input_id, :label, :placeholder, :button_label

  # A term already typed keeps the field open: what narrows the list stays
  # visible.
  def open?
    value.present?
  end

  def wrapper_attributes
    data = { controller: 'search-disclosure', fb_search: '' }.merge(@wrapper_data)
    data[:fb_search_open] = '' if open?
    { class: [WRAPPER_CLASSES, @wrapper_class].compact.join(' '), data: data }
  end

  def form_attributes
    data = { controller: 'auto-submit', turbo_frame: @frame }
    data[:turbo_action] = @turbo_action if @turbo_action
    { url: url, method: :get, class: "#{@form_class} w-full", data: data }
  end

  def input_attributes
    { id: input_id, placeholder: placeholder, 'aria-label': label,
      data: { search_disclosure_target: 'input',
              action: 'keydown.esc->search-disclosure#close focusout->search-disclosure#blur' },
      class: INPUT_CLASSES }
  end
end
