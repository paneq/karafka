# frozen_string_literal: true

module Karafka
  # Namespace that encapsulates all the logic related to processing data.
  module Processing
    # Executors:
    # - run consumers code (for `#call`) or run given preparation / teardown operations when needed
    #   from separate threads.
    # - they re-create consumer instances in case of partitions that were revoked and assigned
    #   back.
    #
    # @note Executors are not removed after partition is revoked. They are not that big and will
    #   be re-used in case of a re-claim
    class Executor
      extend Forwardable

      def_delegators :@coordinator, :topic, :partition

      # @return [String] unique id that we use to ensure, that we use for state tracking
      attr_reader :id

      # @return [String] subscription group id to which a given executor belongs
      attr_reader :group_id

      # @return [Karafka::Messages::Messages] messages batch
      attr_reader :messages

      # @return [Karafka::Processing::Coordinator] coordinator for this executor
      attr_reader :coordinator

      # @param group_id [String] id of the subscription group to which the executor belongs
      # @param client [Karafka::Connection::Client] kafka client
      # @param coordinator [Karafka::Processing::Coordinator]
      def initialize(group_id, client, coordinator)
        @id = SecureRandom.hex(6)
        @group_id = group_id
        @client = client
        @coordinator = coordinator
      end

      # Allows us to prepare the consumer in the listener thread prior to the job being send to
      # the queue. It also allows to run some code that is time sensitive and cannot wait in the
      # queue as it could cause starvation.
      #
      # @param messages [Array<Karafka::Messages::Message>]
      def before_enqueue(messages)
        # Recreate consumer with each batch if persistence is not enabled
        # We reload the consumers with each batch instead of relying on some external signals
        # when needed for consistency. That way devs may have it on or off and not in this
        # middle state, where re-creation of a consumer instance would occur only sometimes
        @consumer = nil unless topic.consumer_persistence

        # First we build messages batch...
        consumer.messages = Messages::Builders::Messages.call(
          messages,
          topic,
          partition,
          # the moment we've received the batch or actually the moment we've enqueued it,
          # but good enough
          Time.now
        )

        consumer.on_before_enqueue
      end

      # Runs setup and warm-up code in the worker prior to running the consumption
      def before_consume
        consumer.on_before_consume
      end

      # Runs consumer data processing against given batch and handles failures and errors.
      def consume
        # We run the consumer client logic...
        consumer.on_consume
      end

      # Runs consumer after consumption code
      def after_consume
        consumer.on_after_consume
      end

      # Runs consumer idle operations
      # This may include house-keeping or other state management changes that can occur but that
      # not mean there are any new messages available for the end user to process
      def idle
        # Initializes the messages set in case idle operation would happen before any processing
        # This prevents us from having no messages object at all as the messages object and
        # its metadata may be used for statistics
        consumer.messages ||= Messages::Builders::Messages.call(
          [],
          topic,
          partition,
          Time.now
        )

        consumer.on_idle
      end

      # Runs the controller `#revoked` method that should be triggered when a given consumer is
      # no longer needed due to partitions reassignment.
      #
      # @note Clearing the consumer will ensure, that if we get the partition back, it will be
      #   handled with a consumer with a clean state.
      #
      # @note We run it only when consumer was present, because presence indicates, that at least
      #   a single message has been consumed.
      #
      # @note We do not reset the consumer but we indicate need for recreation instead, because
      #   after the revocation, there still may be `#after_consume` running that needs a given
      #   consumer instance.
      def revoked
        consumer.on_revoked if @consumer
      end

      # Runs the controller `#shutdown` method that should be triggered when a given consumer is
      # no longer needed as we're closing the process.
      #
      # @note While we do not need to clear the consumer here, it's a good habit to clean after
      #   work is done.
      def shutdown
        # There is a case, where the consumer no longer exists because it was revoked, in case like
        # that we do not build a new instance and shutdown should not be triggered.
        consumer.on_shutdown if @consumer
      end

      private

      # @return [Object] cached consumer instance
      def consumer
        @consumer ||= begin
          topic = @coordinator.topic

          strategy = ::Karafka::App.config.internal.processing.strategy_selector.find(topic)

          consumer = topic.consumer_class.new
          # We use singleton class as the same consumer class may be used to process different
          # topics with different settings
          consumer.singleton_class.include(strategy)
          consumer.client = @client
          consumer.producer = ::Karafka::App.producer
          consumer.coordinator = @coordinator

          consumer
        end
      end
    end
  end
end
