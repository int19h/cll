# Shared by the renderer and the gloss lint.
require 'nokogiri'

def table_row_by_words node
  newchildren = []
  merge_with_previous = false
  node.children.each do |child|
    if child.text?
      words = child.text.gsub('--',"\u00A0").split( %r{\s+} )
      # Hide ellipses for now
      words.delete('…')
      words.each_index do |word_index|
        word = words[word_index]
        td = node.document.parse("<td></td>").first

        if word =~ %r{^\s*$}
          next
        end

        # Handle dashes
        if word == '[-]'
          td.content = '-'
        elsif word == '-'
          td.content = ''
        else
          td.content = word
        end

        if merge_with_previous
          newchildren.last << td.content
          merge_with_previous = false
        else
          newchildren << td
        end

        # Handle word-hyphen-quote, i.e.: lerfu-<quote>c</quote>,
        # which should stay together
        if word_index == words.length-1 && word[-1] == "-" && child.next && !(child.next.text?) && child.next.element? && child.next.name == 'quote'
          merge_with_previous = true
        end
        # Handle word-subscript, i.e.: x<subscript>1</subscript>,
        # which should stay together
        if word_index == words.length-1 && child.next && !(child.next.text?) && child.next.element? && child.next.name == 'subscript'
          merge_with_previous = true
        end
      end
    elsif child.element?
      if merge_with_previous
        newchildren.last << child.dup
        merge_with_previous = false
      else
        newchildren << node.document.parse("<td>#{child}</td>").first
      end

      # Handle the text coming right after a subscript, i.e.: x<subscript>1</subscript>--and--x...,
      # which should be joined if it starts with "=", "-", "/" or "]"
      if child.next && child.next.text? && (child.next.text[0] == "=" || child.next.text[0] == "-" || child.next.text[0] == "/" || child.next.text[0] == "]")
          merge_with_previous = true
      end
    end
  end
  newnode = node.replace( "<tr class='#{node.name}'></tr>" ).first
  newnode.children = Nokogiri::XML::NodeSet.new( node.document, newchildren )

  return newnode
end
