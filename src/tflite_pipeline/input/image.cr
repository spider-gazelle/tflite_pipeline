require "../input"
require "../stats"

class TensorflowLite::Pipeline::Input::Image < TensorflowLite::Pipeline::Input
  def initialize
  end

  getter! current_image : StumpyCore::Canvas

  def replay(before : Time::Span, after : Time::Span, & : File ->)
    canvas = current_image
    file_name = File.tempname("replay", ".png")

    begin
      StumpyPNG.write(canvas, file_name)
      File.open(file_name) do |file|
        yield file
      end
    ensure
      File.delete? file_name
    end
  end

  def process(image : StumpyCore::Canvas)
    @current_image = image

    # todo:: perform the measurements in the coordinator class
    # @stats.add_time(Time.measure {
    #
    # })

    select
    when @image_channel.send(image) then true
    else
      stats.skipped += 1
      false
    end
  end

  def start
    update_state true
  end

  def shutdown
    next_frame.close
    update_state false
  end
end
