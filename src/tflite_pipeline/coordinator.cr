require "./configuration"
require "./input"

class TensorflowLite::Pipeline::Coordinator
  def initialize(@index : Int32, @config : Configuration::Pipeline)
    case input = @config.input
    in Configuration::InputImage
      @input = Input::Image.new
    in Configuration::InputDevice, Configuration::InputStream
      raise NotImplementedError.new("not yet available")
    in Configuration::Input
      raise "abstract class, will never occur"
    end

    @input_errors = [] of Tuple(String, String)
    @output_errors = [] of Tuple(String, String)
    @tasks = @config.output.compact_map do |outp|
      begin
        outp.tap &.detector
      rescue error
        @output_errors << {outp.to_json, error.message || error.inspect_with_backtrace}
        nil
      end
    end
  end

  getter index : Int32
  getter input : Input
  getter tasks : Array(Configuration::Model)
  getter input_errors : Array(Tuple(String, String))
  getter output_errors : Array(Tuple(String, String))
  getter? shutdown : Bool = false

  delegate stats, replay, ready?, ready_state_change, to: @input

  def run_pipeline
    begin
      input.startup
    rescue error
      @input_errors << {@config.input.to_json, error.message || error.inspect_with_backtrace}
      raise error
    end

    loop do
      image = input.next_frame.receive
      outputs = @tasks.map do |task|
        task.detector.process
      end
      break if @shutdown
    end
  rescue error
    unless @shutdown
      Log.error(exception: error) { "running pipeline" }
      shutdown
    end
  end

  def shutdown
    @shutdown = true
    @input.shutdown
  end
end
