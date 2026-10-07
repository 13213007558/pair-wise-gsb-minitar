# frozen_string_literal: true

# Implements PAX global (+g+) and per-entry (+x+) extended headers.
class Minitar::PaxHeader
  BLOCK_SIZE = 512

  attr_reader :attributes

  class << self
    def from_stream(stream, posix_header)
      unless posix_header.pax_header?
        raise ArgumentError, "Header must be a PAX header"
      end

      raise ArgumentError, "PAX header size must be positive" if posix_header.size <= 0

      pax_block = ((posix_header.size + BLOCK_SIZE - 1) / BLOCK_SIZE) * BLOCK_SIZE
      pax_content = stream.read(pax_block)

      if pax_content.nil? || pax_content.bytesize < posix_header.size
        raise Minitar::InvalidTarStream
      end

      from_data(pax_content.byteslice(0, posix_header.size))
    end

    def from_data(content) = new(parse_content(content))

    def valid_keyword!(keyword)
      return if keyword.bytesize.positive? &&
        keyword.ascii_only? &&
        !keyword.include?(" ") &&
        !keyword.include?("=") &&
        !keyword.include?("\n")

      raise ArgumentError, "Invalid keyword in PAX header: #{keyword.inspect}"
    end

    private

    def parse_content(content)
      content = content.to_s.b
      attributes = {}
      offset = 0

      while offset < content.bytesize
        remaining = content.byteslice(offset, content.bytesize - offset)
        relative_space = remaining.index(" ")
        raise ArgumentError, "Missing length separator in PAX header" unless relative_space

        length_str = content.byteslice(offset, relative_space)
        unless length_str.match?(/\A\d+\z/)
          raise ArgumentError, "Invalid length format in PAX header: #{length_str.inspect}"
        end

        length = Integer(length_str, 10)
        if length <= 0 || offset + length > content.bytesize
          raise ArgumentError, "Length beyond PAX header: #{length_str}"
        end

        record = content.byteslice(offset, length)
        raise ArgumentError, "Missing newline in PAX header" unless record.end_with?("\n")

        keyword_value = record.byteslice(relative_space + 1, length - relative_space - 2)
        equal_pos = keyword_value.index("=")
        raise ArgumentError, "Missing keyword separator in PAX header" unless equal_pos

        keyword = keyword_value.byteslice(0, equal_pos)
        valid_keyword!(keyword)
        value = keyword_value.byteslice(equal_pos + 1, keyword_value.bytesize - equal_pos - 1)
        attributes[keyword] = value

        offset += length
      end

      raise ArgumentError, "Truncated record in PAX header" if offset != content.bytesize
      attributes
    end
  end

  def initialize(attributes = {})
    @attributes = attributes.transform_keys(&:to_s).transform_values(&:to_s)
  end

  def size = integer_attribute("size")
  def path = @attributes["path"]
  def linkpath = @attributes["linkpath"]
  def uid = integer_attribute("uid")
  def gid = integer_attribute("gid")
  def uname = @attributes["uname"]
  def gname = @attributes["gname"]

  # Returns decimal times as Rational so no precision is lost to Float.
  def mtime = decimal_attribute("mtime")
  def atime = decimal_attribute("atime")
  def ctime = decimal_attribute("ctime")

  def to_s
    @attributes.map do |keyword, value|
      keyword = keyword.to_s
      self.class.valid_keyword!(keyword)

      suffix = " #{keyword}=#{value}\n".b
      total = suffix.bytesize + 1

      loop do
        candidate = suffix.bytesize + total.to_s.bytesize
        raise ArgumentError, "Unable to encode PAX header length" if candidate < total
        break if candidate == total
        total = candidate
      end

      record = "#{total}#{suffix}"
      if record.bytesize != total
        raise ArgumentError, "Invalid PAX header record length"
      end
      record
    end.join
  end

  private

  def integer_attribute(name)
    value = @attributes[name]
    return if value.nil?
    unless value.match?(/\A\d+\z/)
      raise ArgumentError, "Invalid decimal integer in PAX #{name}: #{value.inspect}"
    end
    Integer(value, 10)
  end

  def decimal_attribute(name)
    value = @attributes[name]
    return if value.nil?
    unless value.match?(/\A-?\d+(?:\.\d+)?\z/)
      raise ArgumentError, "Invalid decimal time in PAX #{name}: #{value.inspect}"
    end
    Rational(value)
  end
end
