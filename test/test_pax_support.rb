require "minitest_helper"

class TestPaxSupport < Minitest::Test
  def test_pax_header_size_extraction_in_reader
    pax_content = "16 size=1048576\n28 mtime=1749098832.3200000\n"
    tar_data = create_pax_with_file_headers(pax_content, "./PaxHeaders.X/large_file.mov", "large_file.mov", 1048576, 0)

    entries = read_tar_entries(tar_data)
    assert_equal 1, entries.size

    entry = entries.first
    assert_equal "large_file.mov", entry.name
    assert_equal 1048576, entry.size  # Size from PAX header
  end

  def test_pax_header_without_size_uses_header_size
    pax_content = "28 mtime=1749098832.3200000\n"
    tar_data = create_pax_with_file_headers(pax_content, "./PaxHeaders.X/normal_file.txt", "normal_file.txt", 12345, 12345)

    entries = read_tar_entries(tar_data)
    assert_equal 1, entries.size

    entry = entries.first
    assert_equal "normal_file.txt", entry.name
    assert_equal 12345, entry.size  # Original header size preserved
  end

  def test_pax_header_takes_precedence_over_posix_header_size
    pax_content = "16 size=1048576\n28 mtime=1749098832.3200000\n"
    tar_data = create_pax_with_file_headers(pax_content, "./PaxHeaders.X/precedence_file.txt", "precedence_file.txt", 12345, 12345)

    entries = read_tar_entries(tar_data)
    assert_equal 1, entries.size

    entry = entries.first
    assert_equal "precedence_file.txt", entry.name
    assert_equal 1048576, entry.size  # PAX size takes precedence over POSIX size (12345)
  end

  def test_pax_size_extraction_logic
    pax_header_with_size = Minitar::PaxHeader.new(size: "1048576", mtime: "1749098832.3200000")
    assert_equal 1048576, pax_header_with_size.size

    pax_header_without_size = Minitar::PaxHeader.new(mtime: "1749098832.3200000")
    assert_nil pax_header_without_size.size
  end

  def test_global_and_entry_pax_scopes_apply_to_successive_files
    tar_data = write_scoped_pax_archive
    entries = read_tar_entries(tar_data).first(3)

    assert_equal ["global/path", "local/path", "global/path"], entries.map(&:full_name)
    assert_equal ["global/link", "local/link", "global/link"], entries.map(&:linkname)
    assert_equal [1001, 3003, 1001], entries.map(&:uid)
    assert_equal [2002, 4004, 2002], entries.map(&:gid)
    assert_equal ["global-user", "global-user", "global-user"], entries.map(&:uname)
    assert_equal ["global-group", "global-group", "global-group"], entries.map(&:gname)
    assert_equal [
      Rational("1700000000.123456789"),
      Rational("1700000001.987654321"),
      Rational("1700000000.123456789")
    ], entries.map(&:mtime)
    assert_equal ["global", "local", "global"], entries.map { _1.pax_attributes["custom"] }

    scopes = scan_pax_scopes(tar_data)
    assert_equal ["g", "x", "g"], scopes.map { |scope| scope.fetch(:typeflag) }
    assert_equal "global/path", scopes[0].dig(:attributes, "path")
    assert_equal "local/path", scopes[1].dig(:attributes, "path")
    assert_equal "", scopes[2].dig(:attributes, "path")
    scopes.each do |scope|
      assert_equal scope[:posix_size], scope[:parsed_size]
    end

    raw_entries = scan_tar_entries(tar_data).first(3)
    assert_equal ["global/path", "local/path", "global/path"], raw_entries.map { _1[:path] }
    assert_equal ["global/link", "local/link", "global/link"], raw_entries.map { _1[:linkpath] }
    assert_equal [1001, 3003, 1001], raw_entries.map { _1[:uid] }
    assert_equal [2002, 4004, 2002], raw_entries.map { _1[:gid] }
    assert_equal ["global-user", "global-user", "global-user"], raw_entries.map { _1[:uname] }
    assert_equal ["global-group", "global-group", "global-group"], raw_entries.map { _1[:gname] }
    assert_equal [
      Rational("1700000000.123456789"),
      Rational("1700000001.987654321"),
      Rational("1700000000.123456789")
    ], raw_entries.map { _1[:mtime] }
  end

  def test_writer_emits_exact_decimal_time_and_pax_paths
    tar_data = StringIO.new.binmode.tap do |io|
      Minitar::Writer.open(io) do |writer|
        writer.write_pax_header({"uid" => "7"}, scope: :global)
        writer.add_file_simple("short", data: "", mtime: Rational("1700000000.25"))
        writer.add_file_simple("a" * 114, data: "", pax: true, mtime: Rational("1700000001.5"))
        writer.symlink("link", "b" * 114, pax: true)
      end
    end.string

    entries = read_tar_entries(tar_data)
    assert_equal Rational("1700000000.25"), entries[0].mtime
    assert_equal "a" * 114, entries[1].full_name
    assert_equal "b" * 114, entries[2].linkname
    assert_instance_of Rational, entries[0].mtime

    pax_scopes = scan_pax_scopes(tar_data)
    assert_equal "1700000000.25", pax_scopes[1][:attributes]["mtime"]
    assert_equal "a" * 114, pax_scopes[2][:attributes]["path"]
    assert_equal "b" * 114, pax_scopes[3][:attributes]["linkpath"]
  end

  def test_writer_streaming_add_file_expands_pax_header_reserved_blocks
    io = StringIO.new.binmode
    data = "x" * 1024
    long_value = "y" * 1000

    Minitar::Writer.open(io) do |tar|
      tar.add_file("streamed", pax: {}) do |stream, opts|
        stream.write(data)
        opts[:pax] = {"custom" => long_value}
      end
    end

    entry_data = nil
    entry_size = nil
    entry_count = 0
    Minitar::Reader.new(StringIO.new(io.string)).each do |entry|
      entry_count += 1
        entry_data = entry.read(1024)
      entry_size = entry.size
    end

    assert_equal 1, entry_count
    assert_equal data, entry_data
    assert_equal 1024, entry_size

    pax = scan_pax_scopes(io.string).first
    assert_equal "x", pax[:typeflag]
    assert_equal long_value, pax[:attributes]["custom"]
  end

  def test_writer_streaming_add_file_uses_pax_for_long_path
    io = StringIO.new.binmode
    name = "a" * 114
    data = "z" * 1024

    Minitar::Writer.open(io) do |tar|
      tar.add_file(name, pax: true) do |stream, _opts|
        stream.write(data)
      end
    end

    entry_data = nil
    entry_name = nil
    Minitar::Reader.new(StringIO.new(io.string)).each do |entry|
      entry_name = entry.full_name
      entry_data = entry.read(1024)
    end

    assert_equal name, entry_name
    assert_equal data, entry_data

    pax = scan_pax_scopes(io.string).first
    assert_equal "x", pax[:typeflag]
    assert_equal name, pax[:attributes]["path"]
  end

  def test_writer_emits_large_owner_identifiers
    io = StringIO.new.binmode

    Minitar::Writer.open(io) do |writer|
      writer.add_file_simple("owned", data: "", uid: 8_589_934_591, gid: 8_589_934_592)
    end

    entry = read_tar_entries(io.string).first
    assert_equal 8_589_934_591, entry.uid
    assert_equal 8_589_934_592, entry.gid

    pax = scan_pax_scopes(io.string).first
    assert_equal "8589934591", pax[:attributes]["uid"]
    assert_equal "8589934592", pax[:attributes]["gid"]
  end

  private

  def read_tar_entries(tar_data)
    io = StringIO.new(tar_data)
    Minitar::Reader.open(io, &:to_a)
  end

  def create_pax_with_file_headers(pax_content, pax_name, file_name, file_size, posix_header_file_size)
    file_content = "x" * file_size
    padded_file_content = file_content.ljust((file_size / 512.0).ceil * 512, "\0")

    [
      build_tar_pax_header(pax_name, "", pax_content.bytesize),
      pax_content.ljust((pax_content.bytesize / 512.0).ceil * 512, "\0"),
      build_tar_file_header(file_name, "", 0o644, file_size),
      padded_file_content
    ].join
  end

  def write_scoped_pax_archive
    StringIO.new.binmode.tap do |io|
      Minitar::Writer.open(io) do |writer|
        writer.write_pax_header({
          "path" => "global/path",
          "linkpath" => "global/link",
          "uid" => "1001",
          "gid" => "2002",
          "uname" => "global-user",
          "gname" => "global-group",
          "mtime" => "1700000000.123456789",
          "custom" => "global"
        }, scope: :global)
        writer.add_file_simple("first", size: 1, data: "a")

        writer.write_pax_header({
          "path" => "local/path",
          "linkpath" => "local/link",
          "uid" => "3003",
          "gid" => "4004",
          "uname" => "",
          "mtime" => "1700000001.987654321",
          "custom" => "local"
        }, scope: :entry)
        writer.add_file_simple("second", size: 1, data: "b")
        writer.add_file_simple("third", size: 1, data: "c")

        writer.write_pax_header({
          "path" => "",
          "linkpath" => "",
          "uid" => "",
          "gid" => "",
          "uname" => "",
          "gname" => "",
          "mtime" => "",
          "custom" => ""
        }, scope: :global)
        writer.add_file_simple("plain", size: 1, data: "d")
      end
    end.string
  end

  def scan_pax_scopes(tar_data)
    scopes = []
    offset = 0

    while offset + 512 <= tar_data.bytesize
      raw = tar_data.byteslice(offset, 512)
      header = Minitar::PosixHeader.from_data(raw)
      blocks = (header.size.to_i + 511) / 512

      if header.valid? && header.pax_header?
        content = tar_data.byteslice(offset + 512, header.size)
        pax_header = Minitar::PaxHeader.from_data(content)
        scopes << {
          typeflag: header.typeflag,
          posix_size: header.size,
          parsed_size: pax_header.to_s.bytesize,
          attributes: pax_header.attributes
        }
      end

      data_size = header.empty? ? 0 : blocks * 512
      offset += 512 + data_size
    end

    scopes
  end

  def scan_tar_entries(tar_data)
    entries = []
    global = {}
    local = {}
    offset = 0

    while offset + 512 <= tar_data.bytesize
      header = Minitar::PosixHeader.from_data(tar_data.byteslice(offset, 512))
      blocks = ((header.size.to_i + 511) / 512)

      if header.empty?
        offset += 512
        next
      end

      offset += 512

      if header.long_name?
        long_name = tar_data.byteslice(offset, header.size).sub(/\0+\z/, "")
        offset += blocks * 512
        header = Minitar::PosixHeader.from_data(tar_data.byteslice(offset, 512))
        blocks = ((header.size.to_i + 511) / 512)
        offset += 512
        header.long_name = long_name
      end

      if header.pax_header?
        pax = Minitar::PaxHeader.from_data(tar_data.byteslice(offset, header.size))
        target = header.pax_global_header? ? global : local
        pax.attributes.each do |keyword, value|
          if value.empty?
            target.delete(keyword)
          else
            target[keyword] = value
          end
        end
        offset += blocks * 512
        next
      end

      attributes = global.merge(local)
      local = {}
      entries << {
        path: attributes["path"] || [header.prefix, header.name].reject(&:empty?).join("/"),
        linkpath: attributes["linkpath"] || header.linkname,
        uid: attributes["uid"] ? Integer(attributes["uid"]) : header.uid,
        gid: attributes["gid"] ? Integer(attributes["gid"]) : header.gid,
        uname: attributes["uname"] || header.uname,
        gname: attributes["gname"] || header.gname,
        mtime: attributes["mtime"] ? Rational(attributes["mtime"]) : header.mtime
      }
      offset += blocks * 512
    end

    entries
  end
end
