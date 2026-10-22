#!/usr/bin/env ruby

require "rbconfig"

apply = ARGV.delete("--apply")
args = ["--replace-kit-owned"]
args << "--apply" if apply
exec RbConfig.ruby, File.join(__dir__, "upgrade.rb"), *args, *ARGV
