require "../stats"
require "ffmpeg"
require "v4l2"
require "simple_retry"

class TensorflowLite::Pipeline::Input::V4L2 < TensorflowLite::Pipeline::Input
  LOOPBACK_DEVICES = ::V4L2::Video.enumerate_loopback_devices
  LOOPBACK_MUTEX   = Mutex.new

  def initialize(config : Configuration::InputDevice)
    @device = path = Path[config.path]
    video = ::V4L2::Video.new(path)
    format = video.supported_formats.find! { |form| form.code == config.format }
    @width = config.width.as(Int32).to_u32
    @height = config.height.as(Int32).to_u32

    @resolution = format.frame_sizes.find! do |frame|
      if frame.type.discrete?
        frame.width == @width && frame.height == @height
      else
        @width >= frame.min_width &&
          @width <= frame.max_width &&
          @height >= frame.min_height &&
          @height <= frame.max_height
      end
    end
    video.close

    @multicast_address = Socket::IPAddress.new(config.multicast_ip, config.multicast_port)
  end

  @device : Path
  @resolution : ::V4L2::FrameSize
  @video : ::V4L2::Video? = nil

  getter width : UInt32
  getter height : UInt32

  # loopback device is required if we are going to save replays
  @loopback : Path? = nil
  @loopback_task : BackgroundTask? = nil

  # we then expose the video on a multicast address so we can capture replay files
  # and we can use the same stream as a confidence monitor
  @multicast_address : Socket::IPAddress
  @streaming_task : BackgroundTask? = nil

  getter? shutting_down : Bool = false

  def start
    @shutting_down = false

    # see if there is a loopback device available for replay
    @loopback = loopback = LOOPBACK_MUTEX.synchronize { LOOPBACK_DEVICES.pop? }
    if loopback
      start_loopback
      start_streaming
    end

    # configure device
    resolution = @resolution
    @video = video = ::V4L2::Video.new(loopback || @device)

    SimpleRetry.try_to(
      # Runs the block at most 5 times
      max_attempts: 5,
      # Initial delay time after first retry
      base_interval: 200.milliseconds,
      # Exponentially increase delay up to this period
      max_interval: 5.seconds
    ) do
      video.set_format(
        resolution.format_id,
        width,
        width,
        ::V4L2::BufferType::VIDEO_CAPTURE
      ).request_buffers(1)
    end

    format_code = ::V4L2::PixelFormat.pixel_format_chars(resolution.format_id)
    ffmpeg_format = case format_code
                    when "YUYV"
                      FFmpeg::LibAV::PixelFormat::Yuyv422
                    when "UYVY"
                      FFmpeg::LibAV::PixelFormat::Yuv420P
                    end

    raise "unsupported V4L2 pixel format: #{format_code}" unless ffmpeg_format

    # grab the frames
    @format_cb.try &.call(ffmpeg_format, width.to_i, height.to_i)
    spawn do
      w = width
      h = height
      video.stream do |buffer|
        v4l2_frame = FFmpeg::Frame.new(w, h, ffmpeg_format, buffer: buffer)
        select
        when @next_frame.send(v4l2_frame)
        else
          stats.skipped += 1
          false
        end
      end
    end

    update_state true
  rescue error
    return_loopback
    raise error
  end

  def shutdown
    @video.try &.close
    stop_background_tasks
    return_loopback
    update_state false
  end

  protected def return_loopback
    if loopback = @loopback
      LOOPBACK_MUTEX.synchronize { LOOPBACK_DEVICES.push(loopback) }
      @loopback = nil
    end
  end

  def start_loopback : Nil
    @loopback_task = task = BackgroundTask.new
    spawn do
      task.on_exit.receive?
      if !shutting_down?
        sleep 1
        start_loopback
      end
    end
    task.run(
      "ffmpeg", "-f", "v4l2", "-input_format", "yuyv422",
      "-video_size", "#{width}x#{height}",
      "-i", @device.to_s,
      "-c:v", "copy", "-f", "v4l2", @loopback.to_s
    )
  end

  def start_streaming : Nil
    @streaming_task = task = BackgroundTask.new
    spawn do
      task.on_exit.receive?
      if !shutting_down?
        sleep 1
        start_streaming
      end
    end
    task.run(
      "ffmpeg", "-f", "v4l2", "-i", @loopback.to_s,
      "-c:v", "libx264", "-tune", "zerolatency", "-preset", "ultrafast",
      "-profile:v", "main", "-level:v", "3.1", "-pix_fmt", "yuv420p",
      "-g", "60",
      "-an", "-f", "mpegts", "udp://#{@multicast_address.address}:#{@multicast_address.port}?pkt_size=1316",
    )
  end

  def stop_background_tasks
    @shutting_down = true
    @loopback_task.try &.close
    @streaming_task.try &.close
  end
end
