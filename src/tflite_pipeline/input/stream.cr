require "../input"
require "../stats"
require "ffmpeg"

class TensorflowLite::Pipeline::Input::Stream < TensorflowLite::Pipeline::Input
  def initialize(path : String)
    if File.exists? path
      @input = Path.new(path)
    else
      @input = URI.parse(path)
    end
  end

  @input : Path | URI
  @video : FFmpeg::Video? = nil

  def replay(before : Time::Span, after : Time::Span, & : File ->)
    raise "not implemented"
  end

  def start
    @video = video = FFmpeg::Video.open @input

    video.on_codec do |codec|
      @format_cb.try &.call(codec.pixel_format, codec.width, codec.height)
      update_state true
    end

    spawn do
      video.each_frame do |frame|
        select
        when @next_frame.send(frame)
          sleep 0.02 if @input.is_a?(Path)
        else
          stats.skipped += 1
          false
        end
      end
    end
  end

  def shutdown
    @video.try &.close
    update_state false
  end
end
