# frozen_string_literal: true

class Minitar::Input
  # Tracks hard-link dependencies while an archive is being extracted. A hard-link
  # entry may appear before the entry that supplies its data, so links are resolved
  # against archive entries rather than files that already exist on disk.
  class HardLinkExtractor
    Node = Struct.new(
      :id, :kind, :source_path, :target_path, :target_id, :group_id, :failed,
      :callback,
      keyword_init: true
    ) do
      def regular? = kind == :regular

      def directory? = kind == :directory

      def hard_link? = kind == :hard_link
    end

    attr_reader :failures

    def initialize(destdir)
      FileUtils.mkdir_p(destdir)
      @destdir = File.realpath(destdir)
      @nodes = {}
      @current = {}
      @dependents = Hash.new { |hash, key| hash[key] = [] }
      @waiting = Hash.new { |hash, key| hash[key] = [] }
      @group_paths = Hash.new { |hash, key| hash[key] = [] }
      @anchors = {}
      @materialized = {}
      @failures = []
      @next_id = 0
    end

    def destination(full_name)
      File.join(@destdir, normalize_path(full_name))
    end

    def prepare_regular(full_name)
      path = normalize_path(full_name)
      node = add_node(path, :regular)
      prepare_parent(path)
      remove_current_path(path)
      @materialized.delete(path)
      node
    end

    def commit_regular(full_name, node)
      path = normalize_path(full_name)
      dest = destination(path)
      unless File.file?(dest)
        raise Minitar::BrokenHardLink, "Extracted file is missing: #{path}"
      end

      add_to_group(node.id, path)
      @materialized[path] = node.id
      fulfill(node, node.id)
    end

    def add_directory(full_name)
      path = normalize_path(full_name)
      node = add_node(path, :directory)
      fail(node, "targets directory '#{path}'")
      node
    end

    def add_hard_link(full_name, linkname, &callback)
      path = normalize_path(full_name)
      target_path = normalize_path(linkname)
      target_id = @current[target_path]
      node = add_node(path, :hard_link, target_path)
      node.callback = callback

      if target_id
        attach(node, target_id)
      else
        @waiting[target_path] << node
      end

      node
    end

    def finish
      @waiting.each_value do |nodes|
        nodes.each do |node|
          next if node.group_id || node.failed

          mark_missing(node, node.target_path)
        end
      end

      @nodes.each_value do |node|
        next unless node.hard_link? && node.target_id && !node.group_id && !node.failed

        status = unresolved_status(node, [])
        next unless status

        kind, detail = status
        case kind
        when :missing
          mark_missing(node, detail)
        when :cycle
          mark_cycle(node, detail)
        when :directory
          fail(node, "indirectly targets directory '#{detail}'")
        end
      end

      raise_aggregated_failure if @failures.any?
    end

    private

    def add_node(path, kind, target_path = nil)
      node = Node.new(
        id: @next_id,
        kind: kind,
        source_path: path,
        target_path: target_path,
        target_id: nil,
        group_id: nil,
        failed: false,
        callback: nil
      )
      @next_id += 1
      @nodes[node.id] = node
      @current[path] = node.id

      (@waiting.delete(path) || []).each do |waiting|
        attach(waiting, node.id)
      end

      node
    end

    def attach(node, target_id)
      return if node.target_id

      node.target_id = target_id
      @dependents[target_id] << node

      target = @nodes[target_id]
      return unless target.group_id

      fulfill(node, target.group_id)
    end

    def fulfill(node, group_id)
      return if node.failed || node.group_id

      if node.directory?
        fail(node, "targets directory '#{node.source_path}'")
        return
      end

      node.group_id = group_id
      materialize_hard_link(node) if node.hard_link?
      @dependents[node.id].each { |dependent| fulfill(dependent, group_id) }
    end

    def fail(node, detail)
      return if node.failed || node.group_id

      node.failed = true
      if node.hard_link?
        @failures << Minitar::BrokenHardLink.new(
          "Hard link '#{node.source_path}' #{detail}"
        )
      end
      @dependents[node.id].each { |dependent| fail(dependent, detail) }
    end

    def mark_missing(node, target_path)
      return if node.failed

      node.failed = true
      @failures << Minitar::BrokenHardLink.new(
        "Hard link '#{node.source_path}' points to missing archive entry '#{target_path}'"
      )
      @dependents[node.id].each { |dependent| mark_missing(dependent, target_path) }
    end

    def mark_cycle(node, path)
      node.failed = true
      @failures << Minitar::HardLinkCycle.new(
        "Hard link '#{node.source_path}' is part of an unresolved cycle (#{path.join(' -> ')})"
      )
    end

    def unresolved_status(node, stack)
      return nil if node.group_id || node.failed

      target_id = node.target_id
      return [:missing, node.target_path] unless target_id
      return [:cycle, cycle_path(stack, node, target_id)] if stack.include?(target_id)

      target = @nodes[target_id]
      return [:missing, node.target_path] unless target
      return [:directory, target.source_path] if target.directory?
      return nil if target.regular? && target.group_id

      unresolved_status(target, stack + [node.id])
    end

    def cycle_path(stack, node, target_id)
      ids = stack + [node.id, target_id]
      start = ids.index(target_id)
      ids[start..].map { |id| @nodes[id].source_path }
    end

    def materialize_hard_link(node)
      return unless @current[node.source_path] == node.id

      path = node.source_path
      dest = destination(path)
      prepare_parent(path)

      if File.symlink?(dest) || File.file?(dest)
        if @materialized[path] == node.group_id
          return
        end

        remove_current_path(path)
        File.unlink(dest)
      elsif File.exist?(dest)
        raise Minitar::BrokenHardLink, "Hard link target is not a file: #{path}"
      end

      anchor = @anchors[node.group_id]
      unless anchor
        raise Minitar::BrokenHardLink, "Hard link data is unavailable for '#{path}'"
      end

      File.link(destination(anchor), dest)
      add_to_group(node.group_id, path)
      @materialized[path] = node.id
      node.callback&.call
    end

    def remove_current_path(path)
      node_id = @materialized.delete(path)
      return unless node_id

      paths = @group_paths[node_id]
      paths.delete(path)
      if @anchors[node_id] == path
        @anchors[node_id] = paths.first
      end
    end

    def add_to_group(group_id, path)
      paths = @group_paths[group_id]
      paths << path unless paths.include?(path)
      @anchors[group_id] ||= path
    end

    def prepare_parent(path)
      logical = @destdir

      parent_parts = File.dirname(path).split(File::SEPARATOR)
      parent_parts.each do |part|
        next if part == "."

        logical = File.join(logical, part)

        if File.symlink?(logical)
          target = File.expand_path(File.readlink(logical), File.dirname(logical))
          unless within_destination?(target)
            raise Minitar::SecureRelativePathError, "Path escapes extraction root"
          end
        elsif File.exist?(logical)
          raise Minitar::SecureRelativePathError, "Path escapes extraction root" unless
            within_destination?(File.realpath(logical))
        end

        FileUtils.mkdir(logical) unless File.exist?(logical) || File.symlink?(logical)
      end
    end

    def within_destination?(path)
      path == @destdir || path.start_with?("#{@destdir}#{File::SEPARATOR}")
    end

    def normalize_path(value)
      path = value.to_s.squeeze("/").sub(%r{\A/+(?=.)}, "")
      parts = []

      path.split("/").each do |part|
        next if part.empty? || part == "."

        if part == ".."
          raise Minitar::SecureRelativePathError, "Path contains '..'"
        end

        parts << part
      end

      raise Minitar::BrokenHardLink, "Hard link path is empty" if parts.empty?

      parts.join("/")
    end

    def raise_aggregated_failure
      raise @failures.first if @failures.one?

      message = @failures.map(&:message).join("; ")
      if @failures.all? { |error| error.is_a?(Minitar::HardLinkCycle) }
        raise Minitar::HardLinkCycle, message
      end
      if @failures.all? { |error| error.is_a?(Minitar::BrokenHardLink) }
        raise Minitar::BrokenHardLink, message
      end

      raise Minitar::HardLinkError, message
    end
  end
end
