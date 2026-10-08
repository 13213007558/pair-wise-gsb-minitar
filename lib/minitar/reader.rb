# frozen_string_literal: true

# The class that reads a tar format archive from a data stream. The data stream may be
# sequential or random access, but certain features only work with random access data
# streams.
class Minitar::Reader
  include Enumerable

  # This marks the EntryStream closed for reading without closing the actual data
  # stream.
  module InvalidEntryStream
    def read(*) = raise Minitar::ClosedStream # :nodoc:

    def getc = raise Minitar::ClosedStream # :nodoc:

    def rewind = raise Minitar::ClosedStream # :nodoc:

    def closed? = true # :nodoc:
  end

  # EntryStreams are pseudo-streams on top of the main data stream.
  class EntryStream
    Minitar::PosixHeader::FIELDS.each do |field|
      attr_reader field.to_sym
    end

    def initialize(header, io, sparse_map = nil)
      @io = io
      @sparse_map = sparse_map
      @name = header.name
      @mode = header.mode
      @uid = header.uid
      @gid = header.gid
      @size = sparse_map&.logical_size || header.size
      @archive_size = sparse_map&.archive_size || header.size
      @stored_size = sparse_map&.raw_size || header.size
      @mtime = header.mtime
      @checksum = header.checksum
      @typeflag = header.typeflag
      @linkname = header.linkname
      @magic = header.magic
      @version = header.version
      @uname = header.uname
      @gname = header.gname
      @devmajor = header.devmajor
      @devminor = header.devminor
      @prefix = header.prefix
      @logical_position = 0
      @stored_position = 0
      @extent_index = 0
      @orig_pos =
        if Minitar.seekable?(@io)
          @io.pos
        else
          0
        end
    end

    # Reads `len` bytes (or all remaining data) from the entry. If `out_string`
    # is provided, the read data is stored there instead of allocating a new
    # string. Returns `nil` if there is no more data to read.
    def read(len = nil, out_string = nil)
      return nil if @logical_position >= @size

      len ||= @size - @logical_position
      result = +"".b

      while result.bytesize < len && @logical_position < @size
        if sparse? && !in_current_extent?
          advance_to_next_extent(result, len)
        else
          available =
            if sparse?
              current_extent.offset + current_extent.length - @logical_position
            else
              @size - @logical_position
            end
          chunk_length = [len - result.bytesize, available].min
          chunk = read_from_archive(chunk_length)
          result << chunk
          @logical_position += chunk.bytesize
          @stored_position += chunk.bytesize if sparse?
        end
      end

      return nil if result.empty?
      set_read_result(result, out_string)
    end

    # Reads one byte from the entry. Returns `nil` if there is no more data to read.
    def getc
      data = read(1)
      data && data.bytes[0]
    end

    # Returns `true` if the entry represents a directory.
    #
    # This is primarily controlled by #typeflag `5`, but if the #typeflag is `0` or `\0`,
    # filenames that end with a forward slash (`/`) will be treated as directories for
    # compatibility purposes.
    def directory?
      case @typeflag
      when "5"
        true
      when "0", "\0"
        @name.end_with?("/")
      else
        false
      end
    end
    alias_method :directory, :directory?

    # Returns `true` if the entry represents a plain file.
    def file?
      (@typeflag == "0" || @typeflag == "\0") && !@name.end_with?("/")
    end
    alias_method :file, :file?

    # Returns `true` if the current read pointer is at the end of the EntryStream data.
    def eof? = @logical_position >= @size

    # Returns the current read pointer in the EntryStream.
    def pos = @logical_position

    alias_method :bytes_read, :pos

    # Sets the current read pointer to the beginning of the EntryStream.
    def rewind
      unless Minitar.seekable?(@io, :pos=)
        raise Minitar::NonSeekableStream
      end
      @io.pos = @orig_pos
      @logical_position = 0
      @stored_position = 0
      @extent_index = 0
    end

    # Seeks to a logical position. Sparse holes do not consume archive data.
    def seek(position)
      raise ArgumentError, "seek position must be non-negative" if position.negative?
      raise ArgumentError, "seek position beyond logical size" if position > @size
      unless Minitar.seekable?(@io, :pos=)
        raise Minitar::NonSeekableStream
      end

      unless sparse?
        @io.pos = @orig_pos + position
        @logical_position = position
        @stored_position = position
        return 0
      end

      @extent_index = @sparse_map.extents.index do |extent|
        position < extent.offset + extent.length
      end || @sparse_map.extents.length

      extent = @sparse_map.extents[@extent_index]
      if extent && position >= extent.offset
        @stored_position = archive_position_for_current_extent
        @io.pos = @orig_pos + archive_position_for_current_extent
      elsif extent
        @stored_position = @sparse_map.extents.first(@extent_index).sum(&:length)
        @io.pos = @orig_pos + @stored_position
      else
        @stored_position = @archive_size
        @io.pos = @orig_pos + @archive_size
      end

      @logical_position = position
      0
    end

    # Returns the full and proper name of the entry.
    def full_name
      if @prefix != ""
        File.join(@prefix, @name)
      else
        @name
      end
    end

    # Logical size of the entry. For sparse entries, this includes holes.
    def logical_size = @size

    # Number of bytes used by this entry's body in the archive, including map
    # blocks and the final body padding but excluding the tar header.
    def archive_size = sparse? ? padded_data_size : @archive_size

    # Number of non-hole bytes saved in the archive, excluding map and padding.
    def stored_size = @stored_size

    # Number of 512-byte sparse map blocks stored before file data.
    def map_blocks = @sparse_map&.map_blocks || 0

    def sparse? = !@sparse_map.nil?

    # Yields each non-empty sparse extent. Each yielded extent is a copy, so
    # callers cannot mutate the entry's map.
    def each_extent
      return to_enum(__method__) unless block_given?
      return unless sparse?

      @sparse_map.extents.each do |extent|
        yield Minitar::SparseHeader::SparseExtent.new(
          offset: extent.offset,
          length: extent.length
        )
      end
    end

    # Reads the data belonging to a sparse extent without zero-fill. The archive
    # position is moved to that extent, allowing extraction to seek the output.
    def read_extent(index = nil, len = nil, out_string = nil)
      raise Minitar::NonSeekableStream unless Minitar.seekable?(@io, :pos=)
      raise ArgumentError, "entry is not sparse" unless sparse?

      if index
        extent = @sparse_map.extents.fetch(index)
        raw_offset = @sparse_map.extents.first(index).sum(&:length)
        @io.pos = @orig_pos + raw_offset
        @extent_index = index
        @stored_position = raw_offset
        @logical_position = extent.offset
      else
        extent = current_extent
        raw_offset = @sparse_map.extents.first(@extent_index).sum(&:length)
        @io.pos = @orig_pos + raw_offset
        @stored_position = raw_offset
        @logical_position = extent.offset
      end
      read(len || extent.length, out_string)
    end

    # Returns false if the entry stream is valid.
    def closed? = false

    # Closes the entry.
    def close = invalidate

    def archive_bytes_remaining
      return @size - @logical_position unless sparse?

      extent = @sparse_map.extents[@extent_index]
      unless extent
        data_start = map_blocks * Minitar::PosixHeader::BLOCK_SIZE
        return archive_size - data_start - @stored_position
      end

      raw_end = @sparse_map.extents.first(@extent_index).sum(&:length) + extent.length
      raw_remaining = [raw_end - @stored_position, 0].max
      raw_remaining + @sparse_map.extents.drop(@extent_index + 1).sum(&:length) +
        final_data_padding
    end

    private

    def invalidate
      extend InvalidEntryStream
    end

    def padded_data_blocks
      data_size = @archive_size - map_blocks * Minitar::PosixHeader::BLOCK_SIZE
      (data_size.to_f / Minitar::PosixHeader::BLOCK_SIZE).ceil
    end

    def padded_data_size
      map_blocks * Minitar::PosixHeader::BLOCK_SIZE +
        padded_data_blocks * Minitar::PosixHeader::BLOCK_SIZE
    end

    def final_data_padding
      data_size = @archive_size - map_blocks * Minitar::PosixHeader::BLOCK_SIZE
      (Minitar::PosixHeader::BLOCK_SIZE - (data_size % Minitar::PosixHeader::BLOCK_SIZE)) %
        Minitar::PosixHeader::BLOCK_SIZE
    end

    def current_extent = @sparse_map.extents[@extent_index]

    def in_current_extent?
      extent = current_extent
      extent && @logical_position >= extent.offset &&
        @logical_position < extent.offset + extent.length
    end

    def advance_to_next_extent(result, requested_length)
      extent = @sparse_map.extents[@extent_index]
      if extent.nil?
        result << "\0" * (requested_length - result.bytesize)
        @logical_position = @size
        return
      end

      if @logical_position < extent.offset
        hole_size = [
          extent.offset - @logical_position,
          requested_length - result.bytesize
        ].min
        result << "\0" * hole_size
        @logical_position += hole_size
      elsif @logical_position == extent.offset + extent.length &&
            @extent_index == @sparse_map.extents.length - 1
        hole_size = [
          @size - @logical_position,
          requested_length - result.bytesize
        ].min
        result << "\0" * hole_size
        @logical_position += hole_size
      elsif @logical_position == extent.offset + extent.length
        @extent_index += 1
        @logical_position = extent.offset + extent.length
      else
        raise Minitar::InvalidTarStream, "invalid sparse read position"
      end
    end

    def read_from_archive(length)
      data = @io.read(length)
      raise Minitar::UnexpectedEOF if data.nil? || data.bytesize < length
      data
    end

    def archive_position_for_current_extent
      extent = current_extent
      offset_within = @logical_position - extent.offset
      @sparse_map.extents.first(@extent_index).sum(&:length) + offset_within
    end

    def set_read_result(result, out_string)
      if out_string
        out_string.replace(result)
      else
        result
      end
    end
  end

  # With no associated block, Reader::open is a synonym for Reader::new. If the optional
  # code block is given, it will be passed the new _reader_ as an argument and the Reader
  # object will automatically be closed when the block terminates. In this
  # instance, Reader::open returns the value of the block.
  def self.open(io)
    reader = new(io)
    return reader unless block_given?

    # This exception context must remain, otherwise the stream closes on open even if
    # a block is not given.
    begin
      yield reader
    ensure
      reader.close
    end
  end

  # Iterates over each entry in the provided input. This wraps the common pattern of:
  #
  # ```ruby
  # Minitar::Input.open(io) do |i|
  #   inp.each do |entry|
  #     # ...
  #   end
  # end
  # ```
  #
  # If a block is not provided, an enumerator will be created with the same behaviour.
  #
  # :call-seq:
  #    Minitar::Reader.each_entry(io) -> enumerator
  #    Minitar::Reader.each_entry(io) { |entry| block } -> obj
  def self.each_entry(io)
    return to_enum(__method__, io) unless block_given?

    Input.open(io) do |reader|
      reader.each_entry do |entry|
        yield entry
      end
    end
  end

  # Creates and returns a new Reader object.
  def initialize(io)
    @io = io
    @init_pos = begin
      io.pos
    rescue
      nil
    end
  end

  # Resets the read pointer to the beginning of data stream. Do not call this during
  # a #each or #each_entry iteration. This only works with random access data streams that
  # respond to #rewind and #pos.
  def rewind
    if @init_pos.zero?
      raise Minitar::NonSeekableStream unless Minitar.seekable?(@io, :rewind)
      @io.rewind
    else
      raise Minitar::NonSeekableStream unless Minitar.seekable?(@io, :pos=)
      @io.pos = @init_pos
    end
  end

  # Iterates through each entry in the data stream.
  def each_entry
    return to_enum unless block_given?

    loop do
      return if @io.eof?

      header = Minitar::PosixHeader.from_stream(@io)
      raise Minitar::InvalidTarStream unless header.valid?
      return if header.empty?

      raise Minitar::InvalidTarStream if header.size < 0

      pax_header = nil
      if header.long_name?
        name_block = (header.size / 512.0).ceil * 512

        long_name = @io.read(name_block).rstrip
        header = Minitar::PosixHeader.from_stream(@io)

        return if header.empty?
        header.long_name = long_name
      elsif header.pax_header?
        pax_header = Minitar::PaxHeader.from_stream(@io, header)

        header = Minitar::PosixHeader.from_stream(@io)
        return if header.empty?

        header.size = pax_header.attributes["size"]&.to_i if pax_header.attributes["size"]
        if pax_header.sparse?
          unless pax_header.sparse_version == [Minitar::SparseHeader::VERSION_MAJOR,
                                               Minitar::SparseHeader::VERSION_MINOR]
            raise Minitar::InvalidTarStream, "unsupported GNU sparse format"
          end
          header.long_name = pax_header.sparse_name if pax_header.sparse_name
        end
      end

      raise Minitar::InvalidTarStream, "unsupported GNU sparse format" if header.typeflag == "S"

      sparse_map =
        if pax_header&.sparse?
          Minitar::SparseHeader.read_map(
            header, @io,
            logical_size: pax_header.sparse_logical_size
          )
        end

      entry = EntryStream.new(header, @io, sparse_map)
      yield entry

      if Minitar.seekable?(@io, :seek)
        # avoid reading...
        try_seek(entry.archive_bytes_remaining)
      else
        pending = entry.archive_bytes_remaining
        while pending > 0
          bread = @io.read([pending, 4096].min).bytesize
          raise Minitar::UnexpectedEOF if @io.eof?
          pending -= bread
        end
      end

      if Minitar.seekable?(@io, :seek)
        block_size = Minitar::PosixHeader::BLOCK_SIZE
        @io.seek(((@io.pos + block_size - 1) / block_size) * block_size)
      else
        # Non-seekable sparse reads already consumed the final padding. Normal
        # entries consume only their logical bytes here.
        skip_normal_trailing_padding(entry) unless entry.sparse?
      end

      # make sure nobody can use #read, #getc or #rewind anymore
      entry.close
    end
  end
  alias_method :each, :each_entry

  # Returns `false` if the reader is open (it never closes).
  def closed? = false

  def close = nil

  private

  def try_seek(bytes)
    @io.seek(bytes, IO::SEEK_CUR)
  rescue RangeError
    # This happens when skipping the large entry and the skipping entry size exceeds
    # maximum allowed size (varies by platform and underlying IO object).
    max = RbConfig::LIMITS.fetch("INT_MAX", 2147483647)
    skipped = 0
    while skipped < bytes
      to_skip = [bytes - skipped, max].min
      @io.seek(to_skip, IO::SEEK_CUR)
      skipped += to_skip
    end
  end

  def skip_normal_trailing_padding(entry)
    block_size = Minitar::PosixHeader::BLOCK_SIZE
    padding = (block_size - (entry.archive_size % block_size)) % block_size
    @io.read(padding) if padding.positive?
  end
end
