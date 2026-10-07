# frozen_string_literal: true

# Deferred hard link extraction for Minitar.
#
# Tar archives may contain hard link entries (typeflag `1`) whose target has not been
# extracted yet: the target may appear later in the archive, or may itself be another
# hard link entry, forming a chain that eventually ends at a regular file. Extracting
# such archives strictly in read order does not work, so the resolver records hard
# link entries as they are encountered and creates the links once the target entry
# becomes available.
#
# Links are only ever created between entries produced by the current extraction run.
# The resolver never links to pre-existing files, never follows symbolic links outside
# of the extraction root, and never links to directories. When the archive contains
# multiple entries with the same name, each extracted entry replaces the previous
# version on disk (the old name is unlinked rather than truncated in place), so links
# that were already established keep pointing at the inode of the version that was
# current when they were resolved.
#
# When the archive is exhausted, call #finish. Any hard link entries that could not
# be resolved -- because the target is missing from the archive, is not a regular
# file, or is part of a circular chain -- are reported by raising
# Minitar::HardLinkError. Entries that were already extracted or linked are left in
# place; no rollback of the extraction is performed.
#
# ### Usage
#
#     resolver = Minitar::HardLinkResolver.new(dest)
#     Minitar::Input.open(src) do |input|
#       input.each_entry { |entry| resolver.extract_entry(input, entry) }
#       resolver.finish
#     end
#
# This is what `Minitar.unpack(src, dest, [], hardlinks: true)` does.
class Minitar::HardLinkResolver
  # Creates a resolver that extracts into `destdir`. The `options` are passed
  # through to Minitar::Input#extract_entry for non-link entries.
  def initialize(destdir, options = {})
    @destdir = destdir.to_s
    @options = options
    @kinds = {}
    @link_targets = {}
    @available = {}
    @pending = []
  end

  # Processes a single `entry` read from `input`. Directories, regular files, and
  # other entry types are extracted immediately; hard link entries are recorded and
  # resolved as soon as their target entry has been produced by this extraction run.
  def extract_entry(input, entry, &block)
    name = normalize(entry.full_name)

    if entry.hard_link?
      target = normalize(entry.linkname)
      check_relative!(name)
      check_relative!(target)

      (@kinds[name] ||= []) << :hardlink
      (@link_targets[name] ||= []) << target
      @pending << [name, target]
      resolve_pending
    else
      kind =
        if entry.directory?
          :directory
        elsif entry.file?
          :file
        else
          :other
        end

      (@kinds[name] ||= []) << kind
      remove_existing(name) unless kind == :directory
      input.extract_entry(@destdir, entry, @options, &block)

      @available.delete(name)
      if kind == :file
        @available[name] = true
        resolve_pending
      end
    end
  end

  # Verifies that all recorded hard link entries were resolved. Returns `true` when
  # there is nothing left pending; raises Minitar::HardLinkError describing every
  # unresolvable link otherwise. Already extracted entries and already created links
  # are left in place.
  def finish
    return true if @pending.empty?

    problems = @pending.map { |name, target|
      "  #{name} -> #{target}: #{diagnose(name, target)}"
    }

    raise Minitar::HardLinkError,
      "could not resolve #{@pending.size} hard link(s):\n#{problems.join("\n")}"
  end

  private

  def normalize(name)
    name.squeeze("/").sub(%r{/+\z}, "")
  end

  def check_relative!(name)
    if /\.{2}(?:\/|\z)/.match?(name)
      raise Minitar::SecureRelativePathError, "Path contains '..'"
    end
  end

  def resolve_pending
    until @pending.empty?
      resolved = @pending.reject! { |name, target| try_link(name, target) }
      break if resolved.nil?
    end
  end

  def try_link(name, target)
    return false unless @available[target]

    create_link(name, target)
    @available[name] = true
    true
  end

  def create_link(name, target)
    link_path = File.join(@destdir, name)
    target_path = File.join(@destdir, target)

    FileUtils.mkdir_p(File.dirname(link_path), mode: 0o755)

    verify_within_root!(File.dirname(link_path))
    verify_within_root!(target_path)

    if File.symlink?(link_path) || (File.exist?(link_path) && !File.directory?(link_path))
      File.unlink(link_path)
    end

    File.link(target_path, link_path)
  end

  def remove_existing(name)
    path = File.join(@destdir, name)

    if File.symlink?(path) || (File.exist?(path) && !File.directory?(path))
      File.unlink(path)
    end
  end

  def verify_within_root!(path)
    root = File.realpath(@destdir)
    real = File.realpath(path)

    unless real == root || real.start_with?(root + File::SEPARATOR)
      raise Minitar::HardLinkError,
        "hard link path #{path.inspect} resolves outside of #{@destdir.inspect}"
    end
  end

  def diagnose(name, target)
    seen = [name]
    node = target

    loop do
      kinds = @kinds[node]

      return "#{node.inspect} is not present in the archive" if kinds.nil?

      targets = @link_targets[node]

      if targets && !targets.empty?
        if seen.include?(node)
          return "circular hard link chain (#{(seen + [node]).join(" -> ")})"
        end

        seen << node
        node = targets.last
        next
      end

      return "#{node.inspect} is a directory" if kinds.include?(:directory)
      return "#{node.inspect} is not a regular file" unless kinds.include?(:file)

      return "#{node.inspect} could not be extracted"
    end
  end
end
