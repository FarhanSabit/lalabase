# frozen_string_literal: true

# A tag. No "suggestion" (dashed border) any more (Belegungstabelle B15, Befund
# 3): a proposal from outside is not a tag that is not yet saved, it is a
# question the reader has not answered, and it has its own row for that
# (F31, the filter bar's proposal row). The dashed border is unassigned.
class NeoTagComponent < ViewComponent::Base
  VARIANTS = {
    primary: 'bg-lime-200 text-cream-900 border-stroke',
    secondary: 'bg-gray-200 text-gray-800 border-gray-800',
    success: 'bg-green-100 text-green-900 border-green-900',
    danger: 'bg-red-100 text-red-900 border-red-900',
    warning: 'bg-yellow-200 text-yellow-900 border-stroke',
    info: 'bg-blue-100 text-blue-900 border-blue-900',
    neutral: 'bg-surface-raised text-gray-800 border-gray-400'
  }.freeze

  SIZES = {
    small: 'text-xs px-2 py-0.5',
    medium: 'text-sm px-3 py-1',
    large: 'text-base px-4 py-1.5'
  }.freeze

  def initialize(
    text: nil,
    variant: :primary,
    size: :medium,
    removable: false,
    href: nil,
    icon: nil,
    **options
  )
    @text = text
    @variant = variant.to_sym
    @size = size.to_sym
    @removable = removable
    @href = href
    @icon = icon
    # Loud, not silent: **options is the attribute bag, and a forgotten
    # suggestion: would otherwise land on the span as an HTML attribute.
    raise ArgumentError, 'suggestion: is gone; a proposal has its own row (NeoFilterBarComponent proposals:, F31)' if options.key?(:suggestion)

    @options = options
  end

  private

  def component_classes
    [
      base_classes,
      SIZES[@size],
      VARIANTS[@variant],
      @href ? 'hover:shadow-sm hover:-translate-x-0.5 hover:-translate-y-0.5 cursor-pointer' : nil,
      @options[:class]
    ].compact.join(' ')
  end

  def component_attributes
    attrs = @options.except(:class).dup

    if @removable || @href
      attrs[:data] ||= {}
      attrs[:data][:controller] = ['neo-tag', attrs[:data][:controller]].compact.join(' ')

      attrs[:data][:neo_tag_removable_value] = 'true' if @removable

      if @href
        attrs[:data][:neo_tag_href_value] = @href
        attrs[:data][:action] = 'click->neo-tag#navigate'
      end
    end

    attrs
  end

  def base_classes
    'inline-flex items-center gap-1.5 rounded-full font-medium border transition-all'
  end

  # What the cross removes, by name: a row of chips is a row of buttons, and "Remove"
  # five times over tells a screen reader nothing. As text, because the template
  # escapes the label: an entity in it would be read out as "&quot;".
  def remove_label
    name = helpers.text_from_html(tag_content).squish
    name.present? ? t('components.neo_tag.remove', name: name) : t('views.common.remove')
  end

  def tag_content
    @text || content
  end
end
