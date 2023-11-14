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

  def start
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
          when @next_frame.send(frame)
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
      spawn do
        video.each_frame do |frame|
          select
          when @next_frame.send(frame)
          else
            stats.skipped += 1
            false
          end
        end
      end
    end
  end

  def shutdown
    @video.try &.close
    @replay_task.try &.close
    update_state false
  end
end
