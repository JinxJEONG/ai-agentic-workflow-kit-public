#!/usr/bin/env ruby
# frozen_string_literal: true

# Compatibility CLI. New code lives in the canonical Phase 2 path.
require_relative "../engine/release/release_manifest"

exit WorkflowKit::Release::ReleaseManifest.run_cli(ARGV) if $PROGRAM_NAME == __FILE__
