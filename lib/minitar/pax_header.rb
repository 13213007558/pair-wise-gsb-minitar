# frozen_string_literal: true

# Implements PAX extended (`x`) and global (`g`) headers. A header is a sequence of
# records in this format:
#
# ```
# <decimal-length><space><ascii-keyword>=<value><newline>
# ```
#
# The decimal length is the total number of bytes in the record, including the length
# itself and the terminal newline.
class Minitar::PaxHeader
  BLOCK_SIZE = 512

  DECIMAL_TIME = /\A[+-]?\d+(?:\.\d+)?\z/
  private_constant :DECIMAL_TIME

  DECIMAL_INTEGER = /\A[+-]?\d+\z/
  private_constant :DECIMAL_INTEGER

  attr_reader :attributes

  class << self
    def rational_to_decimal(value)
      sign = value.negative? ? "-" : ""
      absolute = value.abs
      integer = absolute.to_i
      remainder = absolute - integer

      return "#{sign}#{integer}" if remainder.zero?

      digits = +""

      until remainder.zero?
        remainder *= 10
        digit = remainder.to_i
        digits << digit.to_s
        remainder -= digit

        if digits.bytesize > 1000
          raise ArgumentError, "PAX decimal value has no finite representation"
        end
      end

      "#{sign}#{integer}.#{digits}"
    end

    # Creates a PaxHeader from a data stream and a PAX posix header.
    def from_stream(stream, posix_header)
      unless posix_header.pax_header? || posix_header.pax_global_header?
        raise ArgumentError, "Header must be a PAX header"
      end

      blocks = (posix_header.size.to_r / BLOCK_SIZE).ceil
      pax_content = stream.read(blocks * BLOCK_SIZE)

      if pax_content.nil? || pax_content.bytesize < posix_header.size
        raise Minitar::UnexpectedEOF, "Truncated PAX extended header"
      end

      from_data(pax_content.byteslice(0, posix_header.size))
    end

    # Creates a PaxHeader from PAX content data.
    def from_data(content)
      new(parse_content(content))
    end

    # Applies a PAX header to a PosixHeader. Deletion records (empty values) remove the
    # override; they do not set an empty value.
    def apply_to(header, attributes)
      attributes.each do |keyword, value|
        case keyword
        when "path"
          header.path = value unless value.empty?
        when "linkpath"
          header.linkname = value unless value.empty?
        when "size"
          header.size = parse_integer(value, "size") unless value.empty?
        when "uid"
          header.uid = parse_integer(value, "uid") unless value.empty?
        when "gid"
          header.gid = parse_integer(value, "gid") unless value.empty?
        when "uname"
          header.uname = value unless value.empty?
        when "gname"
          header.gname = value unless value.empty?
        when "mtime"
          header.mtime = parse_time(value) unless value.empty?
        end
      end

      header
    end

    # Merges two PAX scopes. The local scope has precedence and may delete a value from
    # the global scope with an empty record.
    def merge_attributes(global_attributes, local_attributes)
      merged = global_attributes.dup

      local_attributes.each do |keyword, value|
        if value.nil? || value.empty?
          merged.delete(keyword)
        else
          merged[keyword] = value
        end
      end

      merged
    end

    private

    def parse_content(content)
      content = content.b
      attributes = {}
      offset = 0

      while offset < content.bytesize
        space_pos = content.byteslice(offset, content.bytesize - offset).index(" ")

        unless space_pos
          raise ArgumentError, "Missing length separator in PAX header"
        end

        space_pos += offset
        length_string = content.byteslice(offset, space_pos - offset)

        unless length_string.match?(/\A[0-9]+\z/) && !length_string.empty?
          raise ArgumentError, "Invalid length format in PAX header"
        end

        length = length_string.to_i
        minimum_length = length_string.bytesize + 1

        if length < minimum_length
          raise ArgumentError, "Invalid PAX record length"
        end

        if offset + length > content.bytesize
          raise ArgumentError, "Truncated PAX record"
        end

        record = content.byteslice(offset, length)

        unless record.byteslice(-1) == "\n"
          raise ArgumentError, "Missing record newline in PAX header"
        end

        keyword_value = record.byteslice(minimum_length, length - minimum_length - 1)
        equal_pos = keyword_value.index("=")

        unless equal_pos
          raise ArgumentError, "Missing value separator in PAX header"
        end

        keyword = keyword_value.byteslice(0, equal_pos)
        value = keyword_value.byteslice(equal_pos + 1, keyword_value.bytesize - equal_pos - 1)

        if keyword.empty? || keyword.include?("\n")
          raise ArgumentError, "Invalid keyword in PAX header"
        end

        attributes[keyword] = value
        offset += length
      end

      attributes
    end

    def parse_integer(value, keyword)
      unless value.match?(DECIMAL_INTEGER)
        raise ArgumentError, "Invalid PAX #{keyword}: #{value.inspect}"
      end

      value.to_i
    end

    def parse_time(value)
      unless value.match?(DECIMAL_TIME)
        raise ArgumentError, "Invalid PAX mtime: #{value.inspect}"
      end

      Rational(value)
    end
  end

  # Creates a new PaxHeader from attributes hash.
  def initialize(attributes = {})
    @attributes = attributes.transform_keys(&:to_s)
  end

  # The size value from PAX attributes.
  def size
    return if @attributes["size"].nil? || @attributes["size"].empty?
    @attributes["size"].to_i
  end

  # The path value from PAX attributes.
  def path = @attributes["path"]

  # The link path value from PAX attributes.
  def linkpath = @attributes["linkpath"]

  # The exact modification time as a Rational. Use #attributes to access the original
  # decimal representation.
  def mtime
    value = @attributes["mtime"]
    return if value.nil? || value.empty?
    self.class.send(:parse_time, value.to_s)
  end

  # Returns the binary PAX header content.
  def to_s
    @attributes.map {
      record_for(_1.to_s, encode_value(_2))
    }.join.force_encoding(Encoding::BINARY)
  end

  private

  def record_for(keyword, value)
    suffix = " #{keyword}=#{value}\n".b
    length = suffix.bytesize

    loop do
      record = "#{length}#{suffix}".b
      break record if record.bytesize == length
      length = record.bytesize
    end
  end

  def encode_value(value)
    case value
    when Rational
      rational_to_decimal(value)
    when Numeric
      value.to_s
    else
      value.to_s
    end
  end

  def rational_to_decimal(value)
    self.class.rational_to_decimal(value)
  end
end
