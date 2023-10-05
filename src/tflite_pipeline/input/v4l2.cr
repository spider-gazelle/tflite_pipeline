require "../input"
require "../stats"
require "ffmpeg"
require "v4l2"

class TensorflowLite::Pipeline::Input::V4L2 < TensorflowLite::Pipeline::Input
  LOOPBACK_DEVICES = ::V4L2::Video.enumerate_loopback_devices
  LOOPBACK_MUTEX   = Mutex.new

  def initialize(path : String, @format : ::V4L2::FrameRate, @multicast_address : Socket::IPAddress, ram_drive : Path)
    @device = Path.new(path)
    @replay_store = ram_drive / @device.stem
    Dir.mkdir_p @replay_store
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

  # this process captures chunks of video so we can generate replays
  @replay_task : BackgroundTask? = nil
  @replay_store : Path
  @replay_mutex : Mutex = Mutex.new

  def replay(before : Time::Span, after : Time::Span, & : File ->)
    raise "replay not available" unless @replay_task

    created_after = before.ago
    sleep after # wait for future files to be generated

    file_list = File.tempname("replay-", ".txt")
    output_file = File.tempname("replay-", ".ts")
    begin
      replay_file = @replay_mutex.synchronize do
        construct_replay(file_list, output_file, created_after)
      end
      yield replay_file
    ensure
      File.delete output_file
      File.delete file_list
    end
  end

  protected def construct_replay(file_list : String, output_file : String, created_after : Time) : File
    files = Dir.entries(@replay_store).select do |file|
      next if {".", ".."}.includes?(file)
      file = File.join(@replay_store, "../", file)

      begin
        info = File.info(file)
        !info.size.zero? && info.modification_time >= created_after
      rescue err : File::NotFoundError
        nil
      rescue error
        puts "Error obtaining file info for #{file}\n#{error.inspect_with_backtrace}"
        nil
      end
    end

    # ensure the files are joined in the correct order
    files.map! { |file| File.join(@replay_store, file) }.sort! do |file1, file2|
      info1 = File.info(file1)
      info2 = File.info(file2)
      info1.modification_time <=> info2.modification_time
    end

    # generate a list of files to be included in the output
    raise "no replay files found..." if files.size.zero?
    File.open(file_list, "w") do |list|
      files.each { |file| list.puts("file '#{file}'") }
    end

    # concat the files
    status = Process.run("ffmpeg", {
      "-f", "concat", "-safe", "0",
      "-i", file_list, "-c", "copy",
      output_file,
    }, error: :inherit, output: :inherit)

    raise "failed to save video replay" unless status.success?

    File.new(output_file)
  end

  def start
    # see if there is a loopback device available for replay
    @loopback = loopback = LOOPBACK_MUTEX.synchronize { LOOPBACK_DEVICES.pop? }
    if loopback
      start_loopback
      start_streaming
      start_replay_capture
    end

    # configure device
    format = @format
    @video = video = ::V4L2::Video.new(loopback || @device)
    video.set_format(format).request_buffers(1)

    format_code = ::V4L2::PixelFormat.pixel_format_chars(format.format_id)
    width = format.width
    height = format.height

    # grab the frames
    case format_code
    when "YUYV"
      spawn do
        video.stream do |buffer|
          v4l2_frame = FFmpeg::Frame.new(width, height, :yuyv422, buffer: buffer)
          select
          when @next_frame.send(v4l2_frame)
          else
            stats.skipped += 1
            false
          end
        end
      end
    else
      raise "unsupported V4L2 pixel format: #{format_code}"
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

  def start_replay_capture : Nil
    @replay_task = task = BackgroundTask.new
    filenames = File.join(@replay_store, "output_%Y%m%d%H%M%S.ts")
    task.run(
      "ffmpeg",
      "-i", "udp://#{@multicast_address.address}:#{@multicast_address.port}?overrun_nonfatal=1",
      "-c", "copy", "-copyinkf", "-an", "-map", "0", "-f",
      "segment", "-segment_time", "2",
      "-reset_timestamps", "1", "-strftime", "1", filenames
    )

    spawn { cleanup_old_files }
  end

  protected def cleanup_old_files : Nil
    loop do
      sleep 11.seconds
      break if @replay_task.try(&.on_exit.closed?)
      expired_time = 180.seconds.ago

      @replay_mutex.synchronize do
        files = Dir.entries(@replay_store)
        Log.info { "Checking #{files.size} files for removal" }

        files.each do |file|
          begin
            next if {".", ".."}.includes?(file)
            file = File.join(@replay_store, file)
            File.delete(file) if File.info(file).modification_time < expired_time
          rescue error
            Log.error(exception: error) { "Error checking removal of #{file}" }
          end
        end
      end
    end
  end

  def stop_background_tasks
    @loopback_task.try &.close
    @streaming_task.try &.close
    @replay_task.try &.close
  end
end
