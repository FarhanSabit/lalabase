# frozen_string_literal: true

class NeoTitleBoxComponent < ViewComponent::Base
  # The box around the main action: 4 px more than the group's gap-2, so it
  # stands 12 px from its neighbour as on the tickets and the time list
  # (their ml-3), and 3 px of air to the right: a list column clips at its
  # edge (overflow auto), and the main action's offset shadow needs the room.
  TITLE_ACTION_CLASSES = 'ms-1 me-[3px] flex items-center'

  renders_one :title_action
  renders_one :center_content
  renders_one :right_content

  def initialize(
    title:,
    variant: :project, # :project or :organisation (resolves subtitle to org name)
    subtitle: nil,
    badge: nil,
    margin_top: nil,
    margin_right: nil,
    margin_left: nil,
    padding_y: nil,
    margin_bottom: 'mb-6'
  )
    @title = title
    @variant = variant
    @subtitle = subtitle
    @badge = badge
    @margin_top = margin_top
    @margin_right = margin_right
    @margin_left = margin_left
    @padding_y = padding_y
    @margin_bottom = margin_bottom
  end

  private

  def resolved_subtitle
    return @subtitle if @subtitle.present?
    return helpers.current_organisation&.name if @variant == :organisation

    nil
  end

  # The right group of the head, in one order on every page (user,
  # 2026-11-11): what the page puts there first (a view switch, "···", "?"),
  # the main action outermost, as the tickets and the time list had it since
  # 04.09.2026. Until then a title action stood before the page's tools, on
  # "Alle Meetings", Meetings, Wissen, Personen and Glossar.
  def actions
    tools = right_content? ? right_content : content.presence
    main = tag.div(title_action, class: TITLE_ACTION_CLASSES) if title_action?
    safe_join([tools, main].compact)
  end

  def gradient_style
    '' # Clean, no background gradient
  end

  def wrapper_classes
    [
      @margin_top,
      @margin_right,
      @margin_left,
      @padding_y,
      @margin_bottom
    ].compact.join(' ')
  end
end
