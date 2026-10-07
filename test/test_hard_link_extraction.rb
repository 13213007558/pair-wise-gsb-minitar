# frozen_string_literal: true

require "minitest_helper"
require "tmpdir"

class TestHardLinkExtraction < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @dest = File.join(@tmpdir, "dest")
    FileUtils.mkdir_p(@dest)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_hard_link_to_preceding_file
    return if Minitar.windows?

    unpack_archive([
      file("a", "payload"),
      hardlink("b", "a")
    ])

    assert_same_inode("a", "b")
    assert_equal 2, File.stat(path("a")).nlink
    assert_equal "payload", File.read(path("b"))
  end

  def test_forward_hard_link_chain
    return if Minitar.windows?

    unpack_archive([
      hardlink("c", "b"),
      hardlink("b", "a"),
      file("a", "payload")
    ])

    assert_same_inode("a", "b")
    assert_same_inode("b", "c")
    assert_equal 3, File.stat(path("a")).nlink
    assert_equal "payload", File.read(path("c"))
  end

  def test_duplicate_path_versions_keep_established_links
    return if Minitar.windows?

    unpack_archive([
      file("a", "one"),
      hardlink("b", "a"),
      hardlink("c", "a"),
      file("a", "two")
    ])

    assert_equal "two", File.read(path("a"))
    assert_equal "one", File.read(path("b"))
    assert_equal "one", File.read(path("c"))

    assert_same_inode("b", "c")
    assert_equal 2, File.stat(path("b")).nlink

    refute_same_inode("a", "b")
    assert_equal 1, File.stat(path("a")).nlink
  end

  def test_pure_cycle_is_reported
    error = assert_raises(Minitar::HardLinkError) do
      unpack_archive([
        file("ok", "fine"),
        hardlink("x", "y"),
        hardlink("y", "x")
      ])
    end

    assert_match(/circular/, error.message)
    assert_match(/x -> y/, error.message)

    # Completed entries are kept; no rollback of the extraction is performed.
    assert_equal "fine", File.read(path("ok"))
    refute File.exist?(path("x"))
    refute File.exist?(path("y"))
  end

  def test_missing_target_is_reported
    error = assert_raises(Minitar::HardLinkError) do
      unpack_archive([
        file("ok", "fine"),
        hardlink("x", "ghost")
      ])
    end

    assert_match(/not present in the archive/, error.message)
    assert_equal "fine", File.read(path("ok"))
    refute File.exist?(path("x"))
  end

  def test_chain_ending_in_missing_target_is_reported
    error = assert_raises(Minitar::HardLinkError) do
      unpack_archive([
        hardlink("x", "y"),
        hardlink("y", "ghost")
      ])
    end

    assert_match(/not present in the archive/, error.message)
  end

  def test_directory_target_is_rejected
    error = assert_raises(Minitar::HardLinkError) do
      unpack_archive([
        dir("d"),
        hardlink("l", "d")
      ])
    end

    assert_match(/is a directory/, error.message)
    refute File.exist?(path("l"))
  end

  def test_symlink_entry_target_is_rejected
    error = assert_raises(Minitar::HardLinkError) do
      unpack_archive([
        symlink("s", "elsewhere"),
        hardlink("l", "s")
      ])
    end

    assert_match(/not a regular file/, error.message)
    refute File.exist?(path("l"))
  end

  def test_preexisting_file_is_not_borrowed
    File.write(path("victim"), "original")

    error = assert_raises(Minitar::HardLinkError) do
      unpack_archive([
        hardlink("l", "victim")
      ])
    end

    assert_match(/not present in the archive/, error.message)
    assert_equal "original", File.read(path("victim"))
    refute File.exist?(path("l"))
  end

  def test_link_path_cannot_escape_root_through_symlink
    return if Minitar.windows?

    outside = File.join(@tmpdir, "outside")
    FileUtils.mkdir_p(outside)
    File.symlink(outside, path("sub"))

    error = assert_raises(Minitar::HardLinkError) do
      unpack_archive([
        file("a", "payload"),
        hardlink("sub/l", "a")
      ])
    end

    assert_match(/outside/, error.message)
    refute File.exist?(File.join(outside, "l"))
  end

  def test_relative_target_is_rejected
    assert_raises(Minitar::SecureRelativePathError) do
      unpack_archive([
        hardlink("l", "../evil")
      ])
    end
  end

  def test_default_extraction_treats_hard_link_as_empty_file
    Minitar.unpack(
      StringIO.new(build_archive([file("a", "payload"), hardlink("b", "a")])),
      @dest
    )

    assert_equal "", File.read(path("b"))
    refute_same_inode("a", "b")
  end

  private

  def path(name) = File.join(@dest, name)

  def file(name, content) = [:file, name, content]

  def dir(name) = [:dir, name]

  def hardlink(name, target) = [:hardlink, name, target]

  def symlink(name, target) = [:symlink, name, target]

  def unpack_archive(entries)
    Minitar.unpack(StringIO.new(build_archive(entries)), @dest, [], hardlinks: true)
  end

  def build_archive(entries)
    StringIO.new.tap { |io|
      entries.each do |entry|
        case entry.first
        when :file
          _, name, content = entry
          io.write build_tar_file_header(name, "", 0o644, content.bytesize)
          io.write content
          io.write "\0" * ((512 - (content.bytesize % 512)) % 512)
        when :dir
          io.write build_tar_dir_header(entry[1], "", 0o755)
        when :hardlink
          io.write build_tar_hardlink_header(entry[1], entry[2])
        when :symlink
          io.write build_tar_symlink_header(entry[1], "", 0o777, entry[2])
        end
      end
      io.write "\0" * 1024
    }.string
  end

  def build_tar_hardlink_header(name, target) =
    build_header("1", name, "", 0, 0o644, target).then { update_header_checksum(_1) }

  def assert_same_inode(name_a, name_b)
    return if Minitar.windows?

    assert_equal File.stat(path(name_a)).ino, File.stat(path(name_b)).ino,
      "#{name_a} and #{name_b} should share an inode"
  end

  def refute_same_inode(name_a, name_b)
    return if Minitar.windows?

    refute_equal File.stat(path(name_a)).ino, File.stat(path(name_b)).ino,
      "#{name_a} and #{name_b} should not share an inode"
  end
end
