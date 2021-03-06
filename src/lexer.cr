require "./definitions"
require "./errors"
require "./location"
require "./token"

module Runic
  struct Lexer
    NUMBER_SUFFIXES = {
      "l"    => "long",
      "ul"   => "ulong",
      "i"    => "i32",
      "u"    => "u32",
      "i8"   => "i8",
      "u8"   => "u8",
      "i16"  => "i16",
      "u16"  => "u16",
      "i32"  => "i32",
      "u32"  => "u32",
      "i64"  => "i64",
      "u64"  => "u64",
      "i128" => "i128",
      "u128" => "u128",
      "f"    => "f64",
      "f16"  => "f16",
      "f32"  => "f32",
      "f64"  => "f64",
    }

    KEYWORDS = %w(
      alias
      begin
      case
      class
      def
      do
      if
      else
      elsif
      end
      extern
      match
      module
      mutable
      private
      protected
      public
      raise
      require
      rescue
      return
      struct
      then
      unless
      until
      when
      while
    )

    @char : Char?
    @previous_char : Char?
    @previous_previous_char : Char?

    def initialize(@source : IO, file = "MEMORY", @interactive = false)
      @location = Location.new(file, line: 1, column: 1)
    end

    def next
      skip_space

      char = peek_char
      location = @location

      case char
      when nil
        Token.new(:eof, "", location)
      when .ascii_letter?
        identifier = consume_identifier
        if KEYWORDS.includes?(identifier)
          Token.new(:keyword, identifier, location)
        elsif peek_char == ':'
          skip
          Token.new(:kwarg, identifier, location)
        else
          Token.new(:identifier, identifier, location)
        end
      when .number?
        value, type = consume_number, consume_optional_number_suffix
        if type.try(&.starts_with?("f")) ||
            value.includes?('.') ||
            (!value.starts_with?('0') && value.includes?('e'))
          Token.new(:float, value, location, type)
        else
          Token.new(:integer, value, location, type)
        end
      when '"'
        Token.new(:string, consume_string, location)
      when '~', '!', '+', '-', '*', '/', '<', '>', '=', '%', '&', '|', '^'
        Token.new(:operator, consume_operator, location)
      when '['
        if prev_char == '#'
          Token.new(:attribute, consume_attribute.to_s, location)
        else
          Token.new(:mark, consume.to_s, location)
        end
      when '.', ',', ':', '(', ')', '{', '}', ']'
        Token.new(:mark, consume.to_s, location)
      when '@'
        Token.new(:ivar, consume_ivar, location)
      when '\n', '\r'
        if @interactive
          # interactive mode: skip linefeed immediately, don't wait for
          # potential future linefeeds:
          skip_linefeed
        else
          # compile mode: group has many linefeeds as possible:
          skip_whitespace(semicolon: false)
        end
        Token.new(:linefeed, "", location)
      when ';'
        skip_whitespace(semicolon: true)
        Token.new(:semicolon, ";", location)
      when '#'
        str = consume_comment
        if str.empty? && peek_char == '['
          Token.new(:attribute, consume_attribute.to_s, location)
        else
          Token.new(:comment, str, location)
        end
      else
        raise SyntaxError.new("unexpected character #{char.inspect}", location)
      end
    end

    # Picks next char once, the location is already pointing to this char, so
    # it's not updated.
    private def peek_char
      @char ||= @source.read_char
    end

    private def prev_char
      @previous_char
    end

    private def rewind_to_prev_char
      @source.seek(-1, IO::Seek::Current)
      @char = @previous_char
      @previous_char = @previous_previous_char
    end

    # Picks the previously peeked character and consumes it or directly consumes
    # a char from the source. Since the char is consumed the location is updated
    # to point to the next char.
    private def consume
      if char = @char
        @char = nil
      else
        char = @source.read_char
      end

      if char == '\n'
        @location.increment_line
      else
        @location.increment_column
      end

      @previous_previous_char = @previous_char
      @previous_char = char
    end

    # Consumes the previously peeked char or consumes a char from the source,
    # discarding the char altogether. The location is updated to point to the
    # next char.
    private def skip : Nil
      consume
    end

    private def consume_identifier
      consume_while { |c| c.ascii_alphanumeric? || c == '_' }
    end

    private def consume_ivar
      consume # '@'
      consume_identifier
    end

    private def consume_number
      String.build do |str|
        if peek_char == '0'
          location = @location
          consume

          case peek_char
          when 'x'
            consume_hexadecimal_number(str)
          when 'o'
            consume_octal_number(str)
          when 'b'
            consume_binary_number(str)
          else
            if peek_char.nil? || !('0'..'9').includes?(peek_char.not_nil!)
              str << '0'
            end
            consume_decimal_number(str)
          end
        else
          consume_decimal_number(str)
        end
      end
    end

    private def consume_hexadecimal_number(str)
      str << '0'
      str << consume # x
      consume_number_while(str) do |char|
        case char
        when '0'..'9', 'a'..'f', 'A'..'F'
          str << consume
        else
          # shut up, crystal
        end
      end
      raise SyntaxError.new("expected hexadecimal number", @location) if str.bytesize == 2
    end

    private def consume_octal_number(str)
      str << '0'
      str << consume # o
      consume_number_while(str) do |char|
        case char
        when '0'..'7'
          str << consume
        else
          # shut up, crystal
        end
      end
      raise SyntaxError.new("expected octal number", @location) if str.bytesize == 2
    end

    private def consume_binary_number(str)
      str << '0'
      str << consume # b
      consume_number_while(str) do |char|
        case char
        when '0', '1'
          str << consume
        else
          # shut up, crystal
        end
      end
      raise SyntaxError.new("expected binary number", @location) if str.bytesize == 2
    end

    private def consume_decimal_number(str)
      found_dot = 0
      found_exp = 0

      consume_number_while(str) do |char|
        if found_dot == 1
          if char.number?
            found_dot += 1
          else
            raise SyntaxError.new("unexpected character: #{char}", @location)
          end
        end

        if found_exp > 0
          found_exp += 1
        end

        case char
        when .ascii_number?
          str << consume
        when '.'
          if found_dot == 0
            found_dot += 1
            skip # .

            unless peek_char.try(&.ascii_number?)
              # method call / field accessor
              rewind_to_prev_char
              break
            end

            str << '.'
          else
            # method call / field accessor (maybe)
            break
          end
        when 'e', 'E'
          if found_exp == 0
            found_exp += 1
            str << consume
          else
            raise SyntaxError.new("unexpected character: #{char}", @location)
          end
        when '-', '+'
          if found_exp == 2
            # exponential sign
            str << consume
          else
            # operator
            break
          end
        else
          # shut up, crystal
        end
      end
    end

    private def consume_number_while(str)
      significant = false

      while char = peek_char
        if char == '0' && !significant
          # skip leading zero
          skip
          next
        end

        if yield(char)
          significant = true
          next
        end

        case char
        when '_'
          skip
        when 'i', 'u', 'l', 'f'
          break
        else
          break if terminated_number?
          raise SyntaxError.new("unexpected character: #{char}", @location)
        end
      end
    end

    private def consume_optional_number_suffix
      case peek_char
      when 'i', 'u', 'l', 'f'
        location = @location

        suffix = String.build do |str|
          str << consume
          while char = peek_char
            case char
            when '1', '2', '3', '4', '6', '8', 'l'
              str << consume
            else
              break if terminated_number?
              raise SyntaxError.new("unexpected character #{char}", @location)
            end
          end
        end

        NUMBER_SUFFIXES[suffix]? ||
          raise SyntaxError.new("invalid type suffix: #{suffix}", location)
      else
        # shut up crystal
      end
    end

    private def terminated_number?
      case peek_char
      when nil
        true
      when '.', '=', '~', '!', '+', '-', '*', '/', '%', '&', '|', '^', '<', '>', ')', ';', ',', .ascii_whitespace?
        true
      else
        false
      end
    end

    private def consume_attribute
      skip # '['

      value = String.build do |str|
        loop do
          case peek_char
          when ']'
            skip # ']'
            break
          when '\n', '\r'
            raise SyntaxError.new("unexpected linefeed in attribute declaration", @location)
          else
            str << consume
          end
        end
      end

      if peek_char == '\n' || peek_char == '\r'
        skip_linefeed
      else
        raise SyntaxError.new("expected linefeed after attribute declaration", @location)
      end

      value.to_s
    end

    private def consume_comment
      leading_indent = 0
      pending_linefeed = false

      String.build do |str|
        first = true
        loop do
          skip # '#'

          if peek_char == '['
            # attribute
            break
          end

          if first
            first = false
            # count leading spaces and skip them:
            while peek_char == ' '
              skip
              leading_indent += 1
            end
          else
            # skip leading spaces (previously counted):
            leading_indent.times do
              if peek_char == ' '
                skip
              else
                break
              end
            end
          end

          str << '\n' if pending_linefeed
          pending_linefeed = false

          consume_until(str) { |c| c == '\n' || c == '\r' || c.nil? }
          break if peek_char.nil?

          skip_linefeed
          skip_space

          # multiline comment?
          if peek_char == '#'
            pending_linefeed = true
          else
            break
          end
        end
      end
    end

    private def consume_string
      skip # "

      String.build do |str|
        loop do
          case peek_char
          when '"'
            skip # "
            break
          when '\\'
            location = @location
            skip # \
            case peek_char
            when 'a'  then skip; str << 0x07.unsafe_chr   # bell (BEL)
            when 'b'  then skip; str << 0x08.unsafe_chr   # backspace (BS)
            when 'e'  then skip; str << 0x1B.unsafe_chr   # escape (ESC)
            when 'f'  then skip; str << 0x0C.unsafe_chr   # form feed (FF)
            when 'n'  then skip; str << 0x0A.unsafe_chr   # newline (LF)
            when 'r'  then skip; str << 0x0D.unsafe_chr   # carriage return (CR)
            when 't'  then skip; str << 0x09.unsafe_chr   # horizontal tab (TAB)
            when 'v'  then skip; str << 0x0B.unsafe_chr   # vertical tab (VT)
            when '\\' then skip; str << 0x5C.unsafe_chr   # backslash
            when '\'' then skip; str << 0x27.unsafe_chr   # single quote
            when '"'  then skip; str << 0x22.unsafe_chr   # double quote
            when '0', '1', '2', '3', '4', '5', '6', '7'   # octal bit pattern (1-3 octal digits)
              str << consume_octal_codepoint(location)
            when 'x'                                      # hexadecimal bit pattern (1-2 hexadecimal digits)
              skip # x
              str << consume_hexadecimal_codepoint(2) do
                raise SyntaxError.new("invalid hexadecimal codepoint in string literal", location)
              end
            when 'u'                                      # unicode character(s) (1-6 hexadecimal digits)
              skip # u
              if peek_char == '{'
                consume_unicode_codepoints { |char| str << char }
              else
                str << consume_unicode_codepoint(location)
              end
            else
              raise SyntaxError.new("unknown escape sequence in string literal", location)
            end
          when nil
            raise SyntaxError.new("unterminated string literal", @location)
          else
            str << consume
          end
        end
      end
    end

    private def consume_octal_codepoint(location : Location) : Char
      String.build(3) do |str|
        3.times do
          case peek_char
          when '0', '1', '2', '3', '4', '5', '6', '7'
            str << consume
          else
            break
          end
        end
      end.to_i(8).unsafe_chr
    rescue
      raise SyntaxError.new("invalid octal codepoint in string literal", location)
    end

    private def consume_hexadecimal_codepoint(n : Int32) : Char
      String.build(n) do |str|
        n.times do
          case peek_char
          when '0', '1', '2', '3', '4', '5', '6', '7', '8', '9',
               'a', 'b', 'c', 'd', 'e', 'f',
               'A', 'B', 'C', 'D', 'E', 'F'
            str << consume
          else
            break
          end
        end
      end.to_i(16).unsafe_chr
    rescue
      yield
    end

    private def consume_unicode_codepoint(location : Location) : Char
      consume_hexadecimal_codepoint(6) do
        raise SyntaxError.new("invalid unicode codepoint in string literal", location)
      end
    end

    private def consume_unicode_codepoints : Nil
      skip # {

      loop do
        skip_whitespace(semicolon: false)
        if peek_char == '}'
          skip # }
          break
        end
        yield consume_unicode_codepoint(@location)
      end
    end

    private def consume_operator
      location = @location

      operator = String.build do |str|
        char = consume
        str << char

        loop do
          case peek_char
          when '+', '-', '*', '/', '<', '>', '=', '%', '^', '&', '|'
            str << (char = consume)
          else
            break
          end
        end
      end

      unless OPERATORS::ALL.includes?(operator) || operator.each_char.all? { |c| c == '*' }
        raise SyntaxError.new("invalid operator #{operator}", location)
      end

      operator
    end

    private def consume_while
      String.build do |str|
        consume_while(str) { |c| yield c }
      end
    end

    private def consume_while(str)
      loop do
        char = peek_char
        if char && yield(char)
          str << consume
        else
          break
        end
      end
    end

    private def consume_until(str)
      consume_while(str) { |char| !yield char }
    end

    private def skip_whitespace(semicolon)
      while char = peek_char
        break unless char.ascii_whitespace? || (semicolon && char == ';')
        skip
      end
    end

    private def skip_linefeed
      skip if peek_char == '\r'
      skip if peek_char == '\n'
    end

    private def skip_space
      while peek_char == ' '
        skip
      end
    end
  end
end
