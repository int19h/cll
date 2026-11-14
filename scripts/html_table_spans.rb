# frozen_string_literal: true

# Replace the full-width colspan sentinel written by
# xml/docbook2html_config_common.xsl. DocBook's HTML table stylesheets
# do not honor colspan="0", so the stylesheet writes 12321. This step
# runs from the shared HTML cleanup, before Prince, WeasyPrint, the
# online book, or the ePub sees the page. The width is the column count
# of the other rows, including cells that span rows. A sentinel must be
# the only cell in its row, with no row span.
module HtmlTableSpans
  SENTINEL = '12321'
  class Error < StandardError; end

  module_function

  def normalize!(document)
    changed = 0
    document.xpath('//*[local-name()="table"]').each do |table|
      changed += normalize_table!(table)
    end
    changed
  end

  def normalize_table!(table)
    rows = direct_rows(table)
    return 0 unless rows.any? { |row| row_cells(row).any? { |cell| cell['colspan'] == SENTINEL } }

    occupied = {}
    width = 1
    full = []
    rows.each_with_index do |row, row_number|
      cells = row_cells(row)
      sentinels = cells.select { |cell| cell['colspan'] == SENTINEL }
      unless sentinels.empty?
        rowspan = sentinels[0]['rowspan'] || '1'
        if cells.length != 1 || rowspan != '1'
          raise Error, 'A full-width sentinel must occupy its own row'
        end
        full.concat(sentinels)
        next
      end
      column = 0
      cells.each do |cell|
        column += 1 while occupied.fetch(column, 0) > row_number
        colspan = integer_span(cell['colspan'] || '1')
        rowspan = integer_span(cell['rowspan'] || '1')
        rowspan = rows.length - row_number if rowspan == 0
        raise Error, 'Invalid table span' if colspan < 1 || rowspan < 1
        colspan.times { |offset| occupied[column + offset] = row_number + rowspan }
        column += colspan
        width = column if column > width
      end
    end
    full.each { |cell| cell['colspan'] = width.to_s }
    full.length
  end

  def direct_rows(table)
    table.xpath(
      './*[local-name()="tr"]' \
      ' | ./*[local-name()="thead"]/*[local-name()="tr"]' \
      ' | ./*[local-name()="tbody"]/*[local-name()="tr"]' \
      ' | ./*[local-name()="tfoot"]/*[local-name()="tr"]'
    )
  end

  def row_cells(row)
    row.element_children.select { |cell| cell.name == 'td' || cell.name == 'th' }
  end

  def integer_span(value)
    Integer(value, 10)
  rescue ArgumentError
    raise Error, 'Invalid table span'
  end
end
