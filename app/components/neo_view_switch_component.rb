# frozen_string_literal: true

# THE switch between the views of one page, and its one form (user,
# 2026-11-11): the tickets' Liste | Kanban, the time list's Übersicht | Liste
# and the inbox's Chronologisch | Nach Ticket gebündelt. It stands in the page
# head, first in its right group, before "···" and "?"; the main action stays
# outermost.
#
# The form is the icon pair (designer, 09.09.2026): one 30 x 30 tile per view,
# 2px apart, no container, no groove, no tint around the tiles. The groove the
# time list wore until 2026-11-11 was four signals for one statement (trough,
# plate, shadow, bold word) on a control that is used seldom, its trough was
# the selected tone and its plate a soft shadow, which in this app means "it
# floats and closes again". The inbox had a frame of its own, active in the
# selected tone too.
#
# Active: a breath of ink over whatever the head stands on (ink at 5 %) with
# the icon in ink, no weight, no shadow, no edge. Inactive: transparent, the
# icon in cream-500 (the nearest token to the designer's #8A857A, the same
# mapping the selection box made); hover and keyboard focus look like the
# active tile. The designer's tone was cream-100, the neighbours' hover tone,
# and that is the shell's own ground: on the time list, whose head stands on
# the shell and not on a white column, the active tile vanished (2026-11-11).
# The tint is one step darker than ANY ground, white, shell or dark theme,
# with one class. NEVER the selected tone (cream-200): in lists it means "this
# row is chosen", in filters "this value is set", and a switch that wears it
# devalues it there.
#
# The icons are inline SVG (15px, stroke 1.7, currentColor), not the icon
# font; :icon names one of ICONS. The caption is mandatory, not decoration:
# title and aria-label carry the word, and on keyboard focus the tooltip shows
# the same word (components/view_switch.css), or the function is unnamed for
# the keyboard. Every tile always stands: a pair is readable, a lone icon not.
#
# Two kinds of tile, decided per item by :method:
#   :get   -> a link (navigation via query param), aria-current="page" when active
#   other  -> a button_to form (a preference written on the server), like the tickets
#
# Items: { key:, icon:, title:, active:, path:, method: :get, params: {},
# disabled: false }.
class NeoViewSwitchComponent < ViewComponent::Base
  CONTAINER_CLASSES = 'inline-flex items-center gap-0.5'
  TILE_CLASSES = 'view-switch-tile h-[30px] w-[30px] rounded-md inline-flex items-center justify-center ' \
                 'transition-colors focus:outline-none focus-visible:ring-2 focus-visible:ring-ink'
  ACTIVE_CLASSES = 'bg-ink/5 text-ink'
  INACTIVE_CLASSES = 'text-cream-500 hover:bg-ink/5 hover:text-ink focus-visible:bg-ink/5 focus-visible:text-ink'
  DISABLED_CLASSES = 'opacity-30 cursor-not-allowed'

  # The signs, drawn on a 16-grid as tag name and attributes (rendered through
  # the tag helpers, nothing marked safe by hand), straight strokes and plain
  # shapes only (spec/architecture/one_icon_set_guard_spec.rb):
  #   list:   three horizontal strokes, the same list in every switch
  #   kanban: a frame with two dividers, the second shorter
  #   bars:   three columns of different height, as high as the board's frame (an overview)
  #   stack:  a card with two shorter edges behind it (bundled by ticket)
  ICONS = {
    list: [[:path, { d: 'M2.5 4h11M2.5 8h11M2.5 12h11' }]],
    kanban: [[:rect, { x: 1.85, y: 2.35, width: 12.3, height: 11.3, rx: 1.5 }],
             [:path, { d: 'M6 2.35v11.3M10.15 2.35v7.2' }]],
    bars: [[:rect, { x: 2.35, y: 8.35, width: 2.6, height: 5.3, rx: 0.6 }],
           [:rect, { x: 6.7, y: 2.35, width: 2.6, height: 11.3, rx: 0.6 }],
           [:rect, { x: 11.05, y: 5.85, width: 2.6, height: 7.8, rx: 0.6 }]],
    stack: [[:rect, { x: 1.85, y: 6.6, width: 12.3, height: 7.05, rx: 1.5 }],
            [:path, { d: 'M3.75 4.1h8.5M5.75 1.6h4.5' }]]
  }.freeze

  # label: the accessible name of the whole switch ("Ansicht"); container_class:
  # extra classes on the box (the tickets hide theirs on phones).
  def initialize(label:, items:, container_class: nil)
    super()
    @label = label
    @items = items.map { |item| { method: :get, params: {}, disabled: false }.merge(item) }
    @extra_classes = container_class
    @items.each { |item| ICONS.fetch(item[:icon].to_sym) { raise ArgumentError, "unknown icon #{item[:icon].inspect}" } }
  end

  private

  attr_reader :label, :items

  def container_classes
    [CONTAINER_CLASSES, @extra_classes].compact.join(' ')
  end

  def tile_classes(item)
    [TILE_CLASSES,
     item[:active] ? ACTIVE_CLASSES : INACTIVE_CLASSES,
     (DISABLED_CLASSES if item[:disabled])].compact.join(' ')
  end

  # The attributes every tile carries: the spoken name and the tooltip's word
  # are both the title.
  def tile_attributes(item)
    { class: tile_classes(item), title: item[:title], 'aria-label': item[:title], 'data-tip': item[:title] }
  end

  def icon_svg(item)
    drawing = safe_join(ICONS.fetch(item[:icon].to_sym).map { |name, attributes| tag.public_send(name, nil, **attributes) })
    tag.svg(drawing, viewBox: '0 0 16 16', width: 15, height: 15, fill: 'none', stroke: 'currentColor',
                     'stroke-width': '1.7', 'stroke-linecap': 'round', 'stroke-linejoin': 'round',
                     'aria-hidden': true)
  end

  def links_only?
    items.all? { |item| item[:method] == :get }
  end
end
