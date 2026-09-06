#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
AQUA = ENV.fetch("AQUA", "aqua")
CANARY = "A" "K" "I" "A" + %w[Z0 Y1 X2 W3 V4 U5 T6 S7].join


def run!(*command, chdir:)
  stdout, stderr, status = Open3.capture3(*command, chdir: chdir)
  return [stdout, stderr] if status.success?

  abort("command failed: #{command.join(" ")} (exit #{status.exitstatus})")
end

before, = Open3.capture3("git", "status", "--porcelain", chdir: ROOT)
run!(AQUA, "exec", "--", "pre-commit", "run", "--all-files", chdir: ROOT)

Dir.mktmpdir("pre-commit-gitleaks-") do |dir|
  run!("git", "init", "-q", chdir: dir)
  run!("git", "config", "user.email", "test@example.invalid", chdir: dir)
  run!("git", "config", "user.name", "Pre-commit Test", chdir: dir)
  FileUtils.cp(File.join(ROOT, ".pre-commit-config.yaml"), dir)
  FileUtils.cp(File.join(ROOT, "aqua.yaml"), dir)
  FileUtils.mkdir_p(File.join(dir, "scripts"))
  FileUtils.cp(File.join(ROOT, "scripts", "pre-commit-gitleaks"), File.join(dir, "scripts", "pre-commit-gitleaks"))
  File.write(File.join(dir, "fixture.txt"), "clean fixture\n")
  run!("git", "add", ".", chdir: dir)
  run!("git", "commit", "-qm", "initial fixture", chdir: dir)

  File.write(File.join(dir, "fixture.txt"), "clean staged update\n")
  run!("git", "add", "fixture.txt", chdir: dir)
  stdout, stderr, status = Dir.chdir(dir) do
    Open3.capture3({"PWD" => dir}, AQUA, "exec", "--", "pre-commit", "run", "--all-files")
  end
  abort("clean staged fixture was rejected") unless status.success?

  File.write(File.join(dir, "fixture.txt"), "synthetic_access_key=#{CANARY}\n")
  run!("git", "add", "fixture.txt", chdir: dir)
  stdout, stderr, status = Dir.chdir(dir) do
    Open3.capture3({"PWD" => dir}, AQUA, "exec", "--", "pre-commit", "run", "--all-files")
  end

  abort("staged synthetic canary was accepted") if status.success?
  abort("synthetic canary was disclosed") if (stdout + stderr).include?(CANARY)
  _, _, staged_status = Open3.capture3("git", "diff", "--cached", "--quiet", chdir: dir)
  abort("synthetic fixture was not staged") if staged_status.success?
end

after, = Open3.capture3("git", "status", "--porcelain", chdir: ROOT)
abort("repository status changed during regression test") unless before == after
puts "pre-commit regression checks passed"
