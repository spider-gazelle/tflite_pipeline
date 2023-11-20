require "./stream_replay"
require "../stats"
require "ffmpeg"
require "v4l2"

class TensorflowLite::Pipeline::Input::V4L2 < TensorflowLite::Pipeline::Input
  include Input::StreamReplay

  LOOPBACK_DEVICES = ::V4L2::Video.enumerate_loopback_devices
  LOOPBACK_MUTEX   = Mutex.new

  def initialize(config : Configuration::InputDevice, ram_drive : Path)
    @device = path = Path[config.path]
    video = ::V4L2::Video.new(path)
    format = video.supported_formats.find! { |form| form.code == config.format }
    resolution = format.frame_sizes.find! { |frame| frame.width == config.width && frame.height == config.height }
    @format = resolution.frame_rate
    video.close

    @multicast_address = Socket::IPAddress.new(config.multicast_ip, config.multicast_port)

    @replay_store = ram_drive / @device.stem
  end

  @device : Path
  @format : ::V4L2::FrameRate
  @video : ::V4L2::Video? = nil

  # loopback device is required if we are going to save replays
  @loopback : Path? = nil
  @loopback_task : BackgroundTask? = nil

  # we then expose the video on a multicast address so we can capture replay files
  # and we can use the same stream as a confidence monitor
  @multicast_address : Socket::IPAddress
  @streaming_task : BackgroundTask? = nil

  def start
    # see if there is a loopback device available for replay
    @loopback = loopback = LOOPBACK_MUTEX.synchronize { LOOPBACK_DEVICES.pop? }
    if loopback
      start_loopback
      start_streaming
      start_replay_capture("udp://#{@multicast_address.address}:#{@multicast_address.port}?overrun_nonfatal=1")
    end

    # configure device
    format = @format
    @video = video = ::V4L2::Video.new(loopback || @device)
    video.set_format(format).request_buffers(1)

    format_code = ::V4L2::PixelFormat.pixel_format_chars(format.format_id)
    width = format.width
    height = format.height

    ffmpeg_format = case format_code
    when "YUYV"
      FFmpeg::LibAV::PixelFormat::Yuv420P
    when "UYVY"
      FFmpeg::LibAV::PixelFormat::Yuyv422
    end

    raise "unsupported V4L2 pixel format: #{format_code}" unless ffmpeg_format

    # grab the frames
    @format_cb.try &.call(ffmpeg_format, width.to_i, height.to_i)
    spawn do
      video.stream do |buffer|
        v4l2_frame = FFmpeg::Frame.new(width, height, ffmpeg_format, buffer: buffer)
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
    task.run(
      "ffmpeg", "-f", "v4l2", "-input_format", "yuyv422",
      "-video_size", "#{@format.width}x#{@format.height}",
      "-i", @device.to_s,
      "-c:v", "copy", "-f", "v4l2", @loopback.to_s
    )
  end

  def start_streaming : Nil
    @streaming_task = task = BackgroundTask.new
    task.run(
      "ffmpeg", "-f", "v4l2", "-i", @loopback.to_s,
      "-c:v", "libx264", "-tune", "zerolatency", "-preset", "ultrafast",
      "-profile:v", "main", "-level:v", "3.1", "-pix_fmt", "yuv420p",
      "-g", "60",
      "-an", "-f", "mpegts", "udp://#{@multicast_address.address}:#{@multicast_address.port}?pkt_size=1316",
    )
  end

  def stop_background_tasks
    @loopback_task.try &.close
    @streaming_task.try &.close
    @replay_task.try &.close
  end
end
