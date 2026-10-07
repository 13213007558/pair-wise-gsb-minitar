# frozen_string_literal: true

# The class that writes a tar format archive to a data stream.
class Minitar::Writer
  BLOCK_SIZE = Minitar::PosixHeader::BLOCK_SIZE
  MAX_OCTAL_FIELD_VALUE = 0o77777777777

  # The exception raised when the user attempts to write more data to a BoundedWriteStream
  # than has been allocated.
  WriteBoundaryOverflow = Class.new(Minitar::Error)

  # A stream wrapper that can only be written to. Any attempt to read from this restricted
  # stream will result in a NameError being thrown.
  class WriteOnlyStream
    def initialize(io)
      @io = io
    end

    def write(data) = @io.write(data)
  end

  private_constant :WriteOnlyStream

  # A WriteOnlyStream that also has a size limit.
  class BoundedWriteStream < WriteOnlyStream
    # The maximum number of bytes that may be written to this data stream.
    attr_reader :limit
    # The current total number of bytes written to this data stream.
    attr_reader :written

    def initialize(io, limit)
      @io = io
      @limit = limit
      @written = 0
    end

    def write(data)
      size = data.bytesize
      raise WriteBoundaryOverflow if (size + @written) > @limit
      @io.write(data)
      @written += size
      size
    end
  end

  private_constant :BoundedWriteStream

  # With no associated block, Writer::open is a synonym for Writer::new. If the optional
  # code block is given, it will be passed the new _writer_ as an argument and the Writer
  # object will automatically be closed when the block terminates. In this instance,
  # Writer::open returns the value of the block.
  #
  # :call-seq:
  #    Minitar::Writer.open(io) -> writer
  #    Minitar::Writer.open(io) { |writer| block } -> obj
  def self.open(io) # :yields: Writer
    writer = new(io)
    return writer unless block_given?

    # This exception context must remain, otherwise the stream closes on open even if
    # a block is not given.
    begin
      yield writer
    ensure
      writer.close
    end
  end

  # Creates and returns a new Writer object.
  def initialize(io)
    @io = io
    @closed = false
  end

  # Writes a PAX extended header. +scope+: +:global+ writes a +g+ header that
  # applies until overridden or removed; +:entry+ writes an +x+ header for the
  # next file entry. Empty values remove the corresponding override.
  def write_pax_header(attributes, scope: :entry)
    raise Minitar::ClosedStream if @closed
    unless %i[entry global].include?(scope)
      raise ArgumentError, "PAX scope must be :entry or :global"
    end

    content = Minitar::PaxHeader.new(attributes).to_s
    raise ArgumentError, "PAX header cannot be empty" if content.empty?

    name = scope == :global ? "./PaxHeaders.X/global" : "./PaxHeaders.X/next"
    header = {
      name: name,
      prefix: "",
      mode: 0o644,
      mtime: 0,
      size: content.bytesize,
      typeflag: scope == :global ? "g" : "x"
    }

    @io.write(Minitar::PosixHeader.new(header).to_s)
    @io.write(content)
    @io.write("\0" * ((BLOCK_SIZE - (content.bytesize % BLOCK_SIZE)) % BLOCK_SIZE))
    self
  end

  # Adds a file to the archive as `name`. The data can be provided in `opts[:data]` or
  # provided to a BoundedWriteStream that is yielded to the provided block.
  #
  # If `opts[:data]` is provided, all other values to `opts` are optional. If the data is
  # provided to the yielded BoundedWriteStream, `opts[:size]` must be provided.
  #
  # Valid parameters to `opts` are:
  #
  # - `:data` (_optional_): The data to write to the archive.
  # - `:mode`: The Unix file permissions mode value. If not provided, defaults to `0o644`.
  # - `:size`: The size, in bytes. If `:data` is provided, this parameter may be ignored
  #            (if it is less than the size of the data provided) or used to add padding
  #            (if it is greater than the size of the data provided).
  # - `:uid`: The Unix file owner user ID number.
  # - `:gid`: The Unix file owner group ID number.
  # - `:mtime`: File modification time. Sub-second values are emitted as PAX decimal time.
  # - `:uname`, `:gname`: Owner names; values longer than the ustar fields use PAX.
  # - `:pax`: Per-entry PAX attributes as a Hash, or `true` to use PAX for long paths.
  #
  # An exception will be raised if the Writer is already closed, or if more data is
  # written to the BoundedWriteStream than expected.
  #
  # :call-seq:
  #    add_file_simple('foo.txt', :data => "bar") -> writer
  #    add_file_simple('foo.txt', :size => 3) { |w| block }
  def add_file_simple(name, opts = {}) # :yields: BoundedWriteStream
    raise Minitar::ClosedStream if @closed

    data = opts.fetch(:data, nil)
    size = opts.fetch(:size, nil)

    if block_given?
      raise ArgumentError, "Too much data (opts[:data] and block_given?)." if data
      raise ArgumentError, "No size provided" unless size
    else
      raise ArgumentError, "No data provided" unless data

      bytes = data.bytesize
      size = bytes if size.nil? || size < bytes
    end

    _short_name, _prefix, needs_long_name = split_name(name)
    pax_attributes = entry_pax_attributes(
      name, opts, size, needs_long_name: needs_long_name
    )

    header = {
      mode: opts.fetch(:mode, 0o644),
      mtime: opts.fetch(:mtime, nil),
      gid: opts.fetch(:gid, nil),
      uid: opts.fetch(:uid, nil),
      uname: opts[:uname],
      gname: opts[:gname]
    }

    header[:size] = size

    write_entry_pax_header(pax_attributes)
    short_name, prefix, needs_long_name = entry_name_parts(name, pax_attributes)
    write_header(header, name, short_name, prefix, needs_long_name)

    os = BoundedWriteStream.new(@io, size)
    if block_given?
      yield os
    else
      os.write(data)
    end

    min_padding = size - os.written
    @io.write("\0" * min_padding)
    remainder = (512 - (size % 512)) % 512
    @io.write("\0" * remainder)
  end

  # Adds a file to the archive as `name`. The data can be provided in `opts[:data]` or
  # provided to a yielded WriteOnlyStream. The size of the file will be determined from
  # the amount of data written to the stream.
  #
  # Valid parameters to `opts` are:
  #
  # - `:data` (_optional_): The data to write to the archive.
  # - `:mode`: The Unix file permissions mode value. If not provided, defaults to `0o644`.
  # - `:uid`: The Unix file owner user ID number.
  # - `:gid`: The Unix file owner group ID number.
  # - `:mtime`: File modification time. Sub-second values use PAX when required.
  # - `:pax`: Per-entry PAX attributes as a Hash, or `true` to use PAX for long paths.
  #
  # If `opts[:data]` is provided, this acts the same as #add_file_simple. Otherwise, the
  # file's size will be determined from the amount of data written to the stream.
  #
  # For #add_file to be used without `opts[:data]`, the Writer must be wrapping a stream
  # object that is seekable. Otherwise, #add_file_simple must be used.
  #
  # `opts` may be modified during the writing of the file to the stream.
  def add_file(name, opts = {}, &) # :yields: WriteOnlyStream, `opts`
    raise Minitar::ClosedStream if @closed

    return add_file_simple(name, opts, &) if opts[:data]

    raise Minitar::NonSeekableStream unless Minitar.seekable?(@io)

    _short_name, _prefix, original_needs_long_name = split_name(name)
    initial_pax_attributes = entry_pax_attributes(
      name, opts, nil, needs_long_name: original_needs_long_name
    )
    initial_pax_blocks = pax_total_blocks(initial_pax_attributes)
    short_name, prefix, needs_long_name = entry_name_parts(name, initial_pax_attributes)

    data_offset = (needs_long_name ? 3 * BLOCK_SIZE : BLOCK_SIZE) +
      initial_pax_blocks * BLOCK_SIZE
    init_pos = @io.pos
    @io.write("\0" * data_offset) # placeholder for the header

    yield WriteOnlyStream.new(@io), opts

    size = @io.pos - (init_pos + data_offset)
    remainder = (512 - (size % 512)) % 512
    @io.write("\0" * remainder)

    data_end = @io.pos
    @io.pos = init_pos

    final_pax_attributes = entry_pax_attributes(
      name,
      opts,
      size,
      needs_long_name: original_needs_long_name
    )
    final_pax_blocks = pax_total_blocks(final_pax_attributes)
    if final_pax_blocks > initial_pax_blocks
      shift_stream_data(
        init_pos + data_offset,
        data_end,
        (final_pax_blocks - initial_pax_blocks) * BLOCK_SIZE
      )
    end
    @io.pos = init_pos

    final_pos = data_end + (final_pax_blocks - initial_pax_blocks) * BLOCK_SIZE

    header = {
      mode: opts[:mode],
      mtime: opts[:mtime],
      size: size,
      gid: opts[:gid],
      uid: opts[:uid],
      uname: opts[:uname],
      gname: opts[:gname]
    }

    write_entry_pax_header(final_pax_attributes)
    short_name, prefix, final_needs_long_name = entry_name_parts(name, final_pax_attributes)
    write_header(header, name, short_name, prefix, final_needs_long_name)

    @io.pos = final_pos
  end

  # Creates a directory entry in the tar.
  def mkdir(name, opts = {})
    raise Minitar::ClosedStream if @closed

    header = {
      mode: opts[:mode],
      typeflag: "5",
      size: 0,
      gid: opts[:gid],
      uid: opts[:uid],
      mtime: opts[:mtime],
      uname: opts[:uname],
      gname: opts[:gname]
    }

    _short_name, _prefix, needs_long_name = split_name(name)
    pax_attributes = entry_pax_attributes(name, opts, 0, needs_long_name: needs_long_name)
    write_entry_pax_header(pax_attributes)
    short_name, prefix, needs_long_name = entry_name_parts(name, pax_attributes)
    write_header(header, name, short_name, prefix, needs_long_name)

    nil
  end

  # Creates a symbolic link entry in the tar.
  def symlink(name, link_target, opts = {})
    raise Minitar::ClosedStream if @closed
    raise Minitar::FileNameTooLong unless link_target.is_a?(String)

    _short_name, _prefix, needs_long_name = split_name(name)
    pax_attributes = entry_pax_attributes(
      name,
      opts,
      0,
      needs_long_name: needs_long_name,
      link_target: link_target
    )
    raise Minitar::FileNameTooLong if link_target.bytesize > 100 &&
      !pax_attributes.key?("linkpath")
    write_entry_pax_header(pax_attributes)
    short_name, prefix, = entry_name_parts(name, pax_attributes)
    link_name = pax_attributes.key?("linkpath") ? link_target.byteslice(0, 100) : link_target

    header = {
      name: short_name,
      mode: opts[:mode],
      typeflag: "2",
      size: 0,
      linkname: link_name,
      gid: opts[:gid],
      uid: opts[:uid],
      mtime: opts[:mtime],
      uname: opts[:uname],
      gname: opts[:gname],
      prefix: prefix
    }
    @io.write(Minitar::PosixHeader.new(header).to_s)
    nil
  end

  # Passes the #flush method to the wrapped stream, used for buffered streams.
  def flush
    raise Minitar::ClosedStream if @closed
    @io.flush if @io.respond_to?(:flush)
  end

  # Returns false if the writer is open.
  def closed? = @closed

  # Closes the Writer. This does not close the underlying wrapped output stream.
  def close
    return if @closed
    @io.write("\0" * 1024)
    @closed = true
  end

  private

  def write_header(header, long_name, short_name, prefix, needs_long_name)
    if needs_long_name
      long_name_header = {
        prefix: "",
        name: Minitar::PosixHeader::GNU_EXT_LONG_LINK,
        typeflag: "L",
        size: long_name.bytesize + 1,
        mode: 0
      }
      @io.write(Minitar::PosixHeader.new(long_name_header).to_s)
      @io.write(long_name.b)
      @io.write("\0" * ((BLOCK_SIZE - (long_name.bytesize % BLOCK_SIZE)) % BLOCK_SIZE))
    end

    new_header = header.merge({name: short_name, prefix: prefix})
    @io.write(Minitar::PosixHeader.new(new_header).to_s)
  end

  def entry_pax_attributes(name, opts, size, needs_long_name:, link_target: nil)
    option = opts[:pax]
    return {} if option == false

    pax_enabled = option == true || option.is_a?(Hash)
    attributes = option.is_a?(Hash) ? normalize_pax_attributes(option) : {}

    add_pax_integer(attributes, "uid", opts[:uid]) if opts[:uid]&.>=(MAX_OCTAL_FIELD_VALUE)
    add_pax_integer(attributes, "gid", opts[:gid]) if opts[:gid]&.>=(MAX_OCTAL_FIELD_VALUE)
    add_pax_string(attributes, "uname", opts[:uname]) if opts[:uname]&.bytesize&.>(32)
    add_pax_string(attributes, "gname", opts[:gname]) if opts[:gname]&.bytesize&.>(32)
    add_pax_integer(attributes, "size", size) if size&.>=(MAX_OCTAL_FIELD_VALUE)
    add_pax_time(attributes, opts[:mtime], "mtime")

    if needs_long_name && (pax_enabled || !attributes.empty?)
      attributes["path"] = name.b unless attributes.key?("path")
    end

    if link_target && link_target.bytesize > 100 && (pax_enabled || !attributes.empty?)
      attributes["linkpath"] = link_target.b unless attributes.key?("linkpath")
    end

    attributes
  end

  def normalize_pax_attributes(attributes)
    attributes.each_with_object({}) do |(keyword, value), result|
      keyword = keyword.to_s
      Minitar::PaxHeader.valid_keyword!(keyword)
      result[keyword] = pax_attribute_value(keyword, value)
    end
  end

  def pax_attribute_value(keyword, value)
    case keyword
    when "mtime", "atime", "ctime"
      pax_time_value(value)
    when "size", "uid", "gid"
      value.to_s
    else
      value.to_s
    end.b
  end

  def add_pax_time(attributes, value, keyword)
    return if value.nil? || attributes.key?(keyword)
    formatted = pax_time_value(value)
    attributes[keyword] = formatted if formatted.include?(".")
  end

  def add_pax_integer(attributes, keyword, value)
    attributes[keyword] ||= value.to_s
  end

  def add_pax_string(attributes, keyword, value)
    attributes[keyword] ||= value.b
  end

  def pax_time_value(value)
    case value
    when Integer
      value.to_s
    when Rational
      rational_decimal(value)
    when Time
      rational_decimal(value.to_r)
    else
      value.to_s
    end
  end

  def rational_decimal(value)
    numerator = value.numerator.abs
    denominator = value.denominator
    twos = 0
    fives = 0

    while denominator.even?
      denominator /= 2
      twos += 1
    end
    while denominator % 5 == 0
      denominator /= 5
      fives += 1
    end
    raise ArgumentError, "Cannot represent PAX time as finite decimal" unless denominator == 1

    scale = [twos, fives].max
    numerator *= 5**twos * 2**fives
    divisor = 10**scale
    whole, fraction = numerator.divmod(divisor)
    sign = value.negative? ? "-" : ""
    scale.zero? ? "#{sign}#{whole}" : format("#{sign}%d.%0#{scale}d", whole, fraction)
  end

  def write_entry_pax_header(attributes)
    write_pax_header(attributes, scope: :entry) unless attributes.empty?
  end

  def pax_total_blocks(attributes)
    return 0 if attributes.empty?
    content_size = Minitar::PaxHeader.new(attributes).to_s.bytesize
    1 + (content_size + BLOCK_SIZE - 1) / BLOCK_SIZE
  end

  def entry_name_parts(name, pax_attributes)
    if pax_attributes["path"]
      [File.basename(name).byteslice(0, 100), "", false]
    else
      split_name(name)
    end
  end

  def shift_stream_data(start_pos, end_pos, shift)
    pos = end_pos

    while pos > start_pos
      chunk_size = [BLOCK_SIZE, pos - start_pos].min
      chunk_start = pos - chunk_size

      @io.pos = chunk_start
      chunk = @io.read(chunk_size)
      @io.pos = chunk_start + shift
      @io.write(chunk)

      pos -= chunk_size
    end
  end

  def split_name(name)
    if name.bytesize <= 100
      prefix = ""
    else
      parts = name.split("/")
      newname = parts.pop

      nxt = ""

      loop do
        nxt = parts.pop || ""
        break if newname.bytesize + 1 + nxt.bytesize >= 100
        newname = "#{nxt}/#{newname}"
      end

      prefix = (parts + [nxt]).join("/")

      name = newname
    end

    [name, prefix, name.bytesize > 100 || prefix.bytesize > 155]
  end
end
