module Haml
  module I18n
    class Extractor

      def self.debug?
        ENV['DEBUG']
      end

      class InvalidSyntax < StandardError ; end
      class NotADirectory < StandardError ; end
      class NotDefinedLineType < StandardError ; end

      LINE_TYPES_ALL = [:text, :not_text, :loud, :silent, :element]
      LINE_TYPES_ADD_EVAL = [:text, :element]

      attr_reader :haml_reader, :haml_writer
      attr_reader :locale_hash, :yaml_tool, :type

      def initialize(haml_path, opts = {})
        @type = opts[:type]
        @prompt_per_line = opts[:prompt_per_line]
        @haml_reader = Haml::I18n::Extractor::HamlReader.new(haml_path)
        validate_haml(@haml_reader.body)
        @haml_writer = Haml::I18n::Extractor::HamlWriter.new(haml_path, {:type => @type})
        @yaml_tool = Haml::I18n::Extractor::YamlTool.new
        # hold all the processed lines
        @body = []
        # holds a line_no => {info_about_line_replacemnts_or_not}
        @locale_hash = {}
      end

      def run
        assign_replacements
        validate_haml(@haml_writer.body)
        @haml_writer.write_file
        @yaml_tool.write_file
      end

      def assign_new_body
        @haml_writer.body = new_body
      end

      def assign_yaml
        @yaml_tool.locale_hash = @locale_hash
      end

      def assign_replacements
        assign_new_body
        assign_yaml
      end

     def new_body
        @haml_reader.lines.each_with_index do |orig_line, line_no|
          process_line(orig_line,line_no)
        end
        @body.join("\n")
      end

      # this is the bulk of it:
      # where we end up setting body info and locale_hash.
      # not _write_, just set that info in memory in correspoding locations.
      # refactor more?
      def process_line(orig_line, line_no)
        orig_line.chomp!
        orig_line, whitespace = handle_line_whitespace(orig_line)
        line_type, line_match = handle_line_finding(orig_line)
        should_be_replaced, text_to_replace, locale_hash = handle_line_replacing(orig_line, line_match, line_type, line_no)
        if should_be_replaced
          if prompt_per_line?
            Haml::I18n::Extractor::Prompter.new(orig_line,text_to_replace).ask_user
            user_approves = Haml::I18n::Extractor::Prompter.new(orig_line,text_to_replace).ask_user
          else
            user_approves = true
          end
        end
        append_to_locale_hash(line_no, locale_hash)
        if user_approves
          add_to_body("#{whitespace}#{text_to_replace}")
        else
          add_to_body("#{whitespace}#{orig_line}")
        end
        return should_be_replaced
      end

      def prompt_per_line?
        !!@prompt_per_line
      end

      private

      def handle_line_replacing(orig_line, line_match, line_type, line_no)
        if line_match && !line_match.empty?
          replacer = Haml::I18n::Extractor::TextReplacer.new(orig_line, line_match, line_type)
          hash = replacer.replace_hash.dup.merge!({:path => @haml_reader.path })
          [ true, hash[:modified_line], hash ]
        else
          hash = { :modified_line => nil,:keyname => nil,:replaced_text => nil, :path => nil }
          [ false, orig_line, hash ]
        end
      end

      def append_to_locale_hash(line_no, hash)
        @locale_hash[line_no] = hash
      end

      def handle_line_finding(orig_line)
        Haml::I18n::Extractor::TextFinder.new(orig_line).process_by_regex
      end

      def handle_line_whitespace(orig_line)
        orig_line.rstrip.match(/([ \t]+)?(.*)/)
        whitespace_indentation = $1
        orig_line = $2
        [ orig_line, whitespace_indentation ]
      end

      def add_to_body(ln)
        @body << ln
      end

      def validate_haml(haml)
        parser = Haml::Parser.new(haml, Haml::Options.new)
        parser.parse
        rescue Haml::SyntaxError
          raise InvalidSyntax, "invalid syntax for haml #{@haml_reader.path}"
      end

    end
  end
end
