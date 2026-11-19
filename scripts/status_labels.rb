#!/usr/bin/env ruby
# Shared status-label table for the Typst and ConTeXt converters (issue #47).
#
# Both converters read the DocBook sources directly (not the HTML), so they
# need the same token-to-label mapping that xml/docbook2html_config_common.xsl
# carries in its cll.status.label template (the one source of truth for the
# XSL outputs). This file is the one Ruby copy both converters share; it is
# not a third and fourth copy. scripts/test-status-rendering.py checks it
# against the XSL table, the CSS margin glyphs and docs/status-markup.md.
#
# The helpers below mirror the XSL templates field for field:
#   - condition whitespace: the XSL deletes every XML-whitespace character
#     before splitting, so parse_condition does the same;
#   - label: token label, plus ", Body" for an explicit body: the primary
#     label does not already name, plus ", date" where one exists;
#   - also: comma-separated tokens rendered as comma-separated labels;
#   - glyph: the same per-status margin mark the print CSS uses, so the
#     experimental PDFs match the Prince and WeasyPrint PDFs in black
#     and white (docs/status-markup.md lists the shapes).

module StatusLabels
  LABELS = {
    'llg-ratified' => "Ratified by the LLG",
    'bpfk-approved' => "Approved by the BPFK",
    'checkpointed' => "BPFK checkpoint",
    'de-facto' => "Established usage",
    'proposed' => "Proposal",
    'unsettled' => "Open question",
    'editorial' => "This edition's choice",
    'historical' => "First-edition rule",
  }.freeze

  BODY_LABELS = {
    'llg' => "LLG",
    'bpfk' => "BPFK",
    'community' => "Community",
  }.freeze

  # The body a primary label already names, if any: "Ratified by the LLG",
  # "Approved by the BPFK" and "BPFK checkpoint" name theirs; the other
  # labels name none (mirrors the XSL cll.status.body.named template).
  NAMED_BODIES = {
    'llg-ratified' => 'llg',
    'bpfk-approved' => 'bpfk',
    'checkpointed' => 'bpfk',
  }.freeze

  # Margin marks, one shape per status (mirrors assets/css/master.css and
  # docs/status-markup.md): never by colour alone, so black-and-white
  # print still tells the statuses apart.
  GLYPHS = {
    'llg-ratified' => "\u2605",
    'bpfk-approved' => "\u25CF",
    'checkpointed' => "\u25A0",
    'de-facto' => "\u25C6",
    'proposed' => "\u25B3",
    'unsettled' => "?",
    'editorial' => "\u25B2",
    'historical' => "\u25C7",
  }.freeze

  BARE_GLYPH = "\u25C6".freeze

  # A status note or mark as the renderers show it. Nil when there is
  # nothing to label (no condition, or an unknown token, which the lint
  # rejects in real sources); callers keep the generic mark then.
  Note = Struct.new(:token, :label_text, :also_line, :inline_short, :glyph, keyword_init: true)

  def self.parse_condition(condition)
    fields = {}
    condition.to_s.delete(" \t\n\r").split(';').each do |part|
      next if part.empty?
      key, value = part.split(':', 2)
      next if value.nil? || value.empty?
      fields[key] = value unless fields.key?(key)
    end
    fields
  end

  def self.describe(condition)
    fields = parse_condition(condition)
    token = fields['status'].to_s
    return nil unless LABELS.key?(token)

    also = fields['also'].to_s.split(',').reject(&:empty?)
    return nil unless also.all? { |t| LABELS.key?(t) }

    date = fields['date'].to_s
    explicit = fields['body'].to_s
    visible = (!explicit.empty? && explicit != NAMED_BODIES[token] ? ", #{BODY_LABELS.fetch(explicit, explicit)}" : '')
    label = LABELS[token] + visible + (date.empty? ? '' : ", #{date}")
    also_labels = also.map { |t| LABELS[t] }.join(', ')
    Note.new(
      token: token,
      label_text: label,
      also_line: also_labels.empty? ? '' : "also: #{also_labels}",
      inline_short: "[#{label}]",
      glyph: GLYPHS[token]
    )
  end
end
