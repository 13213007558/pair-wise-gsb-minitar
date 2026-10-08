# frozen_string_literal: true

require "minitest_helper"

class TestGnuSparseRejection < Minitest::Test
  def test_pax_sparse_0_0_is_rejected
    pax = Minitar::PaxHeader.new(
      "GNU.sparse.numblocks" => "1",
      "GNU.sparse.offset" => "0",
      "GNU.sparse.numbytes" => "4",
      "GNU.sparse.size" => "8"
    )
    assert_raises(Minitar::InvalidTarStream) do
      Minitar::Input.open(StringIO.new(build_pax_sparse_tarball(pax))) { _1.each_entry {} }
    end
  end

  def test_pax_sparse_0_1_is_rejected
    pax = Minitar::PaxHeader.new("GNU.sparse.map" => "0,4", "GNU.sparse.size" => "8")
    assert_raises(Minitar::InvalidTarStream) do
      Minitar::Input.open(StringIO.new(build_pax_sparse_tarball(pax))) { _1.each_entry {} }
    end
  end

  private

  def build_pax_sparse_tarball(pax_header)
    pax_content = pax_header.to_s
    pax_header_block = Minitar::PosixHeader.new(
      prefix: "",
      name: "././PaxHeaders.0/file",
      typeflag: "x",
      size: pax_content.bytesize,
      mode: 0
    ).to_s
    pax_header_block += pax_content.ljust(
      (pax_content.bytesize / 512.0).ceil * 512,
      "\0"
    )
    file_header = build_tar_file_header("file", "", 0o644, 4)
    pax_header_block + file_header + "data" + "\0" * 1020 + "\0" * 1024
  end
end
