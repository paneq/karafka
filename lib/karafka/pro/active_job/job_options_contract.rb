# frozen_string_literal: true

# This Karafka component is a Pro component under a commercial license.
# This Karafka component is NOT licensed under LGPL.
#
# All of the commercial components are present in the lib/karafka/pro directory of this
# repository and their usage requires commercial license agreement.
#
# Karafka has also commercial-friendly license, commercial support and commercial components.
#
# By sending a pull request to the pro components, you are agreeing to transfer the copyright of
# your code to Maciej Mensfeld.

module Karafka
  module Pro
    module ActiveJob
      # Contract for validating the options that can be altered with `#karafka_options` per job
      # class that works with Pro features.
      class JobOptionsContract < Contracts::Base
        configure do |config|
          config.error_messages = YAML.safe_load(
            File.read(
              File.join(Karafka.gem_root, 'config', 'locales', 'errors.yml')
            )
          ).fetch('en').fetch('validations').fetch('job_options')
        end

        optional(:partitioner) { |val| val.respond_to?(:call) }
        optional(:partition_key_type) { |val| %i[key partition_key].include?(val) }
        optional(:dispatch_method) do |val|
          %i[
            produce_async
            produce_sync
          ].include?(val)
        end
        optional(:dispatch_many_method) do |val|
          %i[
            produce_many_async
            produce_many_sync
          ].include?(val)
        end
      end
    end
  end
end
