# frozen_string_literal: true

module Karafka
  # Namespace for Kafka connection related logic
  module Connection
    # An abstraction layer on top of the rdkafka consumer.
    #
    # It is threadsafe and provides some security measures so we won't end up operating on a
    # closed consumer instance as it causes Ruby VM process to crash.
    class Client
      attr_reader :rebalance_manager

      # @return [String] underlying consumer name
      # @note Consumer name may change in case we regenerate it
      attr_reader :name

      # @return [String] id of the client
      attr_reader :id

      # How many times should we retry polling in case of a failure
      MAX_POLL_RETRIES = 20

      # 1 minute of max wait for the first rebalance before a forceful attempt
      # This applies only to a case when a short-lived Karafka instance with a client would be
      # closed before first rebalance. Mitigates a librdkafka bug.
      COOPERATIVE_STICKY_MAX_WAIT = 60_000

      # We want to make sure we never close several clients in the same moment to prevent
      # potential race conditions and other issues
      SHUTDOWN_MUTEX = Mutex.new

      private_constant :MAX_POLL_RETRIES, :SHUTDOWN_MUTEX, :COOPERATIVE_STICKY_MAX_WAIT

      # Creates a new consumer instance.
      #
      # @param subscription_group [Karafka::Routing::SubscriptionGroup] subscription group
      #   with all the configuration details needed for us to create a client
      # @return [Karafka::Connection::Client]
      def initialize(subscription_group)
        @id = SecureRandom.hex(6)
        # Name is set when we build consumer
        @name = ''
        @closed = false
        @subscription_group = subscription_group
        @buffer = RawMessagesBuffer.new
        @rebalance_manager = RebalanceManager.new
        @kafka = build_consumer
        # There are few operations that can happen in parallel from the listener threads as well
        # as from the workers. They are not fully thread-safe because they may be composed out of
        # few calls to Kafka or out of few internal state changes. That is why we mutex them.
        # It mostly revolves around pausing and resuming.
        @mutex = Mutex.new
        # We need to keep track of what we have paused for resuming
        # In case we loose partition, we still need to resume it, otherwise it won't be fetched
        # again if we get reassigned to it later on. We need to keep them as after revocation we
        # no longer may be able to fetch them from Kafka. We could build them but it is easier
        # to just keep them here and use if needed when cannot be obtained
        @paused_tpls = Hash.new { |h, k| h[k] = {} }
      end

      # Fetches messages within boundaries defined by the settings (time, size, topics, etc).
      #
      # @return [Karafka::Connection::MessagesBuffer] messages buffer that holds messages per topic
      #   partition
      # @note This method should not be executed from many threads at the same time
      def batch_poll
        time_poll = TimeTrackers::Poll.new(@subscription_group.max_wait_time)

        @buffer.clear
        @rebalance_manager.clear

        loop do
          time_poll.start

          # Don't fetch more messages if we do not have any time left
          break if time_poll.exceeded?
          # Don't fetch more messages if we've fetched max as we've wanted
          break if @buffer.size >= @subscription_group.max_messages

          # Fetch message within our time boundaries
          message = poll(time_poll.remaining)

          # Put a message to the buffer if there is one
          @buffer << message if message

          # Upon polling rebalance manager might have been updated.
          # If partition revocation happens, we need to remove messages from revoked partitions
          # as well as ensure we do not have duplicated due to the offset reset for partitions
          # that we got assigned
          # We also do early break, so the information about rebalance is used as soon as possible
          if @rebalance_manager.changed?
            remove_revoked_and_duplicated_messages
            break
          end

          # Track time spent on all of the processing and polling
          time_poll.checkpoint

          # Finally once we've (potentially) removed revoked, etc, if no messages were returned
          # we can break.
          # Worth keeping in mind, that the rebalance manager might have been updated despite no
          # messages being returned during a poll
          break unless message
        end

        @buffer
      end

      # Stores offset for a given partition of a given topic based on the provided message.
      #
      # @param message [Karafka::Messages::Message]
      def store_offset(message)
        internal_store_offset(message)
      end

      # @return [Boolean] true if our current assignment has been lost involuntarily.
      def assignment_lost?
        @kafka.assignment_lost?
      end

      # Commits the offset on a current consumer in a non-blocking or blocking way.
      #
      # @param async [Boolean] should the commit happen async or sync (async by default)
      # @return [Boolean] did committing was successful. It may be not, when we no longer own
      #   given partition.
      #
      # @note This will commit all the offsets for the whole consumer. In order to achieve
      #   granular control over where the offset should be for particular topic partitions, the
      #   store_offset should be used to only store new offset when we want them to be flushed
      #
      # @note This method for async may return `true` despite involuntary partition revocation as
      #   it does **not** resolve to `lost_assignment?`. It returns only the commit state operation
      #   result.
      def commit_offsets(async: true)
        internal_commit_offsets(async: async)
      end

      # Commits offset in a synchronous way.
      #
      # @see `#commit_offset` for more details
      def commit_offsets!
        commit_offsets(async: false)
      end

      # Seek to a particular message. The next poll on the topic/partition will return the
      # message at the given offset.
      #
      # @param message [Messages::Message, Messages::Seek] message to which we want to seek to.
      #   It can have the time based offset.
      # @note Please note, that if you are seeking to a time offset, getting the offset is blocking
      def seek(message)
        @mutex.synchronize { internal_seek(message) }
      end

      # Pauses given partition and moves back to last successful offset processed.
      #
      # @param topic [String] topic name
      # @param partition [Integer] partition
      # @param offset [Integer] offset of the message on which we want to pause (this message will
      #   be reprocessed after getting back to processing)
      # @note This will pause indefinitely and requires manual `#resume`
      def pause(topic, partition, offset)
        @mutex.synchronize do
          # Do not pause if the client got closed, would not change anything
          return if @closed

          pause_msg = Messages::Seek.new(topic, partition, offset)

          internal_commit_offsets(async: true)

          # Here we do not use our cached tpls because we should not try to pause something we do
          # not own anymore.
          tpl = topic_partition_list(topic, partition)

          return unless tpl

          Karafka.monitor.instrument(
            'client.pause',
            caller: self,
            subscription_group: @subscription_group,
            topic: topic,
            partition: partition,
            offset: offset
          )

          @paused_tpls[topic][partition] = tpl

          @kafka.pause(tpl)
          internal_seek(pause_msg)
        end
      end

      # Resumes processing of a give topic partition after it was paused.
      #
      # @param topic [String] topic name
      # @param partition [Integer] partition
      def resume(topic, partition)
        @mutex.synchronize do
          return if @closed

          # We now commit offsets on rebalances, thus we can do it async just to make sure
          internal_commit_offsets(async: true)

          # If we were not able, let's try to reuse the one we have (if we have)
          tpl = topic_partition_list(topic, partition) || @paused_tpls[topic][partition]

          return unless tpl

          # If we did not have it, it means we never paused this partition, thus no resume should
          # happen in the first place
          return unless @paused_tpls[topic].delete(partition)

          Karafka.monitor.instrument(
            'client.resume',
            caller: self,
            subscription_group: @subscription_group,
            topic: topic,
            partition: partition
          )

          @kafka.resume(tpl)
        end
      end

      # Gracefully stops topic consumption.
      #
      # @note Stopping running consumers without a really important reason is not recommended
      #   as until all the consumers are stopped, the server will keep running serving only
      #   part of the messages
      def stop
        # This ensures, that we do not stop the underlying client until it passes the first
        # rebalance for cooperative-sticky. Otherwise librdkafka may crash
        #
        # We set a timeout just in case the rebalance would never happen or would last for an
        # extensive time period.
        #
        # @see https://github.com/confluentinc/librdkafka/issues/4312
        if @subscription_group.kafka[:'partition.assignment.strategy'] == 'cooperative-sticky'
          (COOPERATIVE_STICKY_MAX_WAIT / 100).times do
            # If we're past the first rebalance, no need to wait
            break if @rebalance_manager.active?

            sleep(0.1)
          end
        end

        close
      end

      # Marks given message as consumed.
      #
      # @param [Karafka::Messages::Message] message that we want to mark as processed
      # @return [Boolean] true if successful. False if we no longer own given partition
      # @note This method won't trigger automatic offsets commits, rather relying on the offset
      #   check-pointing trigger that happens with each batch processed. It will however check the
      #   `librdkafka` assignment ownership to increase accuracy for involuntary revocations.
      def mark_as_consumed(message)
        store_offset(message) && !assignment_lost?
      end

      # Marks a given message as consumed and commits the offsets in a blocking way.
      #
      # @param [Karafka::Messages::Message] message that we want to mark as processed
      # @return [Boolean] true if successful. False if we no longer own given partition
      def mark_as_consumed!(message)
        return false unless mark_as_consumed(message)

        commit_offsets!
      end

      # Closes and resets the client completely.
      def reset
        close

        @closed = false
        @paused_tpls.clear
        @kafka = build_consumer
      end

      # Runs a single poll ignoring all the potential errors
      # This is used as a keep-alive in the shutdown stage and any errors that happen here are
      # irrelevant from the shutdown process perspective
      #
      # This is used only to trigger rebalance callbacks
      def ping
        poll(100)
      rescue Rdkafka::RdkafkaError
        nil
      end

      private

      # When we cannot store an offset, it means we no longer own the partition
      #
      # Non thread-safe offset storing method
      # @param message [Karafka::Messages::Message]
      # @return [Boolean] true if we could store the offset (if we still own the partition)
      def internal_store_offset(message)
        @kafka.store_offset(message)
        true
      rescue Rdkafka::RdkafkaError => e
        return false if e.code == :assignment_lost
        return false if e.code == :state

        raise e
      end

      # Non thread-safe message committing method
      # @param async [Boolean] should the commit happen async or sync (async by default)
      # @return [Boolean] true if offset commit worked, false if we've lost the assignment
      # @note We do **not** consider `no_offset` as any problem and we allow to commit offsets
      #   even when no stored, because with sync commit, it refreshes the ownership state of the
      #   consumer in a sync way.
      def internal_commit_offsets(async: true)
        @kafka.commit(nil, async)

        true
      rescue Rdkafka::RdkafkaError => e
        case e.code
        when :assignment_lost
          return false
        when :unknown_member_id
          return false
        when :no_offset
          return true
        when :coordinator_load_in_progress
          sleep(1)
          retry
        end

        raise e
      end

      # Non-mutexed seek that should be used only internally. Outside we expose `#seek` that is
      # wrapped with a mutex.
      #
      # @param message [Messages::Message, Messages::Seek] message to which we want to seek to.
      #   It can have the time based offset.
      def internal_seek(message)
        # If the seek message offset is in a time format, we need to find the closest "real"
        # offset matching before we seek
        if message.offset.is_a?(Time)
          tpl = ::Rdkafka::Consumer::TopicPartitionList.new
          tpl.add_topic_and_partitions_with_offsets(
            message.topic,
            message.partition => message.offset
          )

          proxy = Proxy.new(@kafka)

          # Now we can overwrite the seek message offset with our resolved offset and we can
          # then seek to the appropriate message
          # We set the timeout to 2_000 to make sure that remote clusters handle this well
          real_offsets = proxy.offsets_for_times(tpl)
          detected_partition = real_offsets.to_h.dig(message.topic, message.partition)

          # There always needs to be an offset. In case we seek into the future, where there
          # are no offsets yet, we get -1 which indicates the most recent offset
          # We should always detect offset, whether it is 0, -1 or a corresponding
          message.offset = detected_partition&.offset || raise(Errors::InvalidTimeBasedOffsetError)
        end

        @kafka.seek(message)
      end

      # Commits the stored offsets in a sync way and closes the consumer.
      def close
        # Allow only one client to be closed at the same time
        SHUTDOWN_MUTEX.synchronize do
          # Once client is closed, we should not close it again
          # This could only happen in case of a race-condition when forceful shutdown happens
          # and triggers this from a different thread
          return if @closed

          @closed = true

          # Remove callbacks runners that were registered
          ::Karafka::Core::Instrumentation.statistics_callbacks.delete(@subscription_group.id)
          ::Karafka::Core::Instrumentation.error_callbacks.delete(@subscription_group.id)

          @kafka.close
          @buffer.clear
          # @note We do not clear rebalance manager here as we may still have revocation info
          # here that we want to consider valid prior to running another reconnection
        end
      end

      # Unsubscribes from all the subscriptions
      # @note This is a private API to be used only on shutdown
      # @note We do not re-raise since this is supposed to be only used on close and can be safely
      #   ignored. We do however want to instrument on it
      def unsubscribe
        @kafka.unsubscribe
      rescue ::Rdkafka::RdkafkaError => e
        Karafka.monitor.instrument(
          'error.occurred',
          caller: self,
          error: e,
          type: 'connection.client.unsubscribe.error'
        )
      end

      # @param topic [String]
      # @param partition [Integer]
      # @return [Rdkafka::Consumer::TopicPartitionList]
      def topic_partition_list(topic, partition)
        rdkafka_partition = @kafka
                            .assignment
                            .to_h[topic]
                            &.detect { |part| part.partition == partition }

        return unless rdkafka_partition

        Rdkafka::Consumer::TopicPartitionList.new({ topic => [rdkafka_partition] })
      end

      # Performs a single poll operation and handles retries and error
      #
      # @param timeout [Integer] timeout for a single poll
      # @return [Rdkafka::Consumer::Message, nil] fetched message or nil if nothing polled
      def poll(timeout)
        time_poll ||= TimeTrackers::Poll.new(timeout)

        return nil if time_poll.exceeded?

        time_poll.start

        @kafka.poll(timeout)
      rescue ::Rdkafka::RdkafkaError => e
        early_report = false

        retryable = time_poll.attempts <= MAX_POLL_RETRIES && time_poll.retryable?

        # There are retryable issues on which we want to report fast as they are source of
        # problems and can mean some bigger system instabilities
        # Those are mainly network issues and exceeding the max poll interval
        # We want to report early on max poll interval exceeding because it may mean that the
        # underlying processing is taking too much time and it is not LRJ
        case e.code
        when :max_poll_exceeded # -147
          early_report = true
        when :network_exception # 13
          early_report = true
        when :transport # -195
          early_report = true
        # @see
        # https://github.com/confluentinc/confluent-kafka-dotnet/issues/1366#issuecomment-821842990
        # This will be raised each time poll detects a non-existing topic. When auto creation is
        # on, we can safely ignore it
        when :unknown_topic_or_part # 3
          return nil if @subscription_group.kafka[:'allow.auto.create.topics']

          early_report = true

          # No sense in retrying when no topic/partition and we're no longer running
          retryable = false unless Karafka::App.running?
        end

        if early_report || !retryable
          Karafka.monitor.instrument(
            'error.occurred',
            caller: self,
            error: e,
            type: 'connection.client.poll.error'
          )
        end

        raise unless retryable

        # Most of the errors can be safely ignored as librdkafka will recover from them
        # @see https://github.com/edenhill/librdkafka/issues/1987#issuecomment-422008750
        # @see https://github.com/edenhill/librdkafka/wiki/Error-handling

        time_poll.checkpoint
        time_poll.backoff

        # poll may not only return message but also can run callbacks and if they changed,
        # despite the errors we need to delegate to the other app parts
        @rebalance_manager.changed? ? nil : retry
      end

      # Builds a new rdkafka consumer instance based on the subscription group configuration
      # @return [Rdkafka::Consumer]
      def build_consumer
        ::Rdkafka::Config.logger = ::Karafka::App.config.logger
        config = ::Rdkafka::Config.new(@subscription_group.kafka)
        config.consumer_rebalance_listener = @rebalance_manager
        consumer = config.consumer
        @name = consumer.name

        # Register statistics runner for this particular type of callbacks
        ::Karafka::Core::Instrumentation.statistics_callbacks.add(
          @subscription_group.id,
          Instrumentation::Callbacks::Statistics.new(
            @subscription_group.id,
            @subscription_group.consumer_group_id,
            @name
          )
        )

        # Register error tracking callback
        ::Karafka::Core::Instrumentation.error_callbacks.add(
          @subscription_group.id,
          Instrumentation::Callbacks::Error.new(
            @subscription_group.id,
            @subscription_group.consumer_group_id,
            @name
          )
        )

        # Subscription needs to happen after we assigned the rebalance callbacks just in case of
        # a race condition
        consumer.subscribe(*@subscription_group.topics.map(&:name))
        consumer
      end

      # We may have a case where in the middle of data polling, we've lost a partition.
      # In a case like this we should remove all the pre-buffered messages from list partitions as
      # we are no longer responsible in a given process for processing those messages and they
      # should have been picked up by a different process.
      def remove_revoked_and_duplicated_messages
        @rebalance_manager.lost_partitions.each do |topic, partitions|
          partitions.each do |partition|
            @buffer.delete(topic, partition)
          end
        end

        @buffer.uniq!
      end
    end
  end
end
