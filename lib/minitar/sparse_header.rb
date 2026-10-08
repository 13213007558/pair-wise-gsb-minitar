# frozen_string_literal: true

# GNU sparse format 1.0 metadata using PAX extended headers.
#
# A sparse entry's POSIX +size+ contains bytes actually stored in the archive
# (newline-delimited map blocks plus concatenated non-empty fragments), while
# GNU.sparse.realsize contains the logical file size including holes.
class Minitar::SparseHeader
  BLOCK_SIZE = Minitar::PosixHeader::BLOCK_SIZE
  VERSION_MAJOR = "1"
  VERSION_MINOR = "0"

  SparseMap = Struct.new(
    :logical_size, :extents, :raw_size, :archive_size, :map_blocks,
    keyword_init: true
  )
  SparseExtent = Struct.new(:offset, :length, keyword_init: true)

  class << self
    # Builds a PAX header block, sparse map blocks, and the main file header.
    def build(
      main_header_fields, logical_size, sparse_extents,
      sparse_name: main_header_fields[:name]
    )
      extents = coerce_extents(sparse_extents)
      validate_extents(extents, logical_size)

      map_text = extents.map { "#{_1.offset}\n#{_1.length}" }.join("\n")
      map_text = extents.empty? ? "0\n" : "#{extents.length}\n#{map_text}\n"
      map_blocks = (map_text.bytesize.to_f / BLOCK_SIZE).ceil
      map_padding = map_blocks * BLOCK_SIZE
      fragment_size = extents.sum(&:length)
      archive_size = map_padding + fragment_size

      attributes = {
        "GNU.sparse.major" => VERSION_MAJOR,
        "GNU.sparse.minor" => VERSION_MINOR,
        "GNU.sparse.realsize" => logical_size.to_s,
        "GNU.sparse.name" => sparse_name.to_s
      }
      pax_header = Minitar::PaxHeader.new(attributes)
      pax_content = pax_header.to_s
      pax_fields = {
        prefix: "",
        name: "././PaxHeaders.0/#{File.basename(main_header_fields[:name].to_s)}",
        typeflag: "x",
        size: pax_content.bytesize,
        mode: 0
      }
      pax_block = Minitar::PosixHeader.new(pax_fields).to_s +
        pax_content.ljust(
          (pax_content.bytesize.to_f / BLOCK_SIZE).ceil * BLOCK_SIZE,
          "\0"
        )

      file_header_fields = main_header_fields.merge(
        typeflag: "0",
        size: archive_size
      )
      file_header = Minitar::PosixHeader.new(file_header_fields).to_s

      map_data = map_text.ljust(map_padding, "\0")

      [pax_block, file_header, map_data, map_blocks]
    end

    # Reads one or more 512-byte map blocks from +io+.
    def read_map(header, io, logical_size:)
      unless logical_size.is_a?(Integer)
        raise Minitar::InvalidTarStream, "missing sparse logical size"
      end

      begin
        first_block = io.read(BLOCK_SIZE)
        raise Minitar::InvalidTarStream, "truncated sparse map" if first_block.nil? ||
          first_block.bytesize < BLOCK_SIZE

        first_line, remainder = first_block.split("\n", 2)
        count = Integer(first_line, 10)
        numbers = []
        text = remainder
        map_blocks_read = 1

        while numbers.length < count * 2
          if text.include?("\n")
            number, text = text.split("\n", 2)
            numbers << Integer(number, 10)
          else
            block = io.read(BLOCK_SIZE)
            raise Minitar::InvalidTarStream, "truncated sparse map" if block.nil?
            text << block
            map_blocks_read += 1
          end
        end

        extents = coerce_extents(
          numbers.each_slice(2).map { |offset, length|
            {offset: offset, length: length}
          }
        )
        validate_extents(extents, logical_size)
      rescue ArgumentError
        raise Minitar::InvalidTarStream, "invalid sparse map"
      end

      raw_size = extents.sum(&:length)
      fragment_size = raw_size
      archive_size = header.size
      map_blocks = ((archive_size - fragment_size).to_f / BLOCK_SIZE).ceil * BLOCK_SIZE

      if archive_size < fragment_size || archive_size > map_blocks + fragment_size ||
         archive_size <= map_blocks + fragment_size - BLOCK_SIZE
        raise Minitar::InvalidTarStream, "invalid sparse archive size"
      end

      unread_map_bytes = map_blocks - map_blocks_read * BLOCK_SIZE
      if unread_map_bytes.positive?
        data = io.read(unread_map_bytes)
        raise Minitar::InvalidTarStream, "truncated sparse map" if data.nil? ||
          data.bytesize < unread_map_bytes
      end

      SparseMap.new(
        logical_size: logical_size,
        extents: extents,
        raw_size: raw_size,
        archive_size: archive_size,
        map_blocks: map_blocks / BLOCK_SIZE
      )
    end

    def validate_extents(extents, logical_size)
      raise ArgumentError, "logical size must be non-negative" if logical_size.negative?

      previous_end = 0
      extents.each do |extent|
        offset = integer!(extent.offset, "extent offset")
        length = integer!(extent.length, "extent length")
        raise ArgumentError, "extent length must be positive" unless length.positive?
        raise ArgumentError, "extent overlaps a preceding extent" if offset < previous_end
        raise ArgumentError, "extent extends beyond logical size" if offset + length > logical_size

        previous_end = offset + length
      end
    end

    def coerce_extents(extents)
      raise ArgumentError, "sparse extents are required" if extents.nil?
      extents.map {
        offset = _1[:offset] || _1["offset"]
        length = _1[:length] || _1["length"] || _1[:numbytes] || _1["numbytes"]
        SparseExtent.new(offset: offset, length: length)
      }.sort_by(&:offset)
    end

    private

    def integer!(value, name)
      raise ArgumentError, "#{name} must be an integer" unless value.is_a?(Integer)
      raise ArgumentError, "#{name} must be non-negative" if value.negative?
      value
    end
  end
end
