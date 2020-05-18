# frozen_string_literal: true

require 'set'
require 'digest'

module Licensee
  module ContentHelper
    DIGEST = Digest::SHA1
    START_REGEX = /\A\s*/.freeze
    END_OF_TERMS_REGEX = /^[\s#*_]*end of terms and conditions[\s#*_]*$/i.freeze
    REGEXES = {
      hrs:                 /^\s*[=\-\*]{3,}\s*$/,
      all_rights_reserved: /#{START_REGEX}all rights reserved\.?$/i,
      whitespace:          /\s+/,
      markdown_headings:   /#{START_REGEX}#+/,
      version:             /#{START_REGEX}version.*$/i,
      span_markup:         /[_*~]+(.*?)[_*~]+/,
      link_markup:         /\[(.+?)\]\(.+?\)/,
      block_markup:        /^\s*>/,
      border_markup:       /^[\*-](.*?)[\*-]$/,
      comment_markup:      %r{^\s*?[/\*]{1,2}},
      url:                 %r{#{START_REGEX}https?://[^ ]+\n},
      bullet:              /\n\n\s*(?:[*-]|\(?[\da-z]{1,2}[)\.])\s+/i,
      developed_by:        /#{START_REGEX}developed by:.*?\n\n/im,
      quote_begin:         /[`'"‘“]/,
      quote_end:           /[`'"’”]/,
      cc_legal_code:       /^\s*Creative Commons Legal Code\s*$/i,
      cc0_info:            /For more information, please see\s*\S+zero\S+/im,
      cc0_disclaimer:      /CREATIVE COMMONS CORPORATION.*?\n\n/im,
      unlicense_info:      /For more information, please.*\S+unlicense\S+/im,
      mit_optional:        /\(including the next paragraph\)/i
    }.freeze
    NORMALIZATIONS = {
      lists:      { from: /^\s*(?:\d\.|\*)\s+([^\n])/, to: '- \1' },
      https:      { from: /http:/, to: 'https:' },
      ampersands: { from: '&', to: 'and' },
      dashes:     { from: /(?<!^)([—–-]+)(?!$)/, to: '-' },
      quotes:     {
        from: /#{REGEXES[:quote_begin]}+([\w -]*?\w)#{REGEXES[:quote_end]}+/,
        to:   '"\1"'
      }
    }.freeze

    # Legally equivalent words that schould be ignored for comparison
    # See https://spdx.org/spdx-license-list/matching-guidelines
    VARIETAL_WORDS = {
      'acknowledgment'  => 'acknowledgement',
      'analogue'        => 'analog',
      'analyse'         => 'analyze',
      'artefact'        => 'artifact',
      'authorisation'   => 'authorization',
      'authorised'      => 'authorized',
      'calibre'         => 'caliber',
      'cancelled'       => 'canceled',
      'capitalisations' => 'capitalizations',
      'catalogue'       => 'catalog',
      'categorise'      => 'categorize',
      'centre'          => 'center',
      'emphasised'      => 'emphasized',
      'favour'          => 'favor',
      'favourite'       => 'favorite',
      'fulfil'          => 'fulfill',
      'fulfilment'      => 'fulfillment',
      'initialise'      => 'initialize',
      'judgment'        => 'judgement',
      'labelling'       => 'labeling',
      'labour'          => 'labor',
      'licence'         => 'license',
      'maximise'        => 'maximize',
      'modelled'        => 'modeled',
      'modelling'       => 'modeling',
      'offence'         => 'offense',
      'optimise'        => 'optimize',
      'organisation'    => 'organization',
      'organise'        => 'organize',
      'practise'        => 'practice',
      'programme'       => 'program',
      'realise'         => 'realize',
      'recognise'       => 'recognize',
      'signalling'      => 'signaling',
      'sub-license'     => 'sublicense',
      'sub license'     => 'sublicense',
      'utilisation'     => 'utilization',
      'whilst'          => 'while',
      'wilful'          => 'wilfull',
      'non-commercial'  => 'noncommercial',
      'cent'            => 'percent',
      'owner'           => 'holder'
    }.freeze
    STRIP_METHODS = %i[
      cc0_optional
      unlicense_optional
      hrs
      markdown_headings
      borders
      title
      version
      url
      copyright
      title
      block_markup
      span_markup
      link_markup
      developed_by
      end_of_terms
      whitespace
      mit_optional
    ].freeze

    # A set of each word in the license, without duplicates
    def wordset
      @wordset ||= content_normalized&.scan(%r{(?:[\w\/](?:'s|(?<=s)')?)+})&.to_set
    end

    # Number of characters in the normalized content
    def length
      return 0 unless content_normalized

      content_normalized.length
    end

    # Given another license or project file, calculates the difference in length
    def length_delta(other)
      (length - other.length).abs
    end

    # Given another license or project file, calculates the similarity
    # as a percentage of words in common, minus a tiny penalty that
    # increases with size difference between licenses so that false
    # positives for long licnses are ruled out by this score alone.
    def similarity(other)
      overlap = (wordset_fieldless & other.wordset).size
      total = wordset_fieldless.size + other.wordset.size -
              fields_normalized_set.size
      (overlap * 200.0) / (total + fields_adjusted_length_delta(other) / 10)
    end

    # SHA1 of the normalized content
    def content_hash
      @content_hash ||= DIGEST.hexdigest content_normalized
    end

    # Content with the title and version removed
    # The first time should normally be the attribution line
    # Used to dry up `content_normalized` but we need the case sensitive
    # content with attribution first to detect attribuion in LicenseFile
    def content_without_title_and_version
      @content_without_title_and_version ||= begin
        @_content = nil
        ops = %i[html hrs comments markdown_headings title version]
        ops.each { |op| strip(op) }
        _content
      end
    end

    def content_normalized(wrap: nil)
      @content_normalized ||= begin
        @_content = content_without_title_and_version.downcase

        (NORMALIZATIONS.keys + %i[spelling bullets]).each { |op| normalize(op) }
        STRIP_METHODS.each { |op| strip(op) }

        _content
      end

      if wrap.nil?
        @content_normalized
      else
        Licensee::ContentHelper.wrap(@content_normalized, wrap)
      end
    end

    # Backwards compatibalize constants to avoid a breaking change
    def self.const_missing(const)
      key = const.to_s.downcase.gsub('_regex', '').to_sym
      REGEXES[key] || super
    end

    # Wrap text to the given line length
    def self.wrap(text, line_width = 80)
      return if text.nil?

      text = text.clone
      text.gsub!(REGEXES[:bullet]) { |m| "\n#{m}\n" }
      text.gsub!(/([^\n])\n([^\n])/, '\1 \2')

      text = text.split("\n").collect do |line|
        if line =~ REGEXES[:hrs]
          line
        elsif line.length > line_width
          line.gsub(/(.{1,#{line_width}})(\s+|$)/, "\\1\n").strip
        else
          line
        end
      end * "\n"

      text.strip
    end

    def self.format_percent(float)
      "#{format('%<float>.2f', float: float)}%"
    end

    def self.title_regex
      @title_regex ||= begin
        licenses = Licensee::License.all(hidden: true, psuedo: false)
        titles = licenses.map(&:title_regex)

        # Title regex must include the version to support matching within
        # families, but for sake of normalization, we can be less strict
        without_versions = licenses.map do |license|
          next if license.title == license.name_without_version

          Regexp.new Regexp.escape(license.name_without_version), 'i'
        end
        titles.concat(without_versions.compact)

        /#{START_REGEX}\(?(?:the )?#{Regexp.union titles}.*?$/i
      end
    end

    private

    def _content
      @_content ||= content.to_s.dup.strip
    end

    def strip(regex_or_sym)
      return unless _content

      if regex_or_sym.is_a?(Symbol)
        meth = "strip_#{regex_or_sym}"
        return send(meth) if respond_to?(meth, true)

        unless REGEXES[regex_or_sym]
          raise ArgumentError, "#{regex_or_sym} is an invalid regex reference"
        end

        regex_or_sym = REGEXES[regex_or_sym]
      end

      @_content = _content.gsub(regex_or_sym, ' ').squeeze(' ').strip
    end

    def strip_title
      while _content =~ ContentHelper.title_regex
        strip(ContentHelper.title_regex)
      end
    end

    def strip_borders
      normalize(REGEXES[:border_markup], '\1')
    end

    def strip_comments
      lines = _content.split("\n")
      return if lines.count == 1
      return unless lines.all? { |line| line =~ REGEXES[:comment_markup] }

      strip(:comment_markup)
    end

    def strip_copyright
      regex = Regexp.union(Matchers::Copyright::REGEX, REGEXES[:all_rights_reserved])
      strip(regex) while _content =~ regex
    end

    def strip_cc0_optional
      return unless _content.include? 'associating cc0'

      strip(REGEXES[:cc_legal_code])
      strip(REGEXES[:cc0_info])
      strip(REGEXES[:cc0_disclaimer])
    end

    def strip_unlicense_optional
      return unless _content.include? 'unlicense'

      strip(REGEXES[:unlicense_info])
    end

    def strip_end_of_terms
      body, _partition, _instructions = _content.partition(END_OF_TERMS_REGEX)
      @_content = body
    end

    def strip_span_markup
      normalize(REGEXES[:span_markup], '\1')
    end

    def strip_link_markup
      normalize(REGEXES[:link_markup], '\1')
    end

    def strip_html
      return unless respond_to?(:filename) && filename
      return unless File.extname(filename) =~ /\.html?/i

      require 'reverse_markdown'
      @_content = ReverseMarkdown.convert(_content, unknown_tags: :bypass)
    end

    def normalize(from_or_key, to = nil)
      operation = { from: from_or_key, to: to } if to
      operation ||= NORMALIZATIONS[from_or_key]

      if operation
        @_content = _content.gsub operation[:from], operation[:to]
      elsif respond_to?("normalize_#{from_or_key}", true)
        send("normalize_#{from_or_key}")
      else
        raise ArgumentError, "#{from_or_key} is an invalid normalization"
      end
    end

    def normalize_spelling
      normalize(/\b#{Regexp.union(VARIETAL_WORDS.keys)}\b/, VARIETAL_WORDS)
    end

    def normalize_bullets
      normalize(REGEXES[:bullet], "\n\n* ")
      normalize(/\)\s+\(/, ')(')
    end

    def wordset_fieldless
      @wordset_fieldless ||= wordset - fields_normalized_set
    end

    # Returns an array of strings of substitutable fields in normalized content
    def fields_normalized
      @fields_normalized ||=
        content_normalized.scan(LicenseField::FIELD_REGEX).flatten
    end

    def fields_normalized_set
      @fields_normalized_set ||= fields_normalized.to_set
    end

    def fields_adjusted_length_delta(other)
      delta = length_delta(other)
      adjusted_delta = delta - fields_normalized.size * 2
      adjusted_delta.positive? ? adjusted_delta : delta
    end
  end
end
