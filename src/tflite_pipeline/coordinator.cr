require "./configuration"
require "./input"
require "promise"

class TensorflowLite::Pipeline::Coordinator
  REPLAY_MOUNT_PATH = Path[ENV["REPLAY_MOUNT_PATH"]? || "/mnt/ramdisk"]
  REPLAY_MEM_SIZE   = ENV["REPLAY_MEM_SIZE"]? || "512M"

  def initialize(@id : String, @config : Configuration::Pipeline)
    case input = @config.input
    in Configuration::InputImage
      @input = Input::Image.new
    in Configuration::InputStream
      @input = Input::Stream.new(@id, input.path, REPLAY_MOUNT_PATH)
    in Configuration::InputDevice
      configure_ram_drive
      @input = Input::V4L2.new(input, REPLAY_MOUNT_PATH)
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

    @scalers = [] of Tuple(Scaler, Array(Configuration::Model))
    @input.format &->configure_task_scalers(FFmpeg::PixelFormat, Int32, Int32)
  end

  # ram drive for saving replays
  protected def configure_ram_drive
    output = IO::Memory.new
    status = Process.run("mount", output: output)
    raise "failed to check for existing mount" unless status.success?

    # NOTE:: this won't work in production running as a low privileged user
    # sudo mkdir -p /mnt/ramdisk
    # sudo mount -t tmpfs -o size=512M tmpfs /mnt/ramdisk
    if !String.new(output.to_slice).includes?(REPLAY_MOUNT_PATH.to_s)
      Dir.mkdir_p REPLAY_MOUNT_PATH
      status = Process.run("mount", {"-t", "tmpfs", "-o", "size=#{REPLAY_MEM_SIZE}", "tmpfs", REPLAY_MOUNT_PATH.to_s})
      raise "failed to mount ramdisk: #{REPLAY_MOUNT_PATH}" unless status.success?
    end
  end

  # initialze the scalers on startup for improved performance
  protected def configure_task_scalers(format : FFmpeg::PixelFormat, width : Int32, height : Int32)
    scalers = {} of Tuple(Int32, Int32) => Scaler
    task_map = Hash(Tuple(Int32, Int32), Array(Configuration::Model)).new { |h, k| h[k] = [] of Configuration::Model }

    # create the scalers and task map
    @tasks.each do |task|
      res = task.detector.resolution
      scaler = scalers[res]? || Scaler.new(format, width, height, *res)
      scalers[res] = scaler
      task_map[res] << task
    end

    # combine these
    combined = task_map.map { |res, tasks| {scalers[res], tasks} }
    @scalers = combined
  end

  getter id : String
  getter input : Input
  getter tasks : Array(Configuration::Model)
  getter input_errors : Array(Tuple(String, String))
  getter output_errors : Array(Tuple(String, String))
  getter? shutdown : Bool = false

  delegate stats, replay, ready?, ready_state_change, to: @input

  def on_output(&@on_output : FFmpeg::Frame, Array(TensorflowLite::Image::Detection), Stats ->)
  end

  def run_pipeline
    begin
      input.start
    rescue error
      @input_errors << {@config.input.to_json, error.message || error.inspect_with_backtrace}
      raise error
    end

    local_stats = stats

    loop do
      # grab the next image from the input
      image = input.next_frame.receive
      image_height = image.height
      image_width = image.width

      begin
        local_stats.record_time do
          # process the image in parallel and ensure all results are normalised and
          # adjusted for placement on the original image
          promises = @scalers.flat_map do |(scaler, tasks)|
            # grab the scaled image for the tasks that work with this resolution
            scale_task = Promise.defer { scaler.scale(image); nil }

            tasks.map do |task|
              Promise.defer do
                scale_task.get
                scaled_image = scaler.output_frame

                offset_top = scaler.top_crop
                offset_left = scaler.left_crop
                cropped_height = image_height - offset_top - offset_top
                cropped_width = image_width - offset_left - offset_left

                task.detector.process(scaled_image).map do |detection|
                  detection.make_adjustment(cropped_width, cropped_height, image_width, image_height, offset_left, offset_top)

                  # TODO:: need to run sub pipelines
                  # sub-pipeline scaling can't be pre-calculated as the input image is extracted from the frame

                  detection.as(TensorflowLite::Image::Detection)
                end
              end
            end
          end

          results = Promise.all(promises).get.flatten

          @on_output.try &.call(image, results, local_stats)
        end
      rescue error
        Log.warn(exception: error) { "processing frame" }
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

require "./coordinator/*"
