#!/usr/bin/env ruby
# frozen_string_literal: true

# Symbolicates a samply profile JSON file using atos (macOS).
#
# Samply records addresses but doesn't resolve them to function names.
# This script reads the profile, finds all unsymbolized hex-address
# function names, resolves them via atos, and writes the updated profile.
#
# Usage: symbolicate.rb <profile.json> [output.json]
#   If output is omitted, overwrites the input file.

require "json"
require "zlib"
require "open3"

module Symbolicate
  module_function

  # Mach-O arm64/x86_64 default base address
  MACHO_BASE = 0x100000000

  def run(input_path, output_path = nil)
    output_path ||= input_path

    json = File.binread(input_path)
    if json.byteslice(0, 2) == "\x1F\x8B".b
      json = Zlib::Inflate.new(Zlib::MAX_WBITS | 16).inflate(json)
    end
    data = JSON.parse(json)

    libs = data["libs"] || []

    data["threads"].each do |thread|
      symbolicate_thread(thread, libs)
    end

    File.write(output_path, JSON.generate(data))
    $stderr.puts "Symbolicated profile written to #{output_path}"
  end

  def symbolicate_thread(thread, libs)
    strings = thread["stringArray"]
    func_table = thread["funcTable"]
    resource_table = thread["resourceTable"]
    return unless func_table && resource_table && strings

    # Build: resource_index -> lib entry
    resource_to_lib = {}
    resource_table["length"].times do |ri|
      lib_idx = resource_table["lib"][ri]
      resource_to_lib[ri] = libs[lib_idx] if lib_idx && libs[lib_idx]
    end

    # Group functions by library path.
    # We only care about names that look like hex addresses (0x...).
    # Key: lib_path, Value: array of [string_index, address_int]
    by_lib = Hash.new { |h, k| h[k] = [] }

    func_table["length"].times do |fi|
      name_si = func_table["name"][fi]
      name = strings[name_si]
      next unless name && name.match?(/\A0x[0-9a-fA-F]+\z/)

      resource_idx = func_table["resource"][fi]
      lib = resource_to_lib[resource_idx]
      next unless lib && lib["path"]

      addr = Integer(name)
      by_lib[lib["path"]] << [name_si, addr]
    end

    by_lib.each do |lib_path, entries|
      resolve_with_atos(lib_path, entries, strings)
    end
  end

  def resolve_with_atos(lib_path, entries, strings)
    return if entries.empty?

    # Deduplicate by address to minimize atos calls
    addr_to_sis = Hash.new { |h, k| h[k] = [] }
    entries.each { |si, addr| addr_to_sis[addr] << si }

    addrs = addr_to_sis.keys
    # atos wants addresses with the load address applied
    hex_addrs = addrs.map { |a| "0x#{(a + MACHO_BASE).to_s(16)}" }

    # atos can handle many addresses at once via stdin
    cmd = ["atos", "-o", lib_path, "-l", "0x0"]
    out, status = Open3.capture2(*cmd, stdin_data: hex_addrs.join("\n"))
    unless status.success?
      $stderr.puts "atos failed for #{lib_path}: #{status}"
      return
    end

    lines = out.lines.map(&:chomp)
    addrs.each_with_index do |addr, i|
      resolved = lines[i]
      next unless resolved
      # atos returns the input hex if it can't resolve
      next if resolved.match?(/\A0x[0-9a-fA-F]+\z/)

      # Format: "function_name (in binary) (file.c:123)"
      # Extract just "function_name (file.c:123)" for readability
      display = format_atos_output(resolved)

      addr_to_sis[addr].each do |si|
        strings[si] = display
      end
    end
  end

  def format_atos_output(line)
    # atos output: "func_name (in binary_name) (source_file:line)"
    # We want: "func_name (source_file:line)" or just "func_name"
    if line =~ /\A(.+?) \(in .+?\) (\(.+\))\z/
      "#{$1} #{$2}"
    elsif line =~ /\A(.+?) \(in .+?\)\z/
      $1
    else
      line
    end
  end
end

if __FILE__ == $0
  if ARGV.empty?
    $stderr.puts "Usage: #{$0} <profile.json[.gz]> [output.json]"
    exit 1
  end
  Symbolicate.run(ARGV[0], ARGV[1])
end
