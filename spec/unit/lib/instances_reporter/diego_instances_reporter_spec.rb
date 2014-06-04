require 'spec_helper'

module VCAP::CloudController::InstancesReporter
  describe DiegoInstancesReporter do
    subject { described_class.new(diego_client) }
    let(:app) { VCAP::CloudController::AppFactory.make(package_hash: 'abc', package_state: 'STAGED', instances: desired_instances) }
    let(:diego_client) { double(:diego_client) }
    let(:desired_instances) { 3 }
    let(:instances_to_return) {
      [
        {process_guid: 'process-guid', instance_guid: 'instance-A', index: 0, state: 'RUNNING', since: 1},
        {process_guid: 'process-guid', instance_guid: 'instance-B', index: 1, state: 'RUNNING', since: 2},
        {process_guid: 'process-guid', instance_guid: 'instance-C', index: 1, state: 'CRASHED', since: 3},
        {process_guid: 'process-guid', instance_guid: 'instance-D', index: 2, state: 'RUNNING', since: 4},
        {process_guid: 'process-guid', instance_guid: 'instance-E', index: 2, state: 'STARTING', since: 5},
        {process_guid: 'process-guid', instance_guid: 'instance-F', index: 3, state: 'STARTING', since: 6},
        {process_guid: 'process-guid', instance_guid: 'instance-G', index: 4, state: 'CRASHED', since: 7},
      ]
    }

    before do
      allow(diego_client).to receive(:lrp_instances).and_return(instances_to_return)
    end

    describe '#all_instances_for_app' do
      it 'should return all instances reporting for the specified app' do
        result = subject.all_instances_for_app(app)

        expect(diego_client).to have_received(:lrp_instances).with(app)
        expect(result).to eq(
                            {
                              0 => { state: 'RUNNING', since: 1 },
                              1 => { state: 'CRASHED', since: 3 },
                              2 => { state: 'STARTING', since: 5 },
                              3 => { state: 'STARTING', since: 6 },
                              4 => { state: 'CRASHED', since: 7 },
                            })
      end
    end

    describe '#number_of_starting_and_running_instances_for_app' do
      context 'when the app is not started' do
        before do
          app.state = 'STOPPED'
        end

        it 'returns 0' do
          result = subject.number_of_starting_and_running_instances_for_app(app)

          expect(diego_client).not_to have_received(:lrp_instances)
          expect(result).to eq(0)
        end
      end

      context 'when the app is started' do
        before do
          app.state = 'STARTED'
        end

        let(:desired_instances) { 3 }

        context 'when a desired instance is missing' do
          let(:instances_to_return) {
            [
              {process_guid: 'process-guid', instance_guid: 'instance-A', index: 0, state: 'RUNNING', since: 1},
              {process_guid: 'process-guid', instance_guid: 'instance-D', index: 2, state: 'STARTING', since: 4},
            ]
          }

          it 'returns the number of desired indices that have an instance in the running/starting state ' do
            result = subject.number_of_starting_and_running_instances_for_app(app)

            expect(diego_client).to have_received(:lrp_instances).with(app)
            expect(result).to eq(2)
          end
        end

        context 'when multiple instances are reporting as running/started at a desired index' do
          let(:instances_to_return) {
            [
              {process_guid: 'process-guid', instance_guid: 'instance-A', index: 0, state: 'RUNNING', since: 1},
              {process_guid: 'process-guid', instance_guid: 'instance-B', index: 0, state: 'STARTING', since: 1},
              {process_guid: 'process-guid', instance_guid: 'instance-C', index: 1, state: 'RUNNING', since: 1},
              {process_guid: 'process-guid', instance_guid: 'instance-D', index: 2, state: 'STARTING', since: 4},
            ]
          }

          it 'returns the number of desired indices that have an instance in the running/starting state ' do
            result = subject.number_of_starting_and_running_instances_for_app(app)

            expect(diego_client).to have_received(:lrp_instances).with(app)
            expect(result).to eq(3)
          end
        end

        context 'when there are undesired instances that are running/starting' do
          let(:instances_to_return) {
            [
              {process_guid: 'process-guid', instance_guid: 'instance-A', index: 0, state: 'RUNNING', since: 1},
              {process_guid: 'process-guid', instance_guid: 'instance-B', index: 1, state: 'RUNNING', since: 1},
              {process_guid: 'process-guid', instance_guid: 'instance-C', index: 2, state: 'STARTING', since: 4},
              {process_guid: 'process-guid', instance_guid: 'instance-D', index: 3, state: 'RUNNING', since: 1},
            ]
          }

          it 'returns the number of desired indices that have an instance in the running/starting state ' do
            result = subject.number_of_starting_and_running_instances_for_app(app)

            expect(diego_client).to have_received(:lrp_instances).with(app)
            expect(result).to eq(3)
          end
        end

        context 'when there are crashed instances at a desired index' do
          let(:instances_to_return) {
            [
              {process_guid: 'process-guid', instance_guid: 'instance-A', index: 0, state: 'RUNNING', since: 1},
              {process_guid: 'process-guid', instance_guid: 'instance-B', index: 0, state: 'CRASHED', since: 1},
              {process_guid: 'process-guid', instance_guid: 'instance-C', index: 1, state: 'CRASHED', since: 1},
              {process_guid: 'process-guid', instance_guid: 'instance-D', index: 2, state: 'STARTING', since: 1},
            ]
          }

          it 'returns the number of desired indices that have an instance in the running/starting state ' do
            result = subject.number_of_starting_and_running_instances_for_app(app)

            expect(diego_client).to have_received(:lrp_instances).with(app)
            expect(result).to eq(2)
          end
        end
      end
    end

    describe '#crashed_instances_for_app' do
      it 'returns an array of crashed instances' do
        result = subject.crashed_instances_for_app(app)

        expect(diego_client).to have_received(:lrp_instances).with(app)
        expect(result).to eq([
                               { 'instance' => 'instance-C', 'since' => 3 },
                               { 'instance' => 'instance-G', 'since' => 7 },
                             ])
      end
    end

    describe '#stats_for_app' do
      let(:opts) { {} }
      it 'raises an error - diego does not support stats yet' do
        expect { subject.stats_for_app(app, opts) }.to raise_error('not supported in Diego')
      end
    end
  end
end
