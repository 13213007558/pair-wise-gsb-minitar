require "minitest_helper"

class TestPaxScopes < Minitest::Test
  def test_global_and_extended_header_scopes
    archive = build_archive
    raw_entries = parse_pax_archive(archive)
    reader_entries = read_tar_entries(archive)

    expected = [
      {
        name: "global/path.txt",
        linkname: "global/target",
        uid: 1001,
        gid: 1002,
        uname: "global-user",
        gname: "global-group",
        mtime: Rational("123.25"),
        custom: "global"
      },
      {
        name: "local/path.txt",
        linkname: "local/target",
        uid: 2001,
        gid: 2002,
        uname: "local-user",
        gname: "local-group",
        mtime: Rational("234.5"),
        custom: "local"
      },
      {
        name: "global/path.txt",
        linkname: "global/target",
        uid: 1001,
        gid: 1002,
        uname: "global-user",
        gname: "global-group",
        mtime: Rational("123.25"),
        custom: "global"
      }
    ]

    assert_pax_entries(expected, raw_entries)
    assert_pax_entries(expected, reader_entries.map { |entry|
      entry_to_expected(entry)
    })
  end

  def test_empty_global_header_deletes_global_keys
    archive = StringIO.new.tap do |io|
      writer = Minitar::Writer.new(io)
      writer.add_pax_header({
        "path" => "global/path.txt",
        "uname" => "global-user",
        "custom" => "global"
      }, global: true)
      writer.add_file_simple("base", data: "first")
      writer.add_pax_header({
        "path" => "",
        "uname" => "",
        "custom" => ""
      }, global: true)
      writer.add_file_simple("base", data: "second")
      writer.close
    end.string

    raw_entries = parse_pax_archive(archive)

    assert_equal "global/path.txt", raw_entries.fetch(0).fetch(:name)
    assert_equal "global-user", raw_entries.fetch(0).fetch(:uname)
    assert_equal "base", raw_entries.fetch(1).fetch(:name)
    assert_nil raw_entries.fetch(1).fetch(:uname)
    assert_nil raw_entries.fetch(1).fetch(:custom)
  end

  def test_empty_extended_header_deletes_only_next_entry_override
    archive = StringIO.new.tap do |io|
      writer = Minitar::Writer.new(io)
      writer.add_pax_header({"path" => "global/path.txt", "custom" => "global"}, global: true)
      writer.add_file_simple("base", data: "first")
      writer.add_pax_header({"path" => "", "custom" => ""})
      writer.add_file_simple("base", data: "second")
      writer.add_file_simple("base", data: "third")
      writer.close
    end.string

    entries = read_tar_entries(archive)

    assert_equal "global/path.txt", entries[0].full_name
    assert_equal "global", entries[0].pax_attributes["custom"]
    assert_equal "base", entries[1].full_name
    refute_includes entries[1].pax_attributes, "custom"
    assert_equal "global/path.txt", entries[2].full_name
    assert_equal "global", entries[2].pax_attributes["custom"]
  end

  def test_writer_uses_exact_decimal_time_and_utf8_long_path
    long_path = "dossier/é/" + "a" * 120
    archive = StringIO.new.tap do |io|
      writer = Minitar::Writer.new(io)
      writer.add_file_simple(
        long_path,
        data: "x",
        mtime: Rational("123.25"),
        pax: {
          "linkpath" => "cible/é/" + "b" * 120,
          "mtime" => "123.25"
        }
      )
      writer.close
    end.string

    entry = read_tar_entries(archive).first

    assert_equal long_path, entry.full_name.force_encoding("UTF-8")
    assert_equal "cible/é/" + "b" * 120, entry.linkname.force_encoding("UTF-8")
    assert_equal Rational("123.25"), entry.mtime
    assert_equal long_path.bytesize, parse_pax_archive(archive).first.dig(:attributes, "path").bytesize
  end

  def test_streaming_large_size_reserves_and_inserts_pax_header
    io = StringIO.new
    writer = Minitar::Writer.new(io)
    init_pos = 0
    data_offset = 512
    io.write("\0" * data_offset)
    io.write("abc" + "\0" * 509)
    io.write("def" + "\0" * 509)
    writer.send(:shift_data_for_size_pax_header, init_pos, data_offset, 1024, 0)

    assert_equal "\0" * 512, io.string[0, 512]
    assert_equal "abc", io.string[1024, 3]
    assert_equal "def", io.string[1536, 3]
  end

  private

  def build_archive
    StringIO.new.tap do |io|
      writer = Minitar::Writer.new(io)
      writer.add_pax_header(global_attributes, global: true)
      writer.add_file_simple("base-one", data: "one")
      writer.add_pax_header(local_attributes)
      writer.add_file_simple("base-two", data: "two")
      writer.add_file_simple("base-three", data: "three")
      writer.close
    end.string
  end

  def global_attributes
    {
      "path" => "global/path.txt",
      "linkpath" => "global/target",
      "uid" => "1001",
      "gid" => "1002",
      "uname" => "global-user",
      "gname" => "global-group",
      "mtime" => "123.25",
      "custom" => "global"
    }
  end

  def local_attributes
    {
      "path" => "local/path.txt",
      "linkpath" => "local/target",
      "uid" => "2001",
      "gid" => "2002",
      "uname" => "local-user",
      "gname" => "local-group",
      "mtime" => "234.5",
      "custom" => "local"
    }
  end

  def assert_pax_entries(expected, actual)
    assert_equal expected.size, actual.size

    expected.each_with_index do |expected_entry, index|
      expected_entry.each do |keyword, expected_value|
        assert_equal expected_value, actual.fetch(index).fetch(keyword),
          "Entry #{index} #{keyword}"
      end
    end
  end

  def entry_to_expected(entry)
    {
      name: entry.full_name,
      linkname: entry.linkname,
      uid: entry.uid,
      gid: entry.gid,
      uname: entry.uname.empty? ? nil : entry.uname,
      gname: entry.gname.empty? ? nil : entry.gname,
      mtime: entry.mtime,
      custom: entry.pax_attributes["custom"]
    }
  end

  def read_tar_entries(archive)
    Minitar::Reader.open(StringIO.new(archive), &:to_a)
  end

  def parse_pax_archive(archive)
    io = StringIO.new(archive)
    global_attributes = {}
    local_attributes = nil
    entries = []

    until io.eof?
      header_data = io.read(512)
      header = Minitar::PosixHeader.from_data(header_data)
      break if header.empty?

      data_blocks = (header.size / 512.0).ceil
      data = io.read(data_blocks * 512).byteslice(0, header.size)

      if header.typeflag == "g" || header.typeflag == "x"
        attributes = Minitar::PaxHeader.from_data(data).attributes
        target = header.typeflag == "g" ? global_attributes : (local_attributes ||= {})

        attributes.each do |keyword, value|
          if value.empty?
            target.delete(keyword)
          else
            target[keyword] = value
          end
        end
      else
        attributes = Minitar::PaxHeader.merge_attributes(global_attributes, local_attributes || {})
        base_name = if header.prefix.empty?
      header.name
    else
      File.join(header.prefix, header.name)
    end

    entries << {
      name: (attributes["path"] || base_name).force_encoding("UTF-8"),
      linkname: attributes["linkpath"] || header.linkname,
      uid: attributes.key?("uid") ? Integer(attributes["uid"]) : header.uid,
      gid: attributes.key?("gid") ? Integer(attributes["gid"]) : header.gid,
      uname: attributes["uname"]&.force_encoding("UTF-8"),
      gname: attributes["gname"]&.force_encoding("UTF-8"),
      mtime: attributes.key?("mtime") ? Rational(attributes["mtime"]) : header.mtime,
      custom: attributes["custom"]&.force_encoding("UTF-8"),
      attributes: attributes
    }
        local_attributes = nil
      end
    end

    entries
  end
end
