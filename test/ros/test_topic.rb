$LOAD_PATH.unshift File.join(File.dirname(__FILE__), "..", "lib")
require 'minitest/spec'
require 'orocos'
require 'orocos/test'

TEST_DIR = File.expand_path('..', File.dirname(__FILE__))
DATA_DIR = File.join(TEST_DIR, 'data')
WORK_DIR = File.join(TEST_DIR, 'working_copy')

describe Orocos::ROS::Topic do
    include Orocos::Spec

end

describe Orocos::ROS::OutputTopic do
    include Orocos::Spec

    attr_reader :topic
    before do
        Orocos.load_typekit 'base'
        task = new_ruby_task_context 'ros_test'
        port = task.create_output_port('out', '/base/Time')
        port.publish_on_ros
        @topic = Orocos::ROS.topic '/ros_test/out'
    end

    describe "connect_to" do
        it "should be able to connect to an input port" do
            task = new_ruby_task_context 'rock_test'
            input_port = task.create_input_port('in', '/base/Time')
            policy = Object.new
            flexmock(input_port).should_receive(:subscribe_to_ros).once.
                with('/ros_test/out', policy)
            topic.connect_to input_port, policy
        end
    end

    it "should be able to create a functional reader object" do
        Orocos.load_typekit 'base'
        task = new_ruby_task_context 'ros_test'
        port = task.create_output_port('out', '/base/Time')
        port.create_stream(Orocos::TRANSPORT_ROS, "/ros_test_out")

        node = name_service.get(Orocos::ROS.caller_id)
        topic = node.find_output_port('ros_test_out')
        reader = topic.reader
        sample = port.new_sample
        sample.microseconds = 342235
        port.write sample
        # Account for latency in the communication channel
        100.times do
            if data = reader.read_new
                assert_equal sample, data
                return
            end
            sleep 0.05
        end
    end
end

describe Orocos::ROS::InputTopic do
    include Orocos::Spec

    attr_reader :topic
    before do
        Orocos.load_typekit 'base'
        task = new_ruby_task_context 'ros_test'
        port = task.create_input_port('in', '/base/Time')
        port.subscribe_to_ros
        @topic = Orocos::ROS.topic '/ros_test/in'
    end

    describe "connect_to" do
        it "should be able to connect to an output port" do
            task = new_ruby_task_context 'rock_test'
            output_port = task.create_output_port('out', '/base/Time')
            policy = Object.new
            flexmock(output_port).should_receive(:publish_on_ros).once.
                with('/ros_test/in', policy)
            output_port.connect_to topic, policy
        end
    end

    it "should be able to create a writer object" do
        Orocos.load_typekit 'base'
        task = new_ruby_task_context 'ros_test'
        port = task.create_input_port('out', '/base/Time')
        port.create_stream(Orocos::TRANSPORT_ROS, "/ros_test_in")

        node = name_service.get(Orocos::ROS.caller_id)
        topic = node.find_input_port('ros_test_in')
        writer = topic.writer
        sample = port.new_sample
        sample.microseconds = 342235
        writer.write sample
        # Account for latency in the communication channel
        100.times do
            if data = port.read_new
                assert_equal sample, data
                return
            end
            sleep 0.05
        end
    end

end


