require "./object_tracking"
require "./configuration"
require "./input"
require "promise"

# provide a method for tracking objects
module TensorflowLite::Image::Detection::BoundingBox
  property uuid : String? = nil
end

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
    @tracker = @config.track_objects? ? ObjectTracking.new : nil
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
  getter tracker : ObjectTracking? = nil
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
    local_tracker = tracker
    results = uninitialized Array(TensorflowLite::Image::Detection)

    loop do
      # grab the next image from the input
      image = input.next_frame.receive
      image_height = image.height
      image_width = image.width

      begin
        local_stats.record_time do
          # run detections over the video frame
          results = process_frame(image, image_height, image_width)

          # apply object tracking, giving each object a unique id
          if local_tracker
            objects = results.compact_map do |detection|
              case detection
              when TensorflowLite::Image::Detection::BoundingBox
                detection
              end
            end

            local_tracker.track objects
            local_tracker.tracks.each do |track|
              track.detection.uuid = track.uuid.to_s
            end
          end
        end

        @on_output.try &.call(image, results, local_stats)
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

  def process_frame(image : FFmpeg::Frame, image_height : Int32, image_width : Int32)
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
          local_min_score = task.min_score

          task.detector.process(scaled_image).compact_map do |detection|
            # remove detections that don't meet the threshold
            # also skips processing these detections
            case detection
            when TensorflowLite::Image::Detection::Classification
              next unless detection.score > local_min_score
            end

            detection.make_adjustment(cropped_width, cropped_height, image_width, image_height, offset_left, offset_top)

            # sub-pipeline scaling can't be pre-calculated as the input image is extracted from the frame
            if task.pipeline.size > 0
              detection.associated = Promise.all(task.pipeline.map { |sub_task|
                # process Configuration::SubModel in parallel
                Promise.defer { process_subtask(image, image_width, image_height, detection, sub_task) }
              }).get.flatten
            end

            detection
          end.map(&.as(TensorflowLite::Image::Detection))
        end
      end
    end
    Promise.all(promises).get.flatten
  end

  NO_OUTPUT = [] of TensorflowLite::Image::Detection

  # extracts the bounding boxes of items in the original image for additional processing
  protected def process_subtask(image, image_width, image_height, detection, task : Configuration::SubModel) : Array(TensorflowLite::Image::Detection)
    detector = task.detector
    required_aspect_ratio = detector.aspect_ratio

    case detection
    when TensorflowLite::Image::FaceDetection::Output
      # TODO:: rotate the face before processing
      # https://pyimagesearch.com/2017/05/22/face-alignment-with-opencv-and-python/
      pixels = detection.adjust_bounding_box(required_aspect_ratio, image_width, image_height)
    when TensorflowLite::Image::Detection::BoundingBox
      pixels = detection.adjust_bounding_box(required_aspect_ratio, image_width, image_height)
    end

    return NO_OUTPUT unless pixels

    # crop uses CSS style coordinates
    detection_cropped = image.crop(pixels[:top], pixels[:left], image_height - pixels[:bottom], image_width - pixels[:right])
    detection_scaled = FFmpeg::SWScale.scale(detection_cropped, *detector.resolution)

    # run through any sub models
    task.detector.process(detection_scaled).map(&.as(TensorflowLite::Image::Detection))
  rescue error
    Log.error(exception: error) { "processing pipeline subtask" }
    NO_OUTPUT
  end
end

require "./coordinator/*"
