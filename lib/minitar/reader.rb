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

    def initialize(header, io)
      @io = io
      @name = header.name
      @mode = header.mode
      @uid = header.uid
      @gid = header.gid
      @size = header.size
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
      @read = 0
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
      return nil if @read >= @size
      len ||= @size - @read
      max_read = [len, @size - @read].min

      ret =
        if out_string
          begin
            @io.read(max_read, out_string)
          rescue ArgumentError # If `@io` does not support `out_string`
            out_string.replace(@io.read(max_read))
          end
        else
          @io.read(max_read)
        end

      @read += ret.bytesize
      ret
    end

    # Reads one byte from the entry. Returns `nil` if there is no more data to read.
    def getc
      return nil if @read >= @size
      ret = @io.getc
      @read += 1 if ret
      ret
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

    # Returns +true+ if the entry is a sparse file (GNU sparse 1.0 format).
    def sparse? = false

    # Returns the list of non-empty extents for a sparse file, or +nil+ if the
    # entry is not a sparse file.
    def extents = nil

    # Returns the number of bytes of file data actually stored in the archive
    # for this entry. For sparse files, this is the sum of the extent lengths
    # and excludes holes; for all other files, it is the same as #size.
    def archived_size = @size

    # Returns `true` if the current read pointer is at the end of the EntryStream data.
    def eof? = @read >= @size

    # Returns the current read pointer in the EntryStream.
    def pos = @read

    alias_method :bytes_read, :pos

    # Sets the current read pointer to the beginning of the EntryStream.
    def rewind
      unless Minitar.seekable?(@io, :pos=)
        raise Minitar::NonSeekableStream
      end
      @io.pos = @orig_pos
      @read = 0
    end

    # Returns the full and proper name of the entry.
    def full_name
      if @prefix != ""
        File.join(@prefix, @name)
      else
        @name
      end
    end

    # Returns false if the entry stream is valid.
    def closed? = false

    # Closes the entry.
    def close = invalidate

    private

    def invalidate
      extend InvalidEntryStream
    end
  end

  # SparseEntryStreams are pseudo-streams on top of the main data stream for
  # entries stored in the GNU sparse 1.0 format. The entry presents the
  # *logical* view of the file: #size is the logical file size, and reading
  # returns zero bytes for holes. Only the non-empty extents are read from the
  # underlying stream.
  class SparseEntryStream < EntryStream
    # The list of non-empty extents (Minitar::Sparse::Extent) of the sparse
    # file, in file offset order.
    attr_reader :extents

    def initialize(header, io, logical_size)
      super(header, io)
      @logical_size = logical_size
      @extents, @map_bytes = read_sparse_map(io)
      @data_size = @size - @map_bytes

      if @data_size < 0
        raise Minitar::InvalidTarStream,
          "Sparse map blocks exceed the entry size"
      end

      stored = @extents.sum(&:length)
      if stored != @data_size
        raise Minitar::InvalidTarStream,
          "Sparse map declares #{stored} data bytes, but the entry holds #{@data_size}"
      end

      begin
        Minitar::Sparse.validate_extents!(@extents, @logical_size)
      rescue ArgumentError => e
        raise Minitar::InvalidTarStream, e.message
      end

      @data_start_pos = @orig_pos + @map_bytes
      @data_read = 0
      @extent_index = 0
    end

    # Returns +true+ if the entry is a sparse file (GNU sparse 1.0 format).
    def sparse? = true

    # Returns the logical size of the sparse file, including holes.
    def size = @logical_size

    # Returns the number of bytes of file data actually stored in the archive
    # for this entry (the sum of the extent lengths).
    def archived_size = @data_size

    # Iterates over the non-empty extents of the sparse file. If no block is
    # given, an enumerator is returned.
    def each_extent
      return to_enum(__method__) unless block_given?

      @extents.each { |extent| yield extent }
    end

    # Reads +len+ bytes (or all remaining data) from the logical view of the
    # entry. Holes are returned as zero bytes without consuming data from the
    # underlying stream. If +out_string+ is provided, the read data is stored
    # there instead of allocating a new string. Returns +nil+ if there is no
    # more data to read.
    def read(len = nil, out_string = nil)
      return nil if @read >= @logical_size
      len ||= @logical_size - @read
      max_read = [len, @logical_size - @read].min

      ret = "".b
      remaining = max_read

      while remaining > 0
        extent = current_extent

        if extent
          chunk = [remaining, extent.end_offset - @read].min
          data = @io.read(chunk)
          raise Minitar::UnexpectedEOF if data.nil? || data.bytesize < chunk
          ret << data
          @data_read += data.bytesize
          advance = data.bytesize
        else
          hole_end = @extents[@extent_index]&.offset || @logical_size
          advance = [remaining, hole_end - @read].min
          ret << "\0" * advance
        end

        @read += advance
        remaining -= advance
      end

      if out_string
        out_string.replace(ret)
      else
        ret
      end
    end

    # Reads one byte from the logical view of the entry. Returns +nil+ if there
    # is no more data to read.
    def getc = read(1)

    # Returns +true+ if the current read pointer is at the end of the logical
    # entry data.
    def eof? = @read >= @logical_size

    # Returns the number of bytes consumed from the underlying stream,
    # including the sparse map.
    def bytes_read = @map_bytes + @data_read

    # Sets the current read pointer to the beginning of the EntryStream.
    def rewind
      unless Minitar.seekable?(@io, :pos=)
        raise Minitar::NonSeekableStream
      end
      @io.pos = @data_start_pos
      @read = 0
      @data_read = 0
      @extent_index = 0
    end

    private

    # Returns the extent covering the current logical read position, or +nil+
    # if the position is inside a hole.
    def current_extent
      while (extent = @extents[@extent_index]) && extent.end_offset <= @read
        @extent_index += 1
      end

      extent = @extents[@extent_index]
      (extent && extent.offset <= @read) ? extent : nil
    end

    # Reads the textual sparse map from the beginning of the entry body and
    # returns the extents and the total number of bytes consumed (including
    # padding to a whole number of blocks).
    def read_sparse_map(io)
      map_bytes = 0

      read_number = -> {
        digits = +""
        loop do
          char = io.read(1)
          raise Minitar::UnexpectedEOF if char.nil?
          map_bytes += 1
          break if char == "\n"
          unless char.match?(/[0-9]/)
            raise Minitar::InvalidTarStream, "Invalid sparse map entry"
          end
          digits << char
          if digits.bytesize > 20
            raise Minitar::InvalidTarStream, "Invalid sparse map entry"
          end
        end
        raise Minitar::InvalidTarStream, "Invalid sparse map entry" if digits.empty?
        digits.to_i
      }

      count = read_number.call
      # Each extent needs at least four bytes of map text, so the entry size
      # bounds the number of extents.
      if count > @size / 4
        raise Minitar::InvalidTarStream, "Invalid sparse map entry count"
      end

      extents = Array.new(count) {
        Minitar::Sparse::Extent.new(read_number.call, read_number.call)
      }

      block_size = Minitar::Sparse::MAP_BLOCK_SIZE
      padding = (block_size - (map_bytes % block_size)) % block_size
      if padding > 0
        skipped = io.read(padding)
        raise Minitar::UnexpectedEOF if skipped.nil? || skipped.bytesize < padding
        map_bytes += padding
      end

      [extents, map_bytes]
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

      long_name = nil
      pax_header = nil

      while header.long_name? || header.pax_header?
        if header.long_name?
          name_block = (header.size / 512.0).ceil * 512
          long_name = @io.read(name_block).rstrip
        else
          pax_header = Minitar::PaxHeader.from_stream(@io, header)
        end

        header = Minitar::PosixHeader.from_stream(@io)
        return if header.empty?
      end

      header.long_name = long_name if long_name
      header.size = pax_header.size if pax_header&.size

      if header.typeflag == "S"
        raise Minitar::UnsupportedSparseFormat,
          "Old GNU sparse format is not supported"
      end

      if pax_header&.legacy_sparse?
        raise Minitar::UnsupportedSparseFormat,
          "GNU sparse formats 0.0 and 0.1 are not supported"
      end

      entry =
        if pax_header&.sparse?
          unless pax_header.sparse_major == Minitar::Sparse::MAJOR &&
              pax_header.sparse_minor == Minitar::Sparse::MINOR
            raise Minitar::UnsupportedSparseFormat,
              "GNU sparse format #{pax_header.sparse_major}." \
              "#{pax_header.sparse_minor} is not supported"
          end

          logical_size = pax_header.sparse_realsize
          if logical_size.nil? || logical_size < 0
            raise Minitar::InvalidTarStream, "Missing GNU.sparse.realsize"
          end

          header.long_name = pax_header.sparse_name if pax_header.sparse_name

          SparseEntryStream.new(header, @io, logical_size)
        else
          EntryStream.new(header, @io)
        end

      size = header.size

      yield entry

      skip = (512 - (size % 512)) % 512

      if Minitar.seekable?(@io, :seek)
        # avoid reading...
        try_seek(size - entry.bytes_read)
      else
        pending = size - entry.bytes_read
        while pending > 0
          bread = @io.read([pending, 4096].min).bytesize
          raise Minitar::UnexpectedEOF if @io.eof?
          pending -= bread
        end
      end

      @io.read(skip) # discard trailing zeros
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
end
