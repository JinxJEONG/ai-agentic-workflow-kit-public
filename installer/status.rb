#!/usr/bin/env ruby
# frozen_string_literal: true

require "rbconfig"

exec RbConfig.ruby, File.expand_path("../engine/install/status.rb", __dir__), *ARGV
