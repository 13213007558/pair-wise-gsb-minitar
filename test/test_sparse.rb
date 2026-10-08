# frozen_string_literal: true

require "minitest_helper"

class TestSparse < Minitest::Test
  # A file with content at the head and the tail and two holes in the middle.
  HOLED_EXTENTS = [
    [0, "A" * 1000],
    [5_000, "B" * 2_000],
    [12_000, "C" * 3_000]
  ].freeze
  HOLED_SIZE = 15_000

  # A file whose last extent is followed by a trailing hole.
  TRAILING_EXTENTS = [[512, "D" * 100]].freeze
  TRAILING_SIZE = 4_096

  def logical_content(size, extent_data)
    content = +"\0" * size
    extent_data.each do |offset, data|
      content[offset, data.bytesize] = data
    end
    content.force_encoding(Encoding::BINARY)
  end

  def extent_specs(extent_data)
    extent_data.map { |offset, data| {offset: offset, length: data.bytesize, data: data} }
  end

  def write_sparse(name, size, specs, &block)
    StringIO.new(+"", "w+b").tap do |io|
      Minitar::Writer.open(io) do |writer|
        writer.add_file_sparse(name, size: size, extents: specs)
        block&.call(writer)
      end
      io.rewind
    end
  end

  def holed_tar(&block) = write_sparse("sparse.bin", HOLED_SIZE, extent_specs(HOLED_EXTENTS), &block)

  def test_sparse_entry_metadata
    Minitar::Reader.open(holed_tar) do |reader|
      entry = reader.each_entry.first

      assert entry.sparse?
      assert entry.file?
      assert_equal "sparse.bin", entry.full_name
      assert_equal HOLED_SIZE, entry.size
      assert_equal 6_000, entry.archived_size
      assert_equal [[0, 1000], [5_000, 2_000], [12_000, 3_000]],
        entry.extents.map { |e| [e.offset, e.length] }
    end
  end

  def test_sparse_entry_is_not_sparse_for_regular_files
    tar = StringIO.new(+"", "w+b")
    Minitar::Writer.open(tar) { |w| w.add_file_simple("plain.txt", data: "hello") }
    tar.rewind

    Minitar::Reader.open(tar) do |reader|
      entry = reader.each_entry.first

      refute entry.sparse?
      assert_nil entry.extents
      assert_equal 5, entry.size
      assert_equal 5, entry.archived_size
    end
  end

  def test_sparse_read_returns_logical_content
    Minitar::Reader.open(holed_tar) do |reader|
      reader.each_entry do |entry|
        assert_equal logical_content(HOLED_SIZE, HOLED_EXTENTS), entry.read
        assert entry.eof?
        assert_nil entry.read
      end
    end
  end

  def test_sparse_read_at_logical_positions
    Minitar::Reader.open(holed_tar) do |reader|
      reader.each_entry do |entry|
        assert_equal "A" * 100, entry.read(100)
        assert_equal "A" * 900, entry.read(900)
        assert_equal "\0" * 4_000, entry.read(4_000)
        assert_equal "B" * 2_000, entry.read(2_000)
        assert_equal "\0" * 5_000, entry.read(5_000)
        assert_equal "C" * 3_000, entry.read(3_000)
        assert entry.eof?
      end
    end
  end

  def test_sparse_read_spanning_extent_boundary
    Minitar::Reader.open(holed_tar) do |reader|
      reader.each_entry do |entry|
        entry.read(999)
        assert_equal "A" + ("\0" * 199), entry.read(200)
      end
    end
  end

  def test_sparse_read_with_out_string
    Minitar::Reader.open(holed_tar) do |reader|
      reader.each_entry do |entry|
        buffer = +""
        result = entry.read(1_500, buffer)

        assert_same buffer, result
        assert_equal ("A" * 1_000) + ("\0" * 500), buffer
      end
    end
  end

  def test_sparse_getc_and_pos
    Minitar::Reader.open(holed_tar) do |reader|
      reader.each_entry do |entry|
        assert_equal "A", entry.getc
        assert_equal 1, entry.pos

        entry.read(3_999)
        assert_equal 4_000, entry.pos
        assert_equal "\0", entry.getc
      end
    end
  end

  def test_sparse_rewind
    Minitar::Reader.open(holed_tar) do |reader|
      reader.each_entry do |entry|
        entry.read(2_000)
        entry.rewind

        assert_equal 0, entry.pos
        assert_equal logical_content(HOLED_SIZE, HOLED_EXTENTS), entry.read
      end
    end
  end

  def test_sparse_each_extent
    Minitar::Reader.open(holed_tar) do |reader|
      reader.each_entry do |entry|
        collected = entry.each_extent.map { |e| [e.offset, e.length, e.end_offset] }

        assert_equal [[0, 1000, 1000], [5_000, 2_000, 7_000], [12_000, 3_000, 15_000]], collected
      end
    end
  end

  def test_trailing_hole_is_preserved
    tar = write_sparse("trailing.bin", TRAILING_SIZE, extent_specs(TRAILING_EXTENTS))

    Minitar::Reader.open(tar) do |reader|
      reader.each_entry do |entry|
        assert entry.sparse?
        assert_equal TRAILING_SIZE, entry.size
        assert_equal 100, entry.archived_size
        assert_equal [[512, 100]], entry.extents.map { |e| [e.offset, e.length] }
        assert_equal logical_content(TRAILING_SIZE, TRAILING_EXTENTS), entry.read
      end
    end
  end

  def test_entry_after_sparse_file_is_readable
    tar = holed_tar do |writer|
      writer.add_file_simple("after.txt", data: "after the sparse file")
    end

    entries = []
    Minitar::Reader.open(tar) do |reader|
      reader.each_entry do |entry|
        entries << [entry.full_name, entry.read]
      end
    end

    assert_equal ["sparse.bin", "after.txt"], entries.map(&:first)
    assert_equal logical_content(HOLED_SIZE, HOLED_EXTENTS), entries[0].last
    assert_equal "after the sparse file", entries[1].last
  end

  def test_sparse_extents_from_io_sources
    specs = HOLED_EXTENTS.map { |offset, data|
      [offset, data.bytesize, StringIO.new(data)]
    }
    tar = write_sparse("sparse.bin", HOLED_SIZE, specs)

    Minitar::Reader.open(tar) do |reader|
      reader.each_entry do |entry|
        assert_equal logical_content(HOLED_SIZE, HOLED_EXTENTS), entry.read
      end
    end
  end

  def test_sparse_map_spanning_multiple_blocks
    extent_data = 100.times.map { |i| [i * 1_100, "x" * 100] }
    size = 100 * 1_100
    tar = write_sparse("many.bin", size, extent_specs(extent_data))

    assert_operator Minitar::Sparse.encode_map(
      extent_data.map { |offset, data| Minitar::Sparse::Extent.new(offset, data.bytesize) }
    ).bytesize, :>, 512

    Minitar::Reader.open(tar) do |reader|
      reader.each_entry do |entry|
        assert entry.sparse?
        assert_equal 100, entry.extents.size
        assert_equal logical_content(size, extent_data), entry.read
      end
    end
  end

  def test_extract_sparse_entry_to_filesystem
    Dir.mktmpdir do |dir|
      Minitar.unpack(holed_tar, dir)

      dest = File.join(dir, "sparse.bin")
      assert_equal HOLED_SIZE, File.size(dest)
      assert_equal logical_content(HOLED_SIZE, HOLED_EXTENTS), File.binread(dest)
    end
  end

  def test_extract_sparse_entry_with_trailing_hole_to_filesystem
    tar = write_sparse("trailing.bin", TRAILING_SIZE, extent_specs(TRAILING_EXTENTS))

    Dir.mktmpdir do |dir|
      Minitar.unpack(tar, dir)

      dest = File.join(dir, "trailing.bin")
      assert_equal TRAILING_SIZE, File.size(dest)
      assert_equal logical_content(TRAILING_SIZE, TRAILING_EXTENTS), File.binread(dest)
    end
  end

  def test_overlapping_extents_are_rejected
    error = assert_raises(ArgumentError) do
      write_sparse("bad.bin", 1_000, [
        {offset: 0, length: 100, data: "a" * 100},
        {offset: 50, length: 100, data: "b" * 100}
      ])
    end
    assert_match(/overlap|order/, error.message)
  end

  def test_unordered_extents_are_rejected
    assert_raises(ArgumentError) do
      write_sparse("bad.bin", 1_000, [
        {offset: 500, length: 10, data: "a" * 10},
        {offset: 0, length: 10, data: "b" * 10}
      ])
    end
  end

  def test_extent_beyond_logical_size_is_rejected
    error = assert_raises(ArgumentError) do
      write_sparse("bad.bin", 1_000, [
        {offset: 900, length: 200, data: "a" * 200}
      ])
    end
    assert_match(/logical file size/, error.message)
  end

  def test_zero_length_extent_is_rejected
    assert_raises(ArgumentError) do
      write_sparse("bad.bin", 1_000, [{offset: 0, length: 0, data: ""}])
    end
  end

  def test_short_string_data_is_rejected
    assert_raises(Minitar::UnexpectedEOF) do
      write_sparse("bad.bin", 1_000, [{offset: 0, length: 100, data: "a" * 50}])
    end
  end

  def test_long_string_data_is_rejected
    assert_raises(ArgumentError) do
      write_sparse("bad.bin", 1_000, [{offset: 0, length: 100, data: "a" * 150}])
    end
  end

  def test_short_io_data_is_rejected
    assert_raises(Minitar::UnexpectedEOF) do
      write_sparse("bad.bin", 1_000, [{offset: 0, length: 100, data: StringIO.new("a" * 50)}])
    end
  end

  def test_old_gnu_sparse_typeflag_is_rejected
    header = update_header_checksum(build_header("S", "old.bin", "", 0, 0o644))
    tar = header + ("\0" * 1_024)

    assert_raises(Minitar::UnsupportedSparseFormat) do
      Minitar::Reader.open(StringIO.new(tar)) { |r| r.each_entry { |e| e.read } }
    end
  end

  def test_legacy_sparse_0_0_is_rejected
    tar = pax_sparse_tar(Minitar::PaxHeader.new(
      "GNU.sparse.numblocks" => "1",
      "GNU.sparse.offset" => "0",
      "GNU.sparse.numbytes" => "4",
      "GNU.sparse.size" => "4"
    ).to_s)

    assert_raises(Minitar::UnsupportedSparseFormat) do
      Minitar::Reader.open(StringIO.new(tar)) { |r| r.each_entry { |e| e.read } }
    end
  end

  def test_legacy_sparse_0_1_is_rejected
    tar = pax_sparse_tar(Minitar::PaxHeader.new("GNU.sparse.map" => "0,4").to_s)

    assert_raises(Minitar::UnsupportedSparseFormat) do
      Minitar::Reader.open(StringIO.new(tar)) { |r| r.each_entry { |e| e.read } }
    end
  end

  def test_unsupported_sparse_version_is_rejected
    pax = Minitar::PaxHeader.new(
      "GNU.sparse.major" => "0",
      "GNU.sparse.minor" => "1",
      "GNU.sparse.realsize" => 100
    ).to_s
    tar = pax_sparse_tar(pax)

    assert_raises(Minitar::UnsupportedSparseFormat) do
      Minitar::Reader.open(StringIO.new(tar)) { |r| r.each_entry { |e| e.read } }
    end
  end

  def test_sparse_map_blocks_outside_entry_size_are_rejected
    # The header size does not account for the sparse map blocks.
    extents = [Minitar::Sparse::Extent.new(0, 4)]
    map = Minitar::Sparse.encode_map(extents).ljust(512, "\0")
    tar = sparse_entry_tar(map + "DATA", header_size: 4, realsize: 4)

    assert_raises(Minitar::InvalidTarStream) do
      Minitar::Reader.open(StringIO.new(tar)) { |r| r.each_entry { |e| e.read } }
    end
  end

  def test_sparse_data_size_mismatch_is_rejected
    # The map declares more data than the entry holds.
    extents = [Minitar::Sparse::Extent.new(0, 100)]
    map = Minitar::Sparse.encode_map(extents).ljust(512, "\0")
    tar = sparse_entry_tar(map + ("D" * 50), header_size: 512 + 50, realsize: 100)

    assert_raises(Minitar::InvalidTarStream) do
      Minitar::Reader.open(StringIO.new(tar)) { |r| r.each_entry { |e| e.read } }
    end
  end

  def test_gnu_tar_extracts_minitar_sparse_file
    skip "GNU tar not available" unless has_gnu_tar?

    workspace do
      @workspace.tarball.open("wb") do |io|
        Minitar::Writer.open(io) do |writer|
          writer.add_file_sparse("sparse.bin", size: HOLED_SIZE, extents: extent_specs(HOLED_EXTENTS))
        end
      end

      gnu_tar_extract_in_workspace

      extracted = @workspace.target.join("sparse.bin")
      assert extracted.file?, "sparse.bin should be extracted"
      assert_equal HOLED_SIZE, extracted.size
      assert_equal logical_content(HOLED_SIZE, HOLED_EXTENTS), extracted.binread
    end
  end

  def test_fully_sparse_file
    tar = write_sparse("empty.bin", 2_048, [])

    Minitar::Reader.open(tar) do |reader|
      reader.each_entry do |entry|
        assert entry.sparse?
        assert_equal 2_048, entry.size
        assert_equal 0, entry.archived_size
        assert_empty entry.extents
        assert_equal "\0" * 2_048, entry.read
      end
    end
  end

  def test_sparse_file_with_long_name
    name = "nested/#{"s" * 120}.bin"
    tar = write_sparse(name, HOLED_SIZE, extent_specs(HOLED_EXTENTS))

    Minitar::Reader.open(tar) do |reader|
      reader.each_entry do |entry|
        assert entry.sparse?
        assert_equal name, entry.full_name
        assert_equal logical_content(HOLED_SIZE, HOLED_EXTENTS), entry.read
      end
    end
  end

  private

  # Builds a tar string with a PAX header carrying +pax_content+ in front of a
  # small regular file.
  def pax_sparse_tar(pax_content)
    [
      build_tar_pax_header("PaxHeader/f", "", pax_content.bytesize),
      pax_content.ljust(512, "\0"),
      build_tar_file_header("f.bin", "", 0o644, 4),
      "DATA".ljust(512, "\0"),
      "\0" * 1_024
    ].join
  end

  # Builds a tar string holding a single GNU sparse 1.0 entry with the given
  # raw body and header values.
  def sparse_entry_tar(body, header_size:, realsize:)
    pax = Minitar::PaxHeader.new(
      "GNU.sparse.major" => "1",
      "GNU.sparse.minor" => "0",
      "GNU.sparse.name" => "sparse.bin",
      "GNU.sparse.realsize" => realsize
    ).to_s

    [
      build_tar_pax_header("PaxHeader/sparse.bin", "", pax.bytesize),
      pax.ljust(512, "\0"),
      build_tar_file_header("sparse.bin", "", 0o644, header_size),
      body.ljust((body.bytesize / 512.0).ceil * 512, "\0"),
      "\0" * 1_024
    ].join
  end
end
