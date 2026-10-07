# frozen_string_literal: true

require "minitest_helper"
require "tmpdir"

class TestTarInput < Minitest::Test
  TEST_CONTENTS = {
    "data.tar.gz" => {size: 210, mode: 0o644},
    "file3" => {size: 18, mode: 0o755}
  }.freeze

  TEST_DATA_CONTENTS = {
    "data/" => {size: 0, mode: 0o755},
    "data/__dir__/" => {size: 0, mode: 0o755},
    "data/file1" => {size: 16, mode: 0o644},
    "data/file2" => {size: 16, mode: 0o644}
  }.freeze

  def setup
    @reader = open_fixture("tar_input")
    FileUtils.mkdir_p("data__")
  end

  def teardown
    @reader&.close unless @reader&.closed?
    FileUtils.rm_rf("data__")
  end

  def test_open_no_block
    input = Minitar::Input.open(@reader)
    refute input.closed?
  ensure
    input.close
    assert input.closed?
  end

  def test_each_works
    Minitar::Input.open(@reader) do |stream|
      outer = 0
      stream.each.with_index do |entry, i|
        assert_kind_of Minitar::Reader::EntryStream, entry
        assert TEST_CONTENTS.key?(entry.name)

        assert_equal TEST_CONTENTS[entry.name][:size], entry.size, entry.name
        assert_modes_equal(TEST_CONTENTS[entry.name][:mode],
          entry.mode, entry.name)
        assert_equal TIME_2004, entry.mtime, "entry.mtime"

        if i.zero?
          data_reader = Zlib::GzipReader.new(StringIO.new(entry.read))
          Minitar::Input.open(data_reader) do |is2|
            inner = 0
            is2.each_with_index do |entry2, _j|
              assert_kind_of Minitar::Reader::EntryStream, entry2
              assert TEST_DATA_CONTENTS.key?(entry2.name)
              assert_equal(TEST_DATA_CONTENTS[entry2.name][:size], entry2.size,
                entry2.name)
              assert_modes_equal(TEST_DATA_CONTENTS[entry2.name][:mode],
                entry2.mode, entry2.name)
              assert_equal TIME_2004, entry2.mtime, entry2.name
              inner += 1
            end
            assert_equal 4, inner
          end
        end

        outer += 1
      end

      assert_equal 2, outer
    end
  end

  def test_extract_entry_works
    Minitar::Input.open(@reader) do |stream|
      outer_count = 0
      stream.each_with_index do |entry, i|
        stream.extract_entry("data__", entry)
        name = File.join("data__", entry.name)

        assert TEST_CONTENTS.key?(entry.name)

        if entry.directory?
          assert(File.directory?(name))
        else
          assert(File.file?(name))

          assert_equal TEST_CONTENTS[entry.name][:size], File.stat(name).size
        end

        assert_modes_equal(TEST_CONTENTS[entry.name][:mode],
          File.stat(name).mode, entry.name)

        if i.zero?
          begin
            ff = File.open(name, "rb")
            data_reader = Zlib::GzipReader.new(ff)
            Minitar::Input.open(data_reader) do |is2|
              is2.each_with_index do |entry2, _j|
                is2.extract_entry("data__", entry2)
                name2 = File.join("data__", entry2.name)

                assert TEST_DATA_CONTENTS.key?(entry2.name)

                if entry2.directory?
                  assert(File.directory?(name2))
                else
                  assert(File.file?(name2))
                  assert_equal(TEST_DATA_CONTENTS[entry2.name][:size],
                    File.stat(name2).size)
                end
                assert_modes_equal(TEST_DATA_CONTENTS[entry2.name][:mode],
                  File.stat(name2).mode, name2)
              end
            end
          ensure
            ff.close unless ff.closed?
          end
        end

        outer_count += 1
      end

      assert_equal 2, outer_count
    end
  end

  def test_extract_entry_breaks_symlinks
    return if Minitar.windows?

    IO.respond_to?(:write) &&
      IO.write("data__/file4", "") ||
      File.write("data__/file4", "")

    File.symlink("data__/file4", "data__/file3")
    File.symlink("data__/file4", "data__/data")

    Minitar.unpack(@reader, "data__")
    Minitar.unpack(Zlib::GzipReader.new(File.open("data__/data.tar.gz", "rb")),
      "data__")

    refute File.symlink?("data__/file3")
    refute File.symlink?("data__/data")
  end

  def test_extract_entry_fails_with_relative_directory
    reader = open_fixture("test_input_relative")
    Minitar::Input.open(reader) do |stream|
      stream.each do |entry|
        assert_raises Minitar::SecureRelativePathError do
          stream.extract_entry("data__", entry)
        end
      end
    end
  end

  def test_extract_with_non_strict_octal
    reader = open_fixture("test_input_non_strict_octal")

    assert_raises(ArgumentError) do
      Minitar.unpack(reader, "data__")
    end
  end

  def test_extract_octal_wrapped_by_space
    reader = open_fixture("test_input_space_octal")
    header = Minitar::PosixHeader.from_stream(reader)
    assert_equal 210, header.size

    reader = open_fixture("test_input_space_octal")
    Minitar.unpack(reader, "data__", [])
  end

  def test_fsync_false
    outer = 0
    Minitar.unpack(@reader, "data__", [], fsync: false) do |_label, _path, _stats|
      outer += 1
    end
    assert_equal 6, outer
  end

  def test_hard_links_resolve_forward_and_indirectly
    return if Minitar.windows?

    tar = create_hardlink_tar([
      {type: :hard_link, name: "forward", target: "data"},
      {type: :hard_link, name: "indirect", target: "forward"},
      {type: :file, name: "data", content: "shared"},
      {type: :file, name: "copy", content: "shared"}
    ])

    Dir.mktmpdir("hardlinks", ".tmp") do |tmpdir|
      dest = File.join(tmpdir, "extract")
      events = []
      Minitar.unpack(StringIO.new(tar), dest, [], {hardlinks: true, fsync: false}) do |event, name|
        events << [event, name]
      end

      assert_includes events, [:hard_link, "forward"]
      assert_includes events, [:hard_link, "indirect"]

      assert_equal "shared", File.read(File.join(dest, "data"))
      assert_equal "shared", File.read(File.join(dest, "forward"))
      assert_equal "shared", File.read(File.join(dest, "indirect"))
      assert_equal "shared", File.read(File.join(dest, "copy"))

      inodes = ["data", "forward", "indirect"].map do |name|
        File.stat(File.join(dest, name)).ino
      end
      copy_inode = File.stat(File.join(dest, "copy")).ino

      assert_equal [inodes.first] * 3, inodes
      refute_equal inodes.first, copy_inode
    end
  end

  def test_hard_links_keep_existing_group_when_path_is_later_replaced
    return if Minitar.windows?

    tar = create_hardlink_tar([
      {type: :file, name: "version", content: "old"},
      {type: :hard_link, name: "old_link", target: "version"},
      {type: :file, name: "version", content: "new"},
      {type: :hard_link, name: "new_link", target: "version"}
    ])

    Dir.mktmpdir("hardlinks", ".tmp") do |tmpdir|
      dest = File.join(tmpdir, "extract")
      Minitar.unpack(StringIO.new(tar), dest, [], hardlinks: true, fsync: false)

      assert_equal "old", File.read(File.join(dest, "old_link"))
      assert_equal "new", File.read(File.join(dest, "version"))
      assert_equal "new", File.read(File.join(dest, "new_link"))

      old_inode = File.stat(File.join(dest, "old_link")).ino
      current_inode = File.stat(File.join(dest, "version")).ino
      new_link_inode = File.stat(File.join(dest, "new_link")).ino

      refute_equal old_inode, current_inode
      assert_equal current_inode, new_link_inode
    end
  end

  def test_hard_link_cycle_is_reported
    return if Minitar.windows?

    tar = create_hardlink_tar([
      {type: :hard_link, name: "a", target: "b"},
      {type: :hard_link, name: "b", target: "a"}
    ])

    Dir.mktmpdir("hardlinks", ".tmp") do |tmpdir|
      dest = File.join(tmpdir, "extract")

      assert_raises(Minitar::HardLinkCycle) do
        Minitar.unpack(StringIO.new(tar), dest, [], hardlinks: true, fsync: false)
      end

      refute File.exist?(File.join(dest, "a"))
      refute File.exist?(File.join(dest, "b"))
    end
  end

  def test_missing_hard_link_target_is_reported_and_completed_files_remain
    return if Minitar.windows?

    tar = create_hardlink_tar([
      {type: :file, name: "completed", content: "kept"},
      {type: :hard_link, name: "link", target: "missing"}
    ])

    Dir.mktmpdir("hardlinks", ".tmp") do |tmpdir|
      dest = File.join(tmpdir, "extract")

      assert_raises(Minitar::BrokenHardLink) do
        Minitar.unpack(StringIO.new(tar), dest, [], hardlinks: true, fsync: false)
      end

      assert_equal "kept", File.read(File.join(dest, "completed"))
      refute File.exist?(File.join(dest, "link"))
    end
  end

  def test_hard_link_cannot_target_directory_indirectly
    return if Minitar.windows?

    tar = create_hardlink_tar([
      {type: :hard_link, name: "a", target: "b"},
      {type: :hard_link, name: "b", target: "dir"},
      {type: :dir, name: "dir"}
    ])

    Dir.mktmpdir("hardlinks", ".tmp") do |tmpdir|
      dest = File.join(tmpdir, "extract")

      assert_raises(Minitar::BrokenHardLink) do
        Minitar.unpack(StringIO.new(tar), dest, [], hardlinks: true, fsync: false)
      end

      assert File.directory?(File.join(dest, "dir"))
      refute File.exist?(File.join(dest, "a"))
      refute File.exist?(File.join(dest, "b"))
    end
  end

  def test_hard_link_does_not_use_preexisting_target_file
    return if Minitar.windows?

    tar = create_hardlink_tar([
      {type: :hard_link, name: "link", target: "existing"}
    ])

    Dir.mktmpdir("hardlinks", ".tmp") do |tmpdir|
      dest = File.join(tmpdir, "extract")
      FileUtils.mkdir_p(dest)
      File.write(File.join(dest, "existing"), "outside archive")

      assert_raises(Minitar::BrokenHardLink) do
        Minitar.unpack(StringIO.new(tar), dest, [], hardlinks: true, fsync: false)
      end

      assert_equal "outside archive", File.read(File.join(dest, "existing"))
      refute File.exist?(File.join(dest, "link"))
    end
  end

  def test_hard_link_does_not_escape_through_preexisting_directory_symlink
    return if Minitar.windows?

    tar = create_hardlink_tar([
      {type: :hard_link, name: "sub/link", target: "sub/data"},
      {type: :file, name: "sub/data", content: "inside archive"}
    ])

    Dir.mktmpdir("hardlinks", ".tmp") do |tmpdir|
      dest = File.join(tmpdir, "extract")
      outside = File.join(tmpdir, "outside")
      FileUtils.mkdir_p(dest)
      FileUtils.mkdir_p(outside)
      File.symlink(File.expand_path(outside), File.join(dest, "sub"))

      assert_raises(Minitar::SecureRelativePathError) do
        Minitar.unpack(StringIO.new(tar), dest, [], hardlinks: true, fsync: false)
      end

      refute File.exist?(File.join(outside, "data"))
      refute File.exist?(File.join(outside, "link"))
    end
  end

  def test_hard_link_callbacks_are_not_emitted_for_missing_links
    return if Minitar.windows?

    tar = create_hardlink_tar([
      {type: :hard_link, name: "link", target: "missing"}
    ])

    Dir.mktmpdir("hardlinks", ".tmp") do |tmpdir|
      dest = File.join(tmpdir, "extract")
      events = []

      assert_raises(Minitar::BrokenHardLink) do
        Minitar.unpack(StringIO.new(tar), dest, [], {hardlinks: true, fsync: false}) do |event, name|
          events << [event, name]
        end
      end

      refute_includes events, [:hard_link, "link"]
    end
  end

  private

  def create_hardlink_tar(entries)
    StringIO.new("".b).tap do |io|
      Minitar::Writer.open(io) do |writer|
        entries.each do |entry|
          case entry[:type]
          when :file
            writer.add_file_simple(entry[:name], data: entry[:content])
          when :dir
            writer.mkdir(entry[:name], mode: 0o755)
          when :hard_link
            header = Minitar::PosixHeader.new(
              name: entry[:name],
              prefix: "",
              size: 0,
              mode: 0o644,
              typeflag: "1",
              linkname: entry[:target]
            )
            io.write(header.to_s)
          end
        end
      end
    end.string
  end
end
