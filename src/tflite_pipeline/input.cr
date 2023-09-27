require "./stats"

abstract class TensorflowLite::Pipeline::Input
  abstract def replay(before : Time::Span, after : Time::Span, & : File ->)
  abstract def start
  abstract def shutdown

  getter next_frame : Channel(StumpyCore::Canvas) = Channel(StumpyCore::Canvas).new
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
