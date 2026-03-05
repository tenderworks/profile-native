#!/usr/bin/env ruby
# frozen_string_literal: true

# Reads a Firefox-formatted Vernier profile (.json.gz) and outputs a
# markdown report optimized for consumption by AI tools.

require "json"
require "zlib"

class FirefoxProfileReader
  def initialize(path)
    json = File.binread(path)
    # Gzip magic number: 1f 8b
    if json.byteslice(0, 2) == "\x1F\x8B".b
      json = Zlib::Inflate.new(Zlib::MAX_WBITS | 16).inflate(json)
    end
    @data = JSON.parse(json)
    @meta = @data["meta"]
    @categories = @meta["categories"]
  end

  def to_markdown
    out = +""
    out << "# Profile: #{@meta["product"]}\n\n"
    out << build_summary
    @data["threads"].each_with_index do |thread, i|
      out << build_thread_report(thread, i)
    end
    out
  end

  private

  def build_summary
    out = +"## Summary\n\n"
    out << "| Metric | Value |\n"
    out << "|--------|-------|\n"
    out << "| Product | #{@meta["product"]} |\n"
    out << "| Threads | #{@data["threads"].size} |\n"

    if (user_meta = @meta["vernierUserMetadata"]) && !user_meta.empty?
      user_meta.each do |k, v|
        out << "| #{k} | #{v} |\n"
      end
    end

    out << "\n"
  end

  def build_thread_report(thread, index)
    strings = thread["stringArray"]
    samples = thread["samples"]
    stack_table = thread["stackTable"]
    frame_table = thread["frameTable"]
    func_table = thread["funcTable"]

    out = +"## Thread #{index}: #{thread["name"]}\n\n"
    out << "| Property | Value |\n"
    out << "|----------|-------|\n"
    out << "| TID | #{thread["tid"]} |\n"
    out << "| Main Thread | #{thread["isMainThread"]} |\n"
    out << "| Samples | #{samples["length"]} |\n"
    out << "| Weight Type | #{samples["weightType"]} |\n"
    out << "| Total Weight | #{samples["weight"].sum} |\n"

    duration = compute_duration(thread)
    out << "| Duration | #{format("%.2f", duration)}s |\n" if duration

    out << "\n"

    # Walk stacks to compute self and total weight per function
    self_weights = Hash.new(0)
    total_weights = Hash.new(0)
    func_info = {} # func_key => {name:, file:, line:}

    samples["length"].times do |i|
      stack_idx = samples["stack"][i]
      weight = samples["weight"][i]

      # Self time: just the leaf frame
      frame_idx = stack_table["frame"][stack_idx]
      func_idx = frame_table["func"][frame_idx]
      key = func_key(func_idx, func_table, strings)
      self_weights[key] += weight
      func_info[key] ||= func_details(func_idx, frame_idx, frame_table, func_table, strings)

      # Total time: walk up the stack, count each function once
      seen = {}
      cur = stack_idx
      while cur
        fi = stack_table["frame"][cur]
        fui = frame_table["func"][fi]
        k = func_key(fui, func_table, strings)
        unless seen[k]
          seen[k] = true
          total_weights[k] += weight
          func_info[k] ||= func_details(fui, fi, frame_table, func_table, strings)
        end
        cur = stack_table["prefix"][cur]
      end
    end

    total_weight = samples["weight"].sum
    return out << "_No samples collected._\n\n" if total_weight == 0

    out << build_functions_table(self_weights, total_weights, total_weight, func_info)
    out << build_category_breakdown(samples, stack_table, total_weight)
    out << build_timeline(thread)
    out << build_call_tree(samples, stack_table, frame_table, func_table, strings, total_weight)
    out
  end

  def build_functions_table(self_weights, total_weights, total_weight, func_info, max_rows: 20)
    out = +"### Top Functions\n\n"
    sorted = self_weights.sort_by { |_, w| -w }.first(max_rows)
    return out << "_No data._\n\n" if sorted.empty?

    out << "| Self % | Total % | Function | Location |\n"
    out << "|-------:|--------:|----------|----------|\n"

    sorted.each do |key, self_w|
      info = func_info[key]
      self_pct = format("%.1f", 100.0 * self_w / total_weight)
      total_pct = format("%.1f", 100.0 * total_weights[key] / total_weight)
      location = info[:file] ? "#{info[:file]}:#{info[:line]}" : ""
      out << "| #{self_pct}% | #{total_pct}% | `#{info[:name]}` | #{location} |\n"
    end

    out << "\n"
  end

  def build_category_breakdown(samples, stack_table, total_weight)
    out = +"### Categories\n\n"
    cat_weights = Hash.new(0)

    samples["length"].times do |i|
      stack_idx = samples["stack"][i]
      weight = samples["weight"][i]
      cat_idx = stack_table["category"][stack_idx]
      cat_name = @categories[cat_idx]["name"] rescue "Unknown(#{cat_idx})"
      cat_weights[cat_name] += weight
    end

    return out << "_No data._\n\n" if total_weight == 0

    out << "| Category | % | Weight |\n"
    out << "|----------|--:|-------:|\n"

    cat_weights.sort_by { |_, w| -w }.each do |name, weight|
      pct = format("%.1f", 100.0 * weight / total_weight)
      out << "| #{name} | #{pct}% | #{weight} |\n"
    end

    out << "\n"
  end

  def build_timeline(thread)
    markers = thread["markers"]
    return "" if markers["length"] == 0

    state_names = {
      "THREAD_RUNNING" => "Running",
      "THREAD_STALLED" => "Stalled",
      "THREAD_SUSPENDED" => "Suspended",
      "Thread Running" => "Running",
      "Thread Stalled" => "Stalled",
      "Thread Suspended" => "Suspended"
    }

    strings = thread["stringArray"]
    states = []
    markers["length"].times do |i|
      name = strings[markers["name"][i]]
      datum = markers["data"][i]
      resolved_name = state_names[name] || (datum && state_names[datum["type"]])
      next unless resolved_name
      start_time = markers["startTime"][i]
      end_time = markers["endTime"][i]
      duration = end_time - start_time
      states << { state: resolved_name, start: start_time, end: end_time, duration: duration }
    end

    return "" if states.empty?

    total_duration = states.sum { |s| s[:duration] }
    return "" if total_duration == 0

    by_state = states.group_by { |s| s[:state] }
    state_totals = by_state.transform_values { |ss| ss.sum { |s| s[:duration] } }

    out = +"### GVL State\n\n"
    out << "| State | % | Duration |\n"
    out << "|-------|--:|---------:|\n"

    state_totals.sort_by { |_, d| -d }.each do |state, dur|
      pct = format("%.1f", 100.0 * dur / total_duration)
      out << "| #{state} | #{pct}% | #{format("%.1f", dur)}ms |\n"
    end

    out << "\n"
  end

  def build_call_tree(samples, stack_table, frame_table, func_table, strings, total_weight, max_depth: 30)
    out = +"### Call Tree\n\n"

    # Build a tree from all samples
    root = { name: "(root)", children: {}, self_weight: 0, total_weight: 0 }

    samples["length"].times do |i|
      stack_idx = samples["stack"][i]
      weight = samples["weight"][i]

      # Unwind the stack into an array (bottom to top)
      frames = []
      cur = stack_idx
      while cur
        fi = stack_table["frame"][cur]
        fui = frame_table["func"][fi]
        name_idx = func_table["name"][fui]
        name = strings[name_idx]
        frames << name
        cur = stack_table["prefix"][cur]
      end

      # Walk from root (bottom of stack) to leaf
      node = root
      frames.reverse_each do |name|
        node[:total_weight] += weight
        node[:children][name] ||= { name: name, children: {}, self_weight: 0, total_weight: 0 }
        node = node[:children][name]
      end
      node[:total_weight] += weight
      node[:self_weight] += weight
    end

    out << "```\n"
    # Render tree recursively
    render_tree(out, root[:children], total_weight, "", max_depth, 0)
    out << "```\n\n"
  end

  def render_tree(out, children, total_weight, prefix, max_depth, depth)
    return if depth >= max_depth
    sorted = children.values.sort_by { |n| -n[:total_weight] }
    sorted.each_with_index do |node, i|
      is_last = (i == sorted.size - 1)
      connector = is_last ? "\u2514\u2500 " : "\u251C\u2500 "
      total_pct = format("%.1f", 100.0 * node[:total_weight] / total_weight)
      self_pct = node[:self_weight] > 0 ? " (self: #{format("%.1f", 100.0 * node[:self_weight] / total_weight)}%)" : ""
      out << "#{prefix}#{connector}#{total_pct}% #{node[:name]}#{self_pct}\n"

      next_prefix = prefix + (is_last ? "   " : "\u2502  ")
      render_tree(out, node[:children], total_weight, next_prefix, max_depth, depth + 1)
    end
  end

  def compute_duration(thread)
    samples = thread["samples"]
    return nil if samples["length"] == 0
    times = samples["time"]
    return nil if times.empty?

    start_time = thread["registerTime"] || times.first
    end_time = thread.fetch("unregisterTime", nil) || times.last
    (end_time - start_time) / 1000.0
  end

  def func_key(func_idx, func_table, strings)
    name_idx = func_table["name"][func_idx]
    file_idx = func_table["fileName"][func_idx]
    line = func_table["lineNumber"][func_idx]
    "#{name_idx}:#{file_idx}:#{line}"
  end

  def func_details(func_idx, frame_idx, frame_table, func_table, strings)
    name_idx = func_table["name"][func_idx]
    file_idx = func_table["fileName"][func_idx]
    line = frame_table["line"][frame_idx] || func_table["lineNumber"][func_idx]
    {
      name: strings[name_idx],
      file: file_idx ? strings[file_idx] : nil,
      line: line
    }
  end
end

if ARGV.empty?
  $stderr.puts "Usage: #{$0} <profile.json[.gz]>"
  exit 1
end

reader = FirefoxProfileReader.new(ARGV[0])
puts reader.to_markdown
