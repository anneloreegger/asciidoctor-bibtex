#
# Manage the current set of citations, the document settings,
# and main operations.
#

require 'bibtex'
require 'bibtex/filters'
require 'citeproc'
require 'csl/styles'
require 'latex/decode/base'
require 'latex/decode/maths'
require 'latex/decode/accents'
require 'latex/decode/diacritics'
require 'latex/decode/punctuation'
require 'latex/decode/symbols'
require 'latex/decode/greek'
require 'set'

require_relative 'CitationMacro'
require_relative 'CitationUtils'
require_relative 'StringUtils'
require_relative 'StyleUtils'

module AsciidoctorBibtex
  # This filter extends the original latex filter in bibtex-ruby to handle
  # unknown latex macros more gracefully. We could have used latex-decode
  # gem together with our custom replacement rules, but latex-decode eats up
  # all braces after it finishes all decoding. So we hack over the
  # LaTeX.decode function and insert our rules before `strip_braces`.
  class LatexFilter < ::BibTeX::Filter
    def apply(value)
      text = value.to_s
      LaTeX::Decode::Base.normalize(text)
      LaTeX::Decode::Maths.decode!(text)
      LaTeX::Decode::Accents.decode!(text)
      LaTeX::Decode::Diacritics.decode!(text)
      LaTeX::Decode::Punctuation.decode!(text)
      LaTeX::Decode::Symbols.decode!(text)
      LaTeX::Decode::Greek.decode!(text)
      text = text.gsub(/\\url\{(.+?)\}/, ' \\1 ').gsub(/\\\w+(?=\s+\w)/, '').gsub(/\\\w+(?:\[.+?\])?\s*\{(.+?)\}/, '\\1')
      LaTeX::Decode::Base.strip_braces(text)
      LaTeX.normalize_C(text)
    end
  end

  # Class used through utility method to hold data about citations for
  # current document, and run the different steps to add the citations
  # and bibliography
  class Processor
    def initialize(bibfile, links = false, style = 'ieee', locale = 'en-US',
                   numeric_in_appearance_order = false, output = :asciidoc,
                   throw_on_unknown = false)
      raise "File '#{bibfile}' is not found" unless FileTest.file? bibfile

      bibtex = BibTeX.open bibfile, filter: [LatexFilter]
      @biblio = bibtex
      @links = links
      @numeric_in_appearance_order = numeric_in_appearance_order
      @style = style
      @locale = locale
      @citations = []
      @filenames = Set.new
      @output = output
      @throw_on_unknown = throw_on_unknown

      if (output != :latex) && (output != :bibtex) && (output != :biblatex)
        @citeproc = CiteProc::Processor.new style: @style, format: :html, locale: @locale
        @citeproc.import @biblio.to_citeproc
      end
    end

    # Scan a line and process citation macros.
    def process_citation_macros(line)
      CitationMacro.extract_macros(line).each do |citation|
        @citations += citation.items.collect(&:key)
      end
      @citations.uniq!(&:to_s) # only keep each reference once
    end

    # Replace citation macros with corresponding citation texts.
    #
    # Return new text with all macros replaced.
    def replace_citation_macros(line)
      CitationMacro.extract_macros(line).each do |citation|
        line = line.gsub(citation.text, complete_citation(citation))
      end
      line
    end

    # Build the bibliography list just as bibtex.
    #
    # Return an array of texts representing an asciidoc list.
    def build_bibliography_list
      result = []
      cites.each do |ref|
        result << get_reference(ref)
        result << ''
      end
      result
    end

    # Return the complete citation text for given cite_data
    def complete_citation(cite_data)
      if (@output == :latex) || (@output == :bibtex) || (@output == :biblatex)
        result = '+++'
        cite_data.items.each do |cite|
          # NOTE: xelatex does not support "\citenp", so we output all
          # references as "cite" here unless we're using biblatex.
          result << '\\' << if @output == :biblatex
                              if cite_data.type == 'citenp'
                                'textcite'
                              else
                                'parencite'
                                                end
                            else
                              'cite'
                            end
          result << '[p. ' << cite.locator << ']' if cite.locator != ''
          result << '{' << cite.key.to_s << '},'
        end
        result = result[0..-2] if result[-1] == ','
        result << '+++'
        result
      else
        result = ''
        ob = '('
        cb = ')'

        cite_data.items.each_with_index do |cite, index|
          # before all items apart from the first, insert appropriate separator
          result << "#{separator} " unless index.zero?

          # @links requires adding hyperlink to reference
          result << "<<#{cite.key}," if @links

          # if found, insert reference information
          if @biblio[cite.key].nil?
            if @throw_on_unknown
              raise "Unknown reference: #{cite.ref}"
            else
              puts "Unknown reference: #{cite.ref}"
              cite_text = cite.ref.to_s
            end
          else
            item = @biblio[cite.key].clone
            cite_text, ob, cb = make_citation item, cite.key, cite_data, cite
           end

          result << StringUtils.html_to_asciidoc(cite_text)
          # @links requires finish hyperlink
          result << '>>' if @links
        end

        unless @links
          # combine numeric ranges
          if StyleUtils.is_numeric? @style
            result = StringUtils.combine_consecutive_numbers(result)
          end
        end

        include_pretext result, cite_data, ob, cb
      end
    end

    # Retrieve text for reference in given style
    # - ref is reference for item to give reference for
    def get_reference(ref)
      result = ''
      result << '. ' if StyleUtils.is_numeric? @style

      begin
        cptext = @citeproc.render :bibliography, id: ref
      rescue Exception => e
        puts "Failed to render #{ref}: #{e}"
      end
      result << "[[#{ref}]]" if @links
      if cptext.nil?
        return result + ref
      else
        result << cptext.first
      end

      StringUtils.html_to_asciidoc(result)
    end

    def separator
      if StyleUtils.is_numeric? @style
        ','
      else
        ';'
      end
    end

    # TODO: numerical styles does not support locators.
    # Format pages with pp/p as appropriate
    def with_pp(pages)
      return '' if pages.empty?

      if @style.include? 'chicago'
        pages
      elsif pages.include? '-'
        "pp.&#160;#{pages}"
      else
        "p.&#160;#{pages}"
      end
    end

    # Return page string for given cite
    def page_str(cite)
      result = ''
      unless cite.locator.empty?
        result << ',' unless StyleUtils.is_numeric? @style
        result << " #{with_pp(cite.locator)}"
      end

      result
    end

    def include_pretext(result, cite_data, ob, cb)
      pretext = cite_data.pretext
      pretext += ' ' unless pretext.empty? # add space after any content

      if StyleUtils.is_numeric? @style
        "#{pretext}#{ob}#{result}#{cb}"
      elsif cite_data.type == 'cite'
        "#{ob}#{pretext}#{result}#{cb}"
      else
        "#{pretext}#{result}"
      end
    end

    # Numeric citations are handled by computing the position of the reference
    # in the list of used citations.
    # Other citations are formatted by citeproc.
    def make_citation(item, ref, cite_data, cite)
      if StyleUtils.is_numeric? @style
        cite_text = if @numeric_in_appearance_order
                      (@citations.cites_used.index(cite.key) + 1).to_s
                    else
                      (sorted_cites.index(cite.key) + 1).to_s
                    end
        fc = '+[+'
        lc = '+]+'
      else
        cite_text = @citeproc.process id: ref, mode: :citation
        fc = ''
        lc = ''
      end

      if StyleUtils.is_numeric? @style
        cite_text << page_str(cite).to_s
      elsif cite_data.type == 'citenp'
        cite_text = cite_text.gsub(item.year, "#{fc}#{item.year}#{page_str(cite)}#{lc}").gsub(", #{fc}", " #{fc}")
      else
        cite_text << page_str(cite)
      end

      cite_text = cite_text.gsub(',', '&#44;') if @links # replace comma

      [cite_text, fc, lc]
    end

    # Return a list of citation references in document, sorted into order
    def sorted_cites
      @citations.sort_by do |ref|
        bibitem = @biblio[ref]

        if bibitem.nil?
          [ref]
        else
          # extract the reference, and uppercase.
          # Remove { } from grouped names for sorting.
          author = bibitem.author
          author = bibitem.editor if author.nil?
          CitationUtils.author_chicago(author).collect { |s| s.upcase.gsub('{', '').gsub('}', '') } + [bibitem.year]
        end
      end
    end

    def cites
      if StyleUtils.is_numeric?(@style) && @numeric_in_appearance_order
        @citations
      else
        sorted_cites
      end
    end
  end
end
