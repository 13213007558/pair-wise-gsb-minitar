# frozen_string_literal: true

require_relative "input/hard_link_extractor"

# This wraps a Minitar::Reader with convenience methods and wrapped stream management;
# Input only works with data streams that can be rewound.
#
# ### Security Notice
#
# Constructing a Minitar::Input will use Kernel.open if the provided input is not
# a readable stream object. Using an untrusted value for input may allow a malicious
# user to execute arbitrary system commands. It is the **caller's responsibility** to
# ensure that the input value is safe.
#
# * [CWE-073](https://cwe.mitre.org/data/definitions/73.html)
# * [CWE-078](https://cwe.mitre.org/data/definitions/78.html)
# * [CWE-088](https://cwe.mitre.org/data/definitions/88.html)
#
# This notice applies to Minitar::Input.open, Minitar::Input.each_entry, and
# Minitar::Input.new.
class Minitar::Input
  include Enumerable

  # With no associated block, `Input.open` is a synonym for `Input.new`.
  #
  # If a block is given, the new Input will be yielded to the block as an argument and
  # the Input object will automatically be closed when the block terminates (this also
  # closes the wrapped stream object). The return value will be the value of the block.
  #
  # :call-seq:
  #    Minitar::Input.open(io) -> input
  #    Minitar::Input.open(io) { |input| block } -> obj
  def self.open(input)
    stream = new(input)

    if block_given?
      # This exception context must remain, otherwise the stream closes on open even if
      # a block is not given.
      begin
        yield stream
      ensure
        stream.close
      end
    else
      stream
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
  #    Minitar::Input.each_entry(io) -> enumerator
  #    Minitar::Input.each_entry(io) { |entry| block } -> obj
  def self.each_entry(input)
    return to_enum(__method__, input) unless block_given?

    Input.open(input) do |stream|
      stream.each do |entry|
        yield entry
      end
    end
  end

  # Creates a new Input object. If `input` is a stream object that responds to #read,
  # then it will simply be wrapped. Otherwise, one will be created and opened using
  # Kernel.open. When Input#close is called, the stream object wrapped will be closed.
  #
  # An exception will be raised if the stream that is wrapped does not support
  # rewinding.
  #
  # :call-seq:
  #    Minitar::Input.new(io) -> input
  #    Minitar::Input.new(path) -> input
  def initialize(input)
    @io =
      if input.respond_to?(:read)
        input
      else
        ::Kernel.open(input, "rb")
      end

    raise Minitar::NonSeekableStream unless Minitar.seekable?(@io, :rewind)

    @tar = Minitar::Reader.new(@io)
    @hard_link_extractors = {}
  end

  # When provided a block, iterates through each entry in the archive. When finished,
  # rewinds to the beginning of the stream.
  #
  # If not provided a block, creates an enumerator with the same semantics.
  def each_entry
    return to_enum unless block_given?

    @tar.each do |entry|
      yield entry
    end
  ensure
    @tar.rewind
  end
  alias_method :each, :each_entry

  # Extracts the current `entry` to `destdir`. If a block is provided, it yields an
  # `action` Symbol, the full name of the file being extracted (`name`), and a Hash of
  # statistical information (`stats`).
  #
  # The `action` will be one of:
  #
  # - `:dir`: The `entry` is a directory.
  # - `:hard_link`: A hard link has been created.
  # - `:file_start`: The `entry` is a file; the extract of the file is just beginning.
  # - `:file_progress`: Yielded every 4096 bytes during the extract of the `entry`.
  # - `:file_done`: Yielded when the `entry` is completed.
  #
  # The `stats` hash may contain the following keys:
  #
  # - `:current`: The current total number of bytes read in the `entry`.
  # - `:currinc`: The current number of bytes read in this read cycle.
  # - `:entry`: The entry being extracted; this is a Minitar::Reader::EntryStream.
  #
  # Pass `hardlinks: true` in `options` to create hard-link entries. Links may appear
  # before their targets in the archive; Minitar.unpack resolves those dependencies
  # after all entries have been read. When using #extract_entry directly, call
  # #finish_extraction after processing the archive.
  def extract_entry(destdir, entry, options = {}, &) # :yields: action, name, stats
    stats = {
      current: 0,
      currinc: 0,
      entry: entry
    }

    # extract_entry is not vulnerable to prefix '/' vulnerabilities, but it is
    # vulnerable to relative path directories. This code will break this vulnerability.
    # For this version, we are breaking relative paths HARD by throwing an exception.
    #
    # Future versions may permit relative paths as long as the file does not leave
    # `destdir`.
    #
    # However, squeeze consecutive '/' characters together.
    full_name = secure_archive_path(entry.full_name)
    hard_links = hard_link_extractor(destdir, options)

    if entry.directory?
      hard_links&.add_directory(full_name)
      extract_directory(destdir, full_name, entry, stats, options, &)
    elsif entry.hard_link?
      unless hard_links
        return extract_file(destdir, full_name, entry, stats, options, nil, &)
      end

      add_archive_hard_link(hard_links, full_name, entry, stats, &)
    else # it's a file
      node = hard_links&.prepare_regular(full_name)
      extract_file(destdir, full_name, entry, stats, options, hard_links, node, &)
    end
  end

  # Completes extraction of entries which depend on hard-link targets that appeared
  # later in the archive. This is called automatically by Minitar.unpack when the
  # `:hardlinks` option is enabled.
  def finish_extraction(destdir, options = {})
    return unless hard_links_enabled?(options)

    extractor = @hard_link_extractors[destdir]
    extractor&.finish
  ensure
    @hard_link_extractors.delete(destdir)
  end

  # Returns false if the wrapped data stream is open.
  def closed? = @io.closed?

  # Returns the Minitar::Reader object for direct access.
  attr_reader :tar

  # Closes both the Minitar::Reader object and the wrapped data stream.
  def close
    @io.close
    @tar.close
  end

  private

  def hard_link_extractor(destdir, options)
    return unless hard_links_enabled?(options)

    @hard_link_extractors[destdir] ||= HardLinkExtractor.new(destdir)
  end

  def hard_links_enabled?(options)
    options[:hardlinks] || options[:hard_links]
  end

  def add_archive_hard_link(hard_links, full_name, entry, stats, &block)
    if block
      hard_links.add_hard_link(full_name, entry.linkname) do
        yield :hard_link, full_name, stats
      end
    else
      hard_links.add_hard_link(full_name, entry.linkname)
    end
  end

  def secure_archive_path(value)
    full_name = value.to_s.squeeze("/")

    if /\.{2}(?:\/|\z)/.match?(full_name)
      raise Minitar::SecureRelativePathError, "Path contains '..'"
    end

    full_name
  end

  def fsync_dir(dirname)
    # make sure this hits the disc
    dir = IO.open(dirname, "rb")
    dir.fsync
  rescue # ignore IOError if it's an unpatched (old) Ruby
    nil
  ensure
    dir&.close rescue nil # standard:disable Style/RescueModifier
  end

  def extract_directory(destdir, full_name, entry, stats, options, &block)
    dest = File.join(destdir, full_name)

    block&.call(:dir, full_name, stats)

    if Minitar.dir?(dest)
      begin
        FileUtils.chmod(entry.mode, dest)
      rescue
        nil
      end
    else
      File.unlink(dest.chomp("/")) if File.symlink?(dest.chomp("/"))

      FileUtils.mkdir_p(dest, mode: entry.mode)
      FileUtils.chmod(entry.mode, dest)
    end

    if options.fetch(:fsync, true)
      fsync_dir(dest)
      fsync_dir(File.join(dest, ".."))
    end
  end

  def extract_file(destdir, full_name, entry, stats, options, hard_links = nil,
    hard_link_node = nil)
    destdir = File.join(destdir, File.dirname(full_name))
    FileUtils.mkdir_p(destdir, mode: 0o755) unless hard_links

    destfile = File.join(destdir, File.basename(full_name))

    if hard_links
      File.unlink(destfile) if File.symlink?(destfile) || File.file?(destfile)
    else
      File.unlink(destfile) if File.symlink?(destfile)
    end

    # Errno::ENOENT
    begin
      FileUtils.chmod(0o600, destfile)
    rescue
      nil
    end

    yield :file_start, full_name, stats if block_given?

    File.open(destfile, "wb", entry.mode) do |os|
      loop do
        data = entry.read(4096)
        break unless data

        stats[:currinc] = os.write(data)
        stats[:current] += stats[:currinc]

        yield :file_progress, full_name, stats if block_given?
      end

      if options.fetch(:fsync, true)
        yield :file_fsync, full_name, stats if block_given?
        os.fsync
      end
    end

    FileUtils.chmod(entry.mode, destfile)

    if options.fetch(:fsync, true)
      yield :dir_fsync, full_name, stats if block_given?

      fsync_dir(File.dirname(destfile))
      fsync_dir(File.join(File.dirname(destfile), ".."))
    end

    yield :file_done, full_name, stats if block_given?

    hard_links.commit_regular(full_name, hard_link_node) if hard_links
  end
end
