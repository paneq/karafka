# frozen_string_literal: true

# Karafka should be able to match non-existing topic when it appears later on.

setup_karafka do |config|
  config.patterns.ttl = 1_000
  config.internal.runner.tick = 100
end

class Consumer < Karafka::BaseConsumer
  def consume
    DT[0] = true
  end
end

draw_routes(create_topics: false) do
  pattern(/#{DT.topic}/) do
    consumer Consumer
  end
end

start_karafka_and_wait_until do
  unless @created
    sleep(5)
    produce_many(DT.topic, DT.uuids(1))
    @created = true
  end

  DT.key?(0)
end

# No assertions needed. If works, won't hang.
