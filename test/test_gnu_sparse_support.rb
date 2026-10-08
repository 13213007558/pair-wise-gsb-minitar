# frozen_string_literal: true

require "minitest_helper"

class TestGnuSparseSupport < Minitest::Test
  def test_sparse_roundtrip_preserves_logical_content_tail_holes_and_next_entry
    logical = "AAAA" + "\0" * 4 + "BBBB" + "\0" * 4 + "CCCC" + "\0" * 12
    extents = [
      {offset: 0, length: 4},
      {offset: 8, length: 4},
      {offset: 16, length: 12}
    ]
    sources = ["AAAA", "BBBB", "CCCC" + "\0" * 8]

    tarball = create_sparse_tarball(logical.bytesize, extents, sources)

    read_entries = []
    Minitar::Input.open(StringIO.new(tarball)) do |input|
      input.each_entry do |entry|
        read_entries << [entry.full_name, entry.read]
      end
    end

    assert_equal [["sparse", logical], ["next", "NEXT"]], read_entries

    Minitar::Input.open(StringIO.new(tarball)) do |input|
      input.each_entry do |sparse_entry|
        assert sparse_entry.sparse?
        assert_equal 32, sparse_entry.logical_size
        assert_equal 20, sparse_entry.stored_size
        assert_equal 2 * 512, sparse_entry.archive_size
        assert_equal [[0, 4], [8, 4], [16, 12]], sparse_entry.each_extent.map {
          [_1.offset, _1.length]
        }
        assert_equal logical, sparse_entry.read
        break
      end
    end
  end

  def test_sparse_read_can_start_in_holes_and_data
    logical = "AAAA" + "\0" * 4 + "BBBB" + "\0" * 4 + "CCCC"
    extents = [{offset: 0, length: 4}, {offset: 8, length: 4}, {offset: 16, length: 4}]
    tarball = create_sparse_tarball(logical.bytesize, extents, %w[AAAA BBBB CCCC])

    Minitar::Reader.open(StringIO.new(tarball)) do |reader|
      reader.each_entry do |entry|
        entry.seek(6)
        assert_equal "\0\0BB", entry.read(4)
        assert_equal "BB", entry.read(2)
        assert_equal "\0\0\0\0CCCC", entry.read
        break
      end
    end
  end

  def test_sparse_read_works_with_non_seekable_stream
    logical = "AAAA" + "\0" * 4 + "BBBB"
    extents = [{offset: 0, length: 4}, {offset: 8, length: 4}]
    tarball = create_sparse_tarball(logical.bytesize, extents, %w[AAAA BBBB])
    io = ForwardOnlyIO.new(tarball)
    entries = []

    Minitar::Reader.new(io).each_entry do |entry|
      entries << [entry.full_name, entry.read]
    end

    assert_equal [["sparse", logical], ["next", "NEXT"]], entries
  end

  def test_sparse_map_uses_multiple_blocks
    extents = (0...900).map { |index| {offset: index * 600, length: 1} }
    logical = "\0" * (899 * 600 + 1)
    extents.each { logical[_1[:offset]] = "x" }
    sources = extents.map { "x" }

    tarball = create_sparse_tarball(logical.bytesize, extents, sources)

    Minitar::Reader.open(StringIO.new(tarball)) do |reader|
      reader.each_entry do |entry|
        assert_operator entry.map_blocks, :>, 1
        assert_operator entry.archive_size, :>, entry.map_blocks * 512
        assert_equal logical, entry.read
        break
      end
    end
  end

  def test_writer_rejects_overlapping_extents
    assert_raises(ArgumentError) do
      create_sparse_tarball(10, [{offset: 0, length: 5}, {offset: 4, length: 2}], %w[AAAAA BB])
    end
  end

  def test_writer_rejects_out_of_bounds_extents
    assert_raises(ArgumentError) do
      create_sparse_tarball(5, [{offset: 0, length: 6}], ["A" * 6])
    end
  end

  def test_sparse_file_with_only_holes
    logical = "\0" * 64
    tarball = create_sparse_tarball(logical.bytesize, [], [])

    Minitar::Input.open(StringIO.new(tarball)) do |input|
      entries = []
      input.each_entry { entries << [_1.full_name, _1.read] }
      assert_equal [["sparse", logical], ["next", "NEXT"]], entries
    end
  end

  def test_writer_rejects_short_reads
    assert_raises(Minitar::UnexpectedEOF) do
      create_sparse_tarball(8, [{offset: 0, length: 4}], ["abc"])
    end
  end

  def test_reader_rejects_old_sparse_format
    header = build_header("S", "old", "", 512, 0o644)
    header.setbyte(156, "S".ord)
    header = update_header_checksum(header)
    tarball = header + "hello" + "\0" * 507 + "\0" * 1024

    assert_raises(Minitar::InvalidTarStream) do
      Minitar::Input.open(StringIO.new(tarball)) { _1.each_entry {} }
    end
  end

  def test_extraction_preserves_logical_size_and_tail_hole
    logical_size = 12_000
    extents = [{offset: 0, length: 10}, {offset: 8000, length: 10}]
    sources = ["A" * 10, "B" * 10]
    tarball = create_sparse_tarball(logical_size, extents, sources)
    target = Pathname(Dir.mktmpdir)

    begin
      Minitar::Input.open(StringIO.new(tarball)) do |input|
        input.each_entry { input.extract_entry(target.to_s, _1) }
      end

      extracted = target.join("sparse")
      assert extracted.file?
      assert_equal logical_size, extracted.size
      assert_equal "A" * 10, extracted.binread(10, 0)
      assert_equal "\0" * 10, extracted.binread(10, 10)
      assert_equal "B" * 10, extracted.binread(10, 8000)
      assert_equal "\0" * 10, extracted.binread(10, logical_size - 10)
    ensure
      target.rmtree
    end
  end

  private

  def create_sparse_tarball(logical_size, extents, sources)
    StringIO.new.tap do |io|
      Minitar::Writer.open(io) do |writer|
        writer.add_file_sparse(
          "sparse", logical_size, extents, sources: sources
        )
        writer.add_file_simple("next", data: "NEXT")
      end
    end.string
  end
end

class ForwardOnlyIO
  def initialize(data)
    @data = data
    @position = 0
  end

  def read(length)
    return nil if @position >= @data.bytesize
    chunk = @data.byteslice(@position, length)
    @position += chunk.bytesize
    chunk
  end

  def eof? = @position >= @data.bytesize
end
