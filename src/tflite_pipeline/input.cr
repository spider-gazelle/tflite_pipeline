require "./stats"

abstract class TensorflowLite::Pipeline::Input
  abstract def replay(before : Time::Span, after : Time::Span, & : File ->)
  abstract def start
  abstract def shutdown

  # callback to grab format information for scaler setup
  # format, width, height
  def format(&@format_cb : FFmpeg::PixelFormat, Int32, Int32 ->)
  end

  getter next_frame : Channel(FFmpeg::Frame) = Channel(FFmpeg::Frame).new
  getter stats : Stats = Stats.new
  getter? ready : Bool = false

  @ready_state_change : Array(Proc(Bool, Nil)) = [] of Proc(Bool, Nil)

  def ready_state_change(&callback : Bool ->)
    @ready_state_change << callback
  end

  protected def update_state(state : Bool)
    @ready = state
    @ready_state_change.each do |cb|
      begin
        cb.call state
      rescue error
        Log.warn(exception: error) { "in ready state change callback" }
      end
    end
  end
end

require "./input/*"
