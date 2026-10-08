# frozen_string_literal: true

# Support for the GNU sparse 1.0 format.
#
# A sparse file is described by its *logical size* (the size of the file when
# extracted) and a list of non-empty *extents* (offset/length pairs) describing
# which regions of the file actually contain data. Everything not covered by an
# extent is a hole and reads back as zero bytes. Only the extent data -- not the
# holes -- is stored in the archive.
#
# In the GNU sparse 1.0 format, the entry is preceded by a PAX extended header
# carrying the attributes +GNU.sparse.major=1+, +GNU.sparse.minor=0+,
# +GNU.sparse.name+, and +GNU.sparse.realsize+ (the logical size). The regular
# header's +size+ field covers the entry body, which consists of a textual
# sparse map padded to a whole number of 512-byte blocks, followed by the
# concatenated extent data. The map is a series of decimal numbers, one per
# line: the number of extents, followed by the offset and length of each
# extent.
module Minitar::Sparse
  # A single non-empty extent of a sparse file: +length+ bytes of data stored
  # in the archive that belong at +offset+ in the logical file.
  Extent = Struct.new(:offset, :length) do
    # The offset of the first byte after this extent.
    def end_offset = offset + length
  end

  # The supported GNU sparse format version.
  MAJOR = "1"
  MINOR = "0"

  # The sparse map occupies a whole number of blocks of this size.
  MAP_BLOCK_SIZE = 512

  class << self
    # Validates that +extents+ are ordered, non-overlapping, of positive
    # length, and contained within the logical file +size+. Returns the
    # extents. Raises ArgumentError when the extents are invalid.
    def validate_extents!(extents, size)
      previous_end = 0

      extents.each do |extent|
        if extent.offset < 0
          raise ArgumentError, "Sparse extent has a negative offset"
        end

        if extent.length <= 0
          raise ArgumentError, "Sparse extent has a non-positive length"
        end

        if extent.offset < previous_end
          raise ArgumentError, "Sparse extents overlap or are out of order"
        end

        if extent.end_offset > size
          raise ArgumentError, "Sparse extent exceeds the logical file size"
        end

        previous_end = extent.end_offset
      end

      extents
    end

    # Encodes +extents+ as the textual sparse map stored at the beginning of
    # the entry body.
    def encode_map(extents)
      map = +"#{extents.size}\n"
      extents.each do |extent|
        map << extent.offset.to_s << "\n" << extent.length.to_s << "\n"
      end
      map
    end

    # The number of archive blocks occupied by the encoded sparse map for
    # +extents+, including padding.
    def map_block_count(extents)
      (encode_map(extents).bytesize / MAP_BLOCK_SIZE.to_f).ceil
    end
  end
end
