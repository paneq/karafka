# frozen_string_literal: true

RSpec.describe_current do
  subject(:status_manager) { described_class.new }

  let(:status) { :initializing }

  before { status_manager.instance_variable_set(:'@status', status) }

  context 'when we start with a default state' do
    it { expect(status_manager.initialized?).to eq false }
    it { expect(status_manager.running?).to eq false }
    it { expect(status_manager.stopping?).to eq false }
    it { expect(status_manager.stopped?).to eq false }
    it { expect(status_manager.initializing?).to eq true }
    it { expect(status_manager.to_s).to eq 'initializing' }
    it { expect(status_manager.quieting?).to eq false }
    it { expect(status_manager.quiet?).to eq false }
    it { expect(status_manager.terminated?).to eq false }
    it { expect(status_manager.done?).to eq false }
  end

  describe 'running?' do
    context 'when status is not set to running' do
      it { expect(status_manager.running?).to eq false }
    end

    context 'when status is set to running' do
      let(:status) { :running }

      it { expect(status_manager.initialized?).to eq false }
      it { expect(status_manager.to_s).to eq 'running' }
      it { expect(status_manager.running?).to eq true }
      it { expect(status_manager.terminated?).to eq false }
      it { expect(status_manager.quieting?).to eq false }
      it { expect(status_manager.quiet?).to eq false }
      it { expect(status_manager.done?).to eq false }
    end
  end

  describe 'run!' do
    context 'when we set it to run' do
      before { status_manager.run! }

      it { expect(status_manager.running?).to eq true }
      it { expect(status_manager.to_s).to eq 'running' }
      it { expect(status_manager.initializing?).to eq false }
      it { expect(status_manager.initialized?).to eq false }
      it { expect(status_manager.stopping?).to eq false }
      it { expect(status_manager.stopped?).to eq false }
      it { expect(status_manager.terminated?).to eq false }
      it { expect(status_manager.quieting?).to eq false }
      it { expect(status_manager.quiet?).to eq false }
      it { expect(status_manager.done?).to eq false }
    end
  end

  describe 'stopping?' do
    context 'when status is not set to stopping' do
      before do
        status_manager.instance_variable_set(:'@status', rand)
      end

      it { expect(status_manager.initialized?).to eq false }
      it { expect(status_manager.stopping?).to eq false }
      it { expect(status_manager.stopped?).to eq false }
      it { expect(status_manager.terminated?).to eq false }
      it { expect(status_manager.quieting?).to eq false }
      it { expect(status_manager.quiet?).to eq false }
      it { expect(status_manager.done?).to eq false }
    end

    context 'when status is set to stopping' do
      before do
        status_manager.instance_variable_set(:'@status', :stopping)
      end

      it { expect(status_manager.initialized?).to eq false }
      it { expect(status_manager.to_s).to eq 'stopping' }
      it { expect(status_manager.stopping?).to eq true }
      it { expect(status_manager.stopped?).to eq false }
      it { expect(status_manager.terminated?).to eq false }
      it { expect(status_manager.quieting?).to eq false }
      it { expect(status_manager.quiet?).to eq false }
      it { expect(status_manager.done?).to eq true }
    end
  end

  describe 'stop!' do
    context 'when we set it to stop' do
      before do
        status_manager.run!
        status_manager.stop!
      end

      it { expect(status_manager.running?).to eq false }
      it { expect(status_manager.initializing?).to eq false }
      it { expect(status_manager.initialized?).to eq false }
      it { expect(status_manager.stopping?).to eq true }
      it { expect(status_manager.stopped?).to eq false }
      it { expect(status_manager.terminated?).to eq false }
      it { expect(status_manager.quieting?).to eq false }
      it { expect(status_manager.quiet?).to eq false }
      it { expect(status_manager.done?).to eq true }
    end
  end

  describe 'stopped!' do
    context 'when we set it to stopped' do
      before do
        status_manager.run!
        status_manager.stop!
        status_manager.stopped!
      end

      it { expect(status_manager.running?).to eq false }
      it { expect(status_manager.initializing?).to eq false }
      it { expect(status_manager.initialized?).to eq false }
      it { expect(status_manager.stopping?).to eq false }
      it { expect(status_manager.to_s).to eq 'stopped' }
      it { expect(status_manager.stopped?).to eq true }
      it { expect(status_manager.terminated?).to eq false }
      it { expect(status_manager.quieting?).to eq false }
      it { expect(status_manager.quiet?).to eq false }
      it { expect(status_manager.done?).to eq true }
    end
  end

  describe 'initializing?' do
    context 'when status is not set to initializing' do
      it { expect(status_manager.to_s).to eq 'initializing' }
      it { expect(status_manager.initializing?).to eq true }
      it { expect(status_manager.terminated?).to eq false }
      it { expect(status_manager.quieting?).to eq false }
      it { expect(status_manager.quiet?).to eq false }
      it { expect(status_manager.done?).to eq false }
    end

    context 'when status is set to initializing' do
      let(:status) { :initializing }

      it { expect(status_manager.to_s).to eq 'initializing' }
      it { expect(status_manager.initializing?).to eq true }
      it { expect(status_manager.initialized?).to eq false }
      it { expect(status_manager.terminated?).to eq false }
      it { expect(status_manager.quieting?).to eq false }
      it { expect(status_manager.quiet?).to eq false }
      it { expect(status_manager.done?).to eq false }
    end
  end

  describe 'initialize!' do
    context 'when we set it to initialize' do
      before do
        status_manager.initialize!
      end

      it { expect(status_manager.running?).to eq false }
      it { expect(status_manager.to_s).to eq 'initializing' }
      it { expect(status_manager.initializing?).to eq true }
      it { expect(status_manager.stopping?).to eq false }
      it { expect(status_manager.terminated?).to eq false }
      it { expect(status_manager.quieting?).to eq false }
      it { expect(status_manager.quiet?).to eq false }
      it { expect(status_manager.done?).to eq false }
    end
  end

  describe 'initialized!' do
    context 'when we set it to initialized' do
      before do
        status_manager.initialized!
      end

      it { expect(status_manager.to_s).to eq 'initialized' }
      it { expect(status_manager.initialized?).to eq true }
      it { expect(status_manager.running?).to eq false }
      it { expect(status_manager.initializing?).to eq false }
      it { expect(status_manager.stopping?).to eq false }
      it { expect(status_manager.terminated?).to eq false }
      it { expect(status_manager.quieting?).to eq false }
      it { expect(status_manager.quiet?).to eq false }
      it { expect(status_manager.done?).to eq false }
    end
  end

  describe '#reset!' do
    context 'when we reset!' do
      before do
        status_manager.initialized!
        status_manager.reset!
      end

      it { expect(status_manager.initialized?).to eq false }
      it { expect(status_manager.running?).to eq false }
      it { expect(status_manager.to_s).to eq 'initializing' }
      it { expect(status_manager.initializing?).to eq true }
      it { expect(status_manager.stopping?).to eq false }
      it { expect(status_manager.terminated?).to eq false }
      it { expect(status_manager.quieting?).to eq false }
      it { expect(status_manager.quiet?).to eq false }
      it { expect(status_manager.done?).to eq false }
    end
  end

  describe '#quiet!' do
    context 'when we quiet!' do
      before do
        status_manager.reset!
        status_manager.quiet!
      end

      it { expect(status_manager.initialized?).to eq false }
      it { expect(status_manager.running?).to eq false }
      it { expect(status_manager.to_s).to eq 'quieting' }
      it { expect(status_manager.initializing?).to eq false }
      it { expect(status_manager.stopping?).to eq false }
      it { expect(status_manager.terminated?).to eq false }
      it { expect(status_manager.quieting?).to eq true }
      it { expect(status_manager.quiet?).to eq false }
      it { expect(status_manager.done?).to eq true }
    end
  end

  describe '#quieted!' do
    context 'when we quieted!' do
      before do
        status_manager.reset!
        status_manager.quieted!
      end

      it { expect(status_manager.initialized?).to eq false }
      it { expect(status_manager.running?).to eq false }
      it { expect(status_manager.to_s).to eq 'quiet' }
      it { expect(status_manager.initializing?).to eq false }
      it { expect(status_manager.stopping?).to eq false }
      it { expect(status_manager.terminated?).to eq false }
      it { expect(status_manager.quieting?).to eq false }
      it { expect(status_manager.quiet?).to eq true }
      it { expect(status_manager.done?).to eq true }
    end
  end
end
