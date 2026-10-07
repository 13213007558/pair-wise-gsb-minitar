# frozen_string_literal: true

# The class that writes a tar format archive to a data stream.
class Minitar::Writer
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
    @global_pax_attributes = {}
    @pending_pax_attributes = nil
    @pending_pax_scope = nil
  end

  # Writes a PAX extended header. By default this is a one-entry (`x`) header; pass
  # `global: true` to write a persistent global (`g`) header. Empty values delete an
  # existing override according to the PAX record rules.
  def add_pax_header(attributes, global: false)
    raise Minitar::ClosedStream if @closed

    attributes = normalize_pax_attributes(attributes)
    write_pax_header(attributes, global: global)

    if global
      merge_pax_attributes!(@global_pax_attributes, attributes)
    else
      @pending_pax_attributes ||= {}
      @pending_pax_scope ||= {}
      attributes.each do |keyword, value|
        @pending_pax_attributes[keyword] = value.empty? ? nil : value
        @pending_pax_scope[keyword] = value
      end
    end

    nil
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
  # - `:uname`: The Unix file owner user name.
  # - `:gname`: The Unix file owner group name.
  # - `:mtime`: File modification time, interpreted as an integer.
  # - `:pax`: Set to `true` to emit standard PAX fields, or provide a Hash of PAX records.
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

    local_pax_attributes, effective_pax_attributes, _needs_long_name,
      written_pax_attributes = entry_pax_attributes(name, size, opts)
    header = {
      mode: opts.fetch(:mode, 0o644),
      mtime: pax_header_value(opts, :mtime, effective_pax_attributes),
      gid: pax_header_value(opts, :gid, effective_pax_attributes),
      uid: pax_header_value(opts, :uid, effective_pax_attributes),
      uname: pax_header_value(opts, :uname, effective_pax_attributes),
      gname: pax_header_value(opts, :gname, effective_pax_attributes)
    }

    header[:size] = size

    short_name, prefix, needs_long_name = split_name(name)
    pax_path = local_pax_attributes.key?("path") ? local_pax_attributes["path"] : effective_pax_attributes["path"]
    if pax_path
      short_name = "x"
      prefix = ""
      needs_long_name = false
    end
    write_header(header, short_name, prefix, needs_long_name, name, local_pax_attributes,
      effective_pax_attributes: effective_pax_attributes,
      written_pax_attributes: written_pax_attributes)

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
  # - `:uname`: The Unix file owner user name.
  # - `:gname`: The Unix file owner group name.
  # - `:mtime`: File modification time, interpreted as an integer.
  # - `:pax`: Set to `true` to emit standard PAX fields, or provide a Hash of PAX records.
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

    initial_local_pax, initial_effective_pax, _, initial_written_pax = entry_pax_attributes(name, 0, opts)
    short_name, prefix, needs_long_name = split_name(name)

    pax_path = if initial_local_pax.key?("path")
      initial_local_pax["path"]
    else
      initial_effective_pax["path"]
    end
    if pax_path
      short_name = "x"
      prefix = ""
      needs_long_name = false
    end

    metadata_headers = 1
    metadata_headers += 1 if needs_long_name
    initial_x_header = needs_long_name || !initial_local_pax.empty? || !initial_written_pax.empty?
    metadata_headers += 1 if initial_x_header
    data_offset = metadata_headers * 512
    init_pos = @io.pos
    @io.write("\0" * data_offset) # placeholder for the header

    yield WriteOnlyStream.new(@io), opts

    size = @io.pos - (init_pos + data_offset)
    remainder = (512 - (size % 512)) % 512
    @io.write("\0" * remainder)

    final_pos, @io.pos = @io.pos, init_pos

    unless initial_written_pax.empty?
      @pending_pax_attributes = {}
      @pending_pax_scope = initial_written_pax.dup
      initial_written_pax.each do |keyword, value|
        @pending_pax_attributes[keyword] = value.empty? ? nil : value
      end
    end
    local_pax_attributes, effective_pax_attributes, _, written_pax_attributes = entry_pax_attributes(name, size, opts)
    if size > PAX_OCTAL_MAXIMUM
      local_pax_attributes["size"] = size.to_s
      effective_pax_attributes["size"] = size.to_s
      unless initial_x_header
        shift_data_for_size_pax_header(init_pos, data_offset, size, remainder)
        written_pax_attributes = {}
        final_pos += Minitar::PosixHeader::BLOCK_SIZE
      end
    end

    header = {
      mode: opts[:mode],
      mtime: pax_header_value(opts, :mtime, effective_pax_attributes),
      size: size,
      gid: pax_header_value(opts, :gid, effective_pax_attributes),
      uid: pax_header_value(opts, :uid, effective_pax_attributes),
      uname: pax_header_value(opts, :uname, effective_pax_attributes),
      gname: pax_header_value(opts, :gname, effective_pax_attributes)
    }

    pax_path = local_pax_attributes.key?("path") ? local_pax_attributes["path"] : effective_pax_attributes["path"]
    if pax_path
      short_name = "x"
      prefix = ""
      needs_long_name = false
    end
    write_header(header, short_name, prefix, needs_long_name, name, local_pax_attributes,
      effective_pax_attributes: effective_pax_attributes,
      written_pax_attributes: written_pax_attributes)

    @io.pos = final_pos
  end

  # Creates a directory entry in the tar.
  def mkdir(name, opts = {})
    raise Minitar::ClosedStream if @closed

    local_pax_attributes, effective_pax_attributes, _, written_pax_attributes = entry_pax_attributes(name, 0, opts)
    header = {
      mode: opts[:mode],
      typeflag: "5",
      size: 0,
      gid: pax_header_value(opts, :gid, effective_pax_attributes),
      uid: pax_header_value(opts, :uid, effective_pax_attributes),
      uname: pax_header_value(opts, :uname, effective_pax_attributes),
      gname: pax_header_value(opts, :gname, effective_pax_attributes),
      mtime: pax_header_value(opts, :mtime, effective_pax_attributes)
    }

    short_name, prefix, needs_long_name = split_name(name)
    pax_path = local_pax_attributes.key?("path") ? local_pax_attributes["path"] : effective_pax_attributes["path"]
    if pax_path
      short_name = "x"
      prefix = ""
      needs_long_name = false
    end
    write_header(header, short_name, prefix, needs_long_name, name, local_pax_attributes,
      effective_pax_attributes: effective_pax_attributes,
      written_pax_attributes: written_pax_attributes)

    nil
  end

  # Creates a symbolic link entry in the tar.
  def symlink(name, link_target, opts = {})
    raise Minitar::ClosedStream if @closed
    local_pax_attributes, effective_pax_attributes, _, written_pax_attributes =
      entry_pax_attributes(name, 0, opts, link_target)
    short_name, prefix, needs_long_name = split_name(name)

    pax_path = local_pax_attributes.key?("path") ? local_pax_attributes["path"] : effective_pax_attributes["path"]
    if pax_path
      short_name = "x"
      prefix = ""
      needs_long_name = false
    end

    if local_pax_attributes.key?("linkpath")
      link_target = "x" unless local_pax_attributes["linkpath"].empty?
    elsif effective_pax_attributes["linkpath"]
      link_target = "x"
    elsif link_target.bytesize > 100
      raise Minitar::FileNameTooLong
    end

    header = {
      name: short_name,
      mode: opts[:mode],
      typeflag: "2",
      size: 0,
      linkname: link_target,
      gid: pax_header_value(opts, :gid, effective_pax_attributes),
      uid: pax_header_value(opts, :uid, effective_pax_attributes),
      uname: pax_header_value(opts, :uname, effective_pax_attributes),
      gname: pax_header_value(opts, :gname, effective_pax_attributes),
      mtime: pax_header_value(opts, :mtime, effective_pax_attributes),
      prefix: prefix
    }
    write_header(header, short_name, prefix, needs_long_name, name, local_pax_attributes,
      effective_pax_attributes: effective_pax_attributes,
      written_pax_attributes: written_pax_attributes)
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

  PAX_OCTAL_MAXIMUM = 0o77777777777

  def write_header(header, short_name, prefix, needs_long_name, original_name,
    local_pax_attributes = nil, effective_pax_attributes: nil,
    written_pax_attributes: nil)
    if needs_long_name
      long_name_header = {
        prefix: "",
        name: Minitar::PosixHeader::GNU_EXT_LONG_LINK,
        typeflag: "L",
        size: original_name.bytesize + 1,
        mode: 0
      }
      @io.write(Minitar::PosixHeader.new(long_name_header).to_s)
      @io.write(original_name)
      @io.write("\0" * ((512 - (original_name.bytesize % 512)) % 512))
    end

    effective_pax_attributes ||= local_pax_attributes || {}
    written_pax_attributes ||= {}
    additional_pax_attributes = local_pax_attributes.reject do |keyword, value|
      written_pax_attributes.key?(keyword) && written_pax_attributes[keyword] == value
    end

    unless additional_pax_attributes.empty?
      write_pax_header(additional_pax_attributes, global: false)
    end

    new_header = header.merge({name: short_name, prefix: prefix})
    posix_header = Minitar::PosixHeader.new(new_header)
    apply_effective_pax_defaults(posix_header, effective_pax_attributes)
    @io.write(posix_header.to_s)
  end

  def entry_pax_attributes(name, size, opts, link_target = nil)
    explicit = opts[:pax]
    enabled = explicit == true || explicit.is_a?(Hash)
    attributes = {}
    written_attributes = {}
    local_scope = {}
    merge_pax_attributes!(written_attributes, @pending_pax_scope) if @pending_pax_scope
    local_scope.update(@pending_pax_scope) if @pending_pax_scope
    merge_pax_attributes!(attributes, @pending_pax_attributes) if @pending_pax_attributes
    if explicit.is_a?(Hash)
      explicit_attributes = normalize_pax_attributes(explicit)
      merge_pax_attributes!(attributes, explicit_attributes)
      local_scope.update(explicit_attributes)
    end
    @pending_pax_attributes = nil
    @pending_pax_scope = nil
    short_name, _prefix, needs_long_name = split_name(name)

    if enabled && needs_long_name && !attributes["path"]
      attributes["path"] = name
    end

    if enabled && link_target && link_target.bytesize > 100 && !attributes["linkpath"]
      attributes["linkpath"] = link_target
    end

    if size > PAX_OCTAL_MAXIMUM
      attributes["size"] = size.to_s
    end

    add_field_pax_attribute(attributes, "uid", opts[:uid])
    add_field_pax_attribute(attributes, "gid", opts[:gid])
    add_field_pax_attribute(attributes, "uname", opts[:uname])
    add_field_pax_attribute(attributes, "gname", opts[:gname])
    add_mtime_pax_attribute(attributes, opts[:mtime], enabled)

    effective_attributes = @global_pax_attributes.dup
    merge_pax_attributes!(effective_attributes, local_scope)
    [attributes, effective_attributes, needs_long_name, written_attributes]
  end

  def add_field_pax_attribute(attributes, keyword, value)
    return if value.nil? || attributes[keyword]

    case keyword
    when "uid", "gid"
      integer = value.to_i
      attributes[keyword] = integer.to_s if integer > PAX_OCTAL_MAXIMUM || integer.negative?
    when "uname", "gname"
      string = value.to_s
      attributes[keyword] = string if string.bytesize > 32
    end
  end

  def add_mtime_pax_attribute(attributes, value, enabled)
    return if value.nil? || attributes["mtime"]

    if value.is_a?(String)
      attributes["mtime"] = value if value.include?(".")
    elsif value.respond_to?(:to_r) && value.to_r != value.to_r.to_i
      attributes["mtime"] = Minitar::PaxHeader.rational_to_decimal(value.to_r)
    elsif enabled && value.respond_to?(:to_r)
      attributes["mtime"] = value.to_r.to_i.to_s
    end
  end

  def pax_header_value(opts, option, local_attributes)
    return opts[option] unless opts[option].nil?

    keyword = option.to_s
    value = local_attributes[keyword] || @global_pax_attributes[keyword]
    return if value.nil? || value.empty?

    case option
    when :uid, :gid
      value.to_i
    when :mtime
      Rational(value)
    else
      value
    end
  end

  def apply_effective_pax_defaults(header, attributes)
    header.size = 0 if attributes.key?("size")

    if attributes["uid"] && (header.uid > PAX_OCTAL_MAXIMUM || header.uid.negative?)
      header.uid = 0
    end

    if attributes["gid"] && (header.gid > PAX_OCTAL_MAXIMUM || header.gid.negative?)
      header.gid = 0
    end

    header.uname = nil if attributes["uname"] && header.uname.to_s.bytesize > 32
    header.gname = nil if attributes["gname"] && header.gname.to_s.bytesize > 32
  end

  def shift_data_for_size_pax_header(init_pos, data_offset, size, remainder)
    data_start = init_pos + data_offset
    data_end = data_start + size + remainder
    shift = Minitar::PosixHeader::BLOCK_SIZE

    while data_end > data_start
      block_start = [data_start, data_end - shift].max
      length = data_end - block_start
      @io.pos = block_start
      chunk = @io.read(length)
      raise Minitar::UnexpectedEOF, "Truncated entry data" if chunk.nil? || chunk.bytesize != length
      @io.pos = block_start + shift
      @io.write(chunk)
      data_end = block_start
    end
    @io.pos = init_pos + data_offset
  end

  def normalize_pax_attributes(attributes)
    attributes.each_with_object({}) do |(keyword, value), normalized|
      normalized[keyword.to_s] = value.to_s
    end
  end

  def merge_pax_attributes!(attributes, overrides)
    overrides.each do |keyword, value|
      if value.nil? || value.empty?
        attributes.delete(keyword)
      else
        attributes[keyword] = value
      end
    end
  end

  def write_pax_header(attributes, global:)
    content = Minitar::PaxHeader.new(attributes).to_s
    name = global ? "global_header" : "./PaxHeaders.X/entry"
    header = {
      prefix: "",
      name: name,
      typeflag: global ? "g" : "x",
      size: content.bytesize,
      mode: 0o644
    }

    @io.write(Minitar::PosixHeader.new(header).to_s)
    @io.write(content)
    remainder = (512 - (content.bytesize % 512)) % 512
    @io.write("\0" * remainder)
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
