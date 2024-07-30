require "./stream_replay"
require "../stats"
require "ffmpeg"

class TensorflowLite::Pipeline::Input::Stream < TensorflowLite::Pipeline::Input
  include Input::StreamReplay

  def initialize(id : String, path : String, ram_drive : Path)
    if File.exists? path
      @input = Path.new(path)
    else
      @input = URI.parse(path)
    end

    @replay_store = ram_drive / id
  end

  @input : Path | URI
  @video : FFmpeg::Video? = nil
  @is_shutdown : Bool = false

  def start
    @is_shutdown = false

    # this needs to be retriable with backoff
    # especially if we move to having a seperate clip recorder processes
    @video = video = FFmpeg::Video.open @input

    video.on_codec do |codec|
      @format_cb.try &.call(codec.pixel_format, codec.width, codec.height)
      update_state true
    end

    if @input.is_a?(Path)
      spawn do
        # video file (this only exists for specs)
        # hence why we sleep, to emulate frame pacing
        video.each_frame do |frame|
          select
          when @next_frame.send(FFmpeg::Frame.new frame)
            sleep 0.02
          else
            stats.skipped += 1
            false
          end
        end
      end
    else
      # Network video stream
      start_replay_capture(@input.to_s)
      spawn { capture_stream_frames }
    end
  end

  def capture_stream_frames
    frame_dup = nil
    video.each_frame do |frame|
      # optimise the frame copies
      frame_dup ||= FFmpeg::Frame.new(frame.width, frame.height, frame.pixel_format)

      select
      when @next_frame.send(frame.copy_to frame_dup)
        frame_dup = nil
        true
      else
        stats.skipped += 1
        false
      end
    end
  rescue error
    Log.warn(exception: error) { "stream IO failed, retrying" }
    sleep 0.5
    @video.try(&.close) rescue nil
    start unless @is_shutdown
  end

  def shutdown
    @is_shutdown = true
    @video.try &.close
    @replay_task.try &.close
    update_state false
  end
end
