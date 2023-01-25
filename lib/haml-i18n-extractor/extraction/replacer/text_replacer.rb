module Haml
  module I18n
    class Extractor
      class TextReplacer
        include Helpers::StringHelpers

        TAG_REGEX = /%\w+/
        TAG_CLASSES_AND_ID_REGEX = /(?:[.#]\w+)*/
        TAG_ATTRIBUTES_REGEX = /(?:\{[^}]+\})?/

        attr_reader :full_line, :text_to_replace, :line_type

        def initialize(full_line, text_to_replace, line_type, path, metadata = {}, options = {})
          @path = path
          @orig_line = @full_line = full_line
          @text_to_replace = text_to_replace
          @metadata = metadata
          @options = options
          if LINE_TYPES_ALL.include?(line_type)
            @line_type = line_type
          else
            raise Extractor::NotDefinedLineType, "line type #{line_type} for #{full_line} does not make sense!"
          end
        end

        def result
          @result ||= build_result
        end

        def replace_hash
          #legacy
          result.info
        end

        def orig_interpolated?
          interpolated?(@orig_line)
        end

        # the new full line, including a `t()` replacement instead of the `text_to_replace` portion.
        def modified_line
          return @full_line if has_been_translated?(@full_line) && !@options[:add_filename_prefix]
          full_line = @full_line.dup
          keyname = if orig_interpolated?
                      Haml::I18n::Extractor::InterpolationHelper.new(@text_to_replace, interpolated_t_name, @options).keyname_with_vars
                    else
                      t_method
                    end
          @text_to_replace = remove_quotes_from_interpolated_text(@text_to_replace)
          gsub_replacement!(full_line, @text_to_replace, keyname)
          apply_ruby_evaling!(full_line, keyname)
          full_line
        end

        private

        def build_result
          result_class = Haml::I18n::Extractor::ReplacerResult
          expression = @line_type == :script || tag_with_code? ? @text_to_replace[1...-1] : @text_to_replace
          if expression.strip.match(/^#\{[^}]+\}$/)
            result_class.new(nil, nil, @text_to_replace, false, @path)
          else
            result_class.new(modified_line, t_name, @text_to_replace, true, @path)
          end
        end

        T_REGEX = /t\('\.(.*?)'\)/

        # the_key_to_use ( for example in t('.the_key_to_use')
        def t_name(to_replace = @text_to_replace, orig_line = @orig_line)
          text_to_replace = to_replace.dup
          if has_been_translated?(text_to_replace)
            text_to_replace.match T_REGEX
            name = normalized_name($1.dup)
          else
            # for simple strings, return the original text as the key,
            # which we'll stick inside the _t method in the template
            name = to_replace
          end

          if (@options[:add_filename_prefix])
            filename = File.basename(@path)
            path_without_filename = @path.gsub(@options[:base_path], '').gsub(filename, '')
            filename_without_leading_underscore = filename.gsub(/^_/, "")
            path_with_corrected_filename = path_without_filename.to_s + filename_without_leading_underscore.to_s
            name = path_with_corrected_filename.gsub(/(\.html)?\.haml/, '').gsub(/\//, '.') + '.' + name.gsub(/^_/, '')
          end
          name
        end

        # since the gem was assuming that the value inside the template would look like
        # t('namespaced.keyname') and doesn't extract the variables until later,
        # we need to write our own t_name method that handles variable extraction at this point
        def interpolated_t_name(to_replace = @text_to_replace, orig_line = @orig_line)
          text_to_replace = to_replace.dup
          if has_been_translated?(text_to_replace)
            text_to_replace.match T_REGEX
            name = normalized_name($1.dup)
          else
            name = interpolations
          end

          name
        end

        # recurse through the string, finding bits of interpolated ruby code
        # and use the InterpolationHelper#extract_interpolation to replace them
        # with the same variable name that will be used by InterpolationHelper#keyname_with_vars
        # and wrap each of those in {}
        def interpolations(new_string = "", str = @text_to_replace)
          return new_string if str.nil? || str.empty?
          return new_string + str if !interpolated?(str)

          scanner = StringScanner.new(str)
          scanner.scan_until(/\#{.*?}/)

          match = scanner.matched
          interpolated_code = Haml::I18n::Extractor::InterpolationHelper.new("", "").extract_interpolation(match)
          new_string += scanner.pre_match + "{#{normalized_name(interpolated_code)}}"

          interpolations(new_string, scanner.rest)
        end

        # t('.the_key_to_use')
        def t_method
          with_translate_method(t_name)
        end

        def with_translate_method(name)
          # use sprintf to allow for strings that have single quotes in them
          # and wrap strings in our custom _t method
          sprintf(%{_t("%s")}, name)
        end

        # adds the = to the right place in the string ... = t()
        def apply_ruby_evaling!(str, keyname)
          if LINE_TYPES_ADD_EVAL.include?(@line_type)
            if @line_type == :tag
              scanner = StringScanner.new(str.dup)
              scanner.skip(TAG_REGEX)
              scanner.skip(TAG_CLASSES_AND_ID_REGEX)
              scanner.skip(TAG_ATTRIBUTES_REGEX)
              if scanner.scan_until(/[\s]*#{Regexp.escape(keyname)}/)
                unless already_evaled?(scanner.pre_match)
                  str[0..-1] = "#{scanner.pre_match}=#{scanner.matched}#{scanner.post_match}"
                end
              end
            elsif @line_type == :plain || (@line_type == :script && !already_evaled?(full_line))
              str.gsub!(str, "= " + str)
            end
          end
        end

        def tag_with_code?
          @metadata[:value] && @metadata[:value][:parse]
        end

        def already_evaled?(str)
          if @line_type == :tag
            if orig_interpolated?
              # for tags that come in interpolated we need to explicitly
              # check that they aren't evaled alreay, the metadata lies
              #   %tag foo #{var} bar
              str.split('').last == '='
            else
              tag_with_code?
            end
          elsif @line_type == :script
            # we need this for tags that come in like :plain but have interpolation
            str.match(/^[\s]*=/)
          end
        end

        def has_been_translated?(str)
          str.match T_REGEX
        end

        # We end up with unwanted quotes around interpolated text
        # e.g. '"Job ##{@job.id} (#{@job.queue})"'
        # Remove them so the result is 'Job ##{@job.id} (#{@job.queue})'
        def remove_quotes_from_interpolated_text(text_to_replace)
          copy = text_to_replace
          if (orig_interpolated?)
            matches = /^"(.*)"$/.match(copy)
            copy = matches[1] if (matches)
          end
          copy
        end

        def gsub_replacement!(str, text_to_replace, keyname_method)
          # FIXME refactor this method
          scanner = StringScanner.new(str.dup)
          str[0..-1] = ''
          if line_type == :tag
            if @options[:place] == :content
              scanner.skip(TAG_REGEX)
              scanner.skip(TAG_CLASSES_AND_ID_REGEX)
              scanner.skip(TAG_ATTRIBUTES_REGEX)
            elsif @options[:place] == :attribute
              scanner.skip(TAG_REGEX)
              scanner.skip(TAG_CLASSES_AND_ID_REGEX)
              scanner.skip_until(/\b#{@options[:attribute_name]}:|:#{@options[:attribute_name]}\s*=>\s*/)
            end
          end
          scanner.scan_until(/(['"]|)#{Regexp.escape(text_to_replace)}\1/)
          str << scanner.pre_match.to_s << keyname_method << scanner.post_match.to_s
        end

      end
    end
  end
end
