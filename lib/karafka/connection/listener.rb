# frozen_string_literal: true

module Karafka
  module Connection
    # A single listener that listens to incoming messages from a single subscription group.
    # It polls the messages and then enqueues jobs. It also takes care of potential recovery from
    # critical errors by restarting everything in a safe manner.
    #
    # This is the heart of the consumption process.
    class Listener
      include Helpers::Async

      # Can be useful for logging
      # @return [String] id of this listener
      attr_reader :id

      # @param consumer_group_coordinator [Karafka::Connection::ConsumerGroupCoordinator]
      # @param subscription_group [Karafka::Routing::SubscriptionGroup]
      # @param jobs_queue [Karafka::Processing::JobsQueue] queue where we should push work
      # @return [Karafka::Connection::Listener] listener instance
      def initialize(consumer_group_coordinator, subscription_group, jobs_queue)
        proc_config = ::Karafka::App.config.internal.processing

        @id = SecureRandom.hex(6)
        @consumer_group_coordinator = consumer_group_coordinator
        @subscription_group = subscription_group
        @jobs_queue = jobs_queue
        @coordinators = Processing::CoordinatorsBuffer.new(subscription_group.topics)
        @client = Client.new(@subscription_group)
        @executors = Processing::ExecutorsBuffer.new(@client, subscription_group)
        @jobs_builder = proc_config.jobs_builder
        @partitioner = proc_config.partitioner_class.new(subscription_group)
        # We reference scheduler here as it is much faster than fetching this each time
        @scheduler = proc_config.scheduler
        # We keep one buffer for messages to preserve memory and not allocate extra objects
        # We can do this that way because we always first schedule jobs using messages before we
        # fetch another batch.
        @messages_buffer = MessagesBuffer.new(subscription_group)
        @mutex = Mutex.new
        @stopped = false
      end

      # Runs the main listener fetch loop.
      #
      # @note Prefetch callbacks can be used to seek offset or do other things before we actually
      #   start consuming data
      def call
        Karafka.monitor.instrument(
          'connection.listener.before_fetch_loop',
          caller: self,
          client: @client,
          subscription_group: @subscription_group
        )

        fetch_loop
      end

      # Stops the jobs queue, triggers shutdown on all the executors (sync), commits offsets and
      # stops kafka client.
      #
      # @note This method is not private despite being part of the fetch loop because in case of
      #   a forceful shutdown, it may be invoked from a separate thread
      #
      # @note We wrap it with a mutex exactly because of the above case of forceful shutdown
      def shutdown
        return if @stopped

        @mutex.synchronize do
          @stopped = true
          @executors.clear
          @coordinators.reset
          @client.stop
        end
      end

      private

      # Fetches the data and adds it to the jobs queue.
      #
      # @note We catch all the errors here, so they don't affect other listeners (or this one)
      #   so we will be able to listen and consume other incoming messages.
      #   Since it is run inside Karafka::Connection::Runner thread - catching all the exceptions
      #   won't crash the whole process. Here we mostly focus on catching the exceptions related to
      #   Kafka connections / Internet connection issues / Etc. Business logic problems should not
      #   propagate this far.
      def fetch_loop
        # Run the main loop as long as we are not stopping or moving into quiet mode
        until Karafka::App.done?
          Karafka.monitor.instrument(
            'connection.listener.fetch_loop',
            caller: self,
            client: @client,
            subscription_group: @subscription_group
          )

          resume_paused_partitions

          Karafka.monitor.instrument(
            'connection.listener.fetch_loop.received',
            caller: self,
            client: @client,
            subscription_group: @subscription_group,
            messages_buffer: @messages_buffer
          ) do
            # We need to fetch data before we revoke lost partitions details as during the polling
            # the callbacks for tracking lost partitions are triggered. Otherwise we would be
            # always one batch behind.
            poll_and_remap_messages
          end

          # If there were revoked partitions, we need to wait on their jobs to finish before
          # distributing consuming jobs as upon revoking, we might get assigned to the same
          # partitions, thus getting their jobs. The revoking jobs need to finish before
          # appropriate consumers are taken down and re-created
          build_and_schedule_revoke_lost_partitions_jobs

          # We wait only on jobs from our subscription group. Other groups are independent.
          # This will block on revoked jobs until they are finished. Those are not meant to last
          # long and should not have any bigger impact on the system. Doing this in a blocking way
          # simplifies the overall design and prevents from race conditions
          wait

          build_and_schedule_consumption_jobs

          wait
        end

        # If we are stopping we will no longer schedule any regular jobs despite polling.
        # We need to keep polling not to exceed the `max.poll.interval` for long-running
        # non-blocking jobs and we need to allow them to finish. We however do not want to
        # enqueue any new jobs. It's worth keeping in mind that it is the end user responsibility
        # to detect shutdown in their long-running logic or else Karafka will force shutdown
        # after a while.
        #
        # We do not care about resuming any partitions or lost jobs as we do not plan to do
        # anything with them as we're in the shutdown phase.
        #
        # What we do care however is the ability to still run revocation jobs in case anything
        # would change in the cluster. We still want to notify the long-running jobs about changes
        # that occurred in the cluster.
        wait_pinging(
          wait_until: -> { @jobs_queue.empty?(@subscription_group.id) },
          after_ping: -> { build_and_schedule_revoke_lost_partitions_jobs }
        )

        # We do not want to schedule the shutdown jobs prior to finishing all the jobs
        # (including non-blocking) as there might be a long-running job with a shutdown and then
        # we would run two jobs in parallel for the same executor and consumer. We do not want that
        # as it could create a race-condition.
        build_and_schedule_shutdown_jobs

        # Wait until all the shutdown jobs are done
        wait_pinging(wait_until: -> { @jobs_queue.empty?(@subscription_group.id) })

        # Once all the work is done, we need to decrement counter of active subscription groups
        # within this consumer group
        @consumer_group_coordinator.finish_work(id)

        # Wait if we're in the process of finishing started work or finished all the work and
        # just sitting and being quiet
        wait_pinging(wait_until: -> { !(Karafka::App.quieting? || Karafka::App.quiet?) })

        # We need to wait until all the work in the whole consumer group (local to the process)
        # is done. Otherwise we may end up with locks and `Timed out LeaveGroupRequest in flight`
        # warning notifications.
        wait_pinging(wait_until: -> { @consumer_group_coordinator.shutdown? })

        # This extra ping will make sure we've refreshed the rebalance state after other instances
        # potentially shutdown. This will prevent us from closing with a dangling callback
        @client.ping

        shutdown

        # This is on purpose - see the notes for this method
        # rubocop:disable Lint/RescueException
      rescue Exception => e
        # rubocop:enable Lint/RescueException
        Karafka.monitor.instrument(
          'error.occurred',
          caller: self,
          error: e,
          type: 'connection.listener.fetch_loop.error'
        )

        restart

        sleep(1) && retry
      ensure
        @consumer_group_coordinator.unlock
      end

      # Resumes processing of partitions that were paused due to an error.
      def resume_paused_partitions
        @coordinators.resume do |topic, partition|
          @client.resume(topic.name, partition)
        end
      end

      # Enqueues revoking jobs for partitions that were taken away from the running process.
      def build_and_schedule_revoke_lost_partitions_jobs
        revoked_partitions = @client.rebalance_manager.revoked_partitions

        # Stop early to save on some execution and array allocation
        return if revoked_partitions.empty?

        jobs = []

        revoked_partitions.each do |topic, partitions|
          partitions.each do |partition|
            @coordinators.revoke(topic, partition)

            # There may be a case where we have lost partition of which data we have never
            # processed (if it was assigned and revoked really fast), thus we may not have it
            # here. In cases like this, we do not run a revocation job
            @executors.find_all(topic, partition).each do |executor|
              job = @jobs_builder.revoked(executor)
              job.before_enqueue
              jobs << job
            end

            # We need to remove all the executors of a given topic partition that we have lost, so
            # next time we pick up it's work, new executors kick in. This may be needed especially
            # for LRJ where we could end up with a race condition
            # This revocation needs to happen after the jobs are scheduled, otherwise they would
            # be scheduled with new executors instead of old
            @executors.revoke(topic, partition)
          end
        end

        @scheduler.schedule_revocation(@jobs_queue, jobs)
      end

      # Enqueues the shutdown jobs for all the executors that exist in our subscription group
      def build_and_schedule_shutdown_jobs
        jobs = []

        @executors.each do |executor|
          job = @jobs_builder.shutdown(executor)
          job.before_enqueue
          jobs << job
        end

        @scheduler.schedule_shutdown(@jobs_queue, jobs)
      end

      # Polls messages within the time and amount boundaries defined in the settings and then
      # builds karafka messages based on the raw rdkafka messages buffer returned by the
      # `#batch_poll` method.
      #
      # @note There are two buffers, one for raw messages and one for "built" karafka messages
      def poll_and_remap_messages
        @messages_buffer.remap(
          @client.batch_poll
        )
      end

      # Takes the messages per topic partition and enqueues processing jobs in threads using
      # given scheduler.
      def build_and_schedule_consumption_jobs
        return if @messages_buffer.empty?

        jobs = []

        @messages_buffer.each do |topic, partition, messages|
          coordinator = @coordinators.find_or_create(topic, partition)
          # Start work coordination for this topic partition
          coordinator.start(messages)

          # We do not increment coordinator for idle job because it's not a user related one
          # and it will not go through a standard lifecycle. Same applies to revoked and shutdown
          if messages.empty?
            executor = @executors.find_or_create(topic, partition, 0, coordinator)
            jobs << @jobs_builder.idle(executor)
          else
            @partitioner.call(topic, messages, coordinator) do |group_id, partition_messages|
              executor = @executors.find_or_create(topic, partition, group_id, coordinator)
              coordinator.increment
              jobs << @jobs_builder.consume(executor, partition_messages)
            end
          end
        end

        jobs.each(&:before_enqueue)

        @scheduler.schedule_consumption(@jobs_queue, jobs)
      end

      # Waits for all the jobs from a given subscription group to finish before moving forward
      def wait
        @jobs_queue.wait(@subscription_group.id)
      end

      # Waits without blocking the polling
      #
      # This should be used only when we no longer plan to use any incoming messages data and we
      # can safely discard it. We can however use the rebalance information if needed.
      #
      # @param wait_until [Proc] until this evaluates to true, we will poll data
      # @param after_ping [Proc] code that we want to run after each ping (if any)
      #
      # @note Performance of this is not relevant (in regards to blocks) because it is used only
      #   on shutdown and quiet, hence not in the running mode
      def wait_pinging(wait_until:, after_ping: -> {})
        until wait_until.call
          @client.ping
          after_ping.call
          sleep(0.2)
        end
      end

      # We can stop client without a problem, as it will reinitialize itself when running the
      # `#fetch_loop` again. We just need to remember to also reset the runner as it is a long
      # running one, so with a new connection to Kafka, we need to initialize the state of the
      # runner and underlying consumers once again.
      def restart
        # If there was any problem with processing, before we reset things we need to make sure,
        # there are no jobs in the queue. Otherwise it could lead to leakage in between client
        # resetting.
        @jobs_queue.wait(@subscription_group.id)
        @jobs_queue.clear(@subscription_group.id)
        @client.reset
        @coordinators.reset
        @executors = Processing::ExecutorsBuffer.new(@client, @subscription_group)
      end
    end
  end
end
