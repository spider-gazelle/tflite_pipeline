require "../coordinator"
require "ffmpeg"

class TensorflowLite::Pipeline::Coordinator::Scaler
  QUICK_CROP_FORMATS = {
    FFmpeg::PixelFormat::Yuv420P,
    FFmpeg::PixelFormat::Yuvj420P,
    FFmpeg::PixelFormat::Rgb24,
    FFmpeg::PixelFormat::Bgr24,
    FFmpeg::PixelFormat::Rgb48Le,
    FFmpeg::PixelFormat::Rgb48Be,
  }

  def initialize(
    @input_format : FFmpeg::PixelFormat,
    @input_width : Int32,
    @input_height : Int32,
    @desired_width : Int32,
    @desired_height : Int32
  )
    # calculate actions we need to perform
    @left_crop, @top_crop = crop_required(@input_width, @input_height, @desired_width, @desired_height)
    @requires_cropping = @left_crop != 0 || @top_crop != 0
    cropped_width = @input_width - @left_crop - @left_crop
    cropped_height = @input_height - @top_crop - @top_crop

    # can we crop, scale and convert format in the same operation?
    @fast_path = @requires_cropping && QUICK_CROP_FORMATS.includes?(@input_format)

    # setup the buffers for storing the results
    @output_frame = FFmpeg::Frame.new(@desired_width, @desired_height, :rgb24)

    if requires_cropping? && !@fast_path
      Log.warn { "input format is not optimal. There will be cropping overheads" }
      @cropped_frame = FFmpeg::Frame.new(@input_width, @input_height, :rgb24)
      scale_format = FFmpeg::PixelFormat::Rgb24
      @format_change = FFmpeg::SWScale.new(@input_width, @input_height, @input_format, @input_width, @input_height, :rgb24)
    else
      # just so it's not nil
      @cropped_frame = @output_frame
      scale_format = @input_format
    end

    # init the scaler
    @scaler = FFmpeg::SWScale.new(cropped_width, cropped_height, scale_format, @desired_width, @desired_height, :rgb24)

    if requires_cropping? && !@fast_path
      @format_change = FFmpeg::SWScale.new(@input_width, @input_height, @input_format, @input_width, @input_height, :rgb24)
    else
      @format_change = @scaler
    end
  end

  # if cropping is required then we move data to this frame,
  # if no cropping is required then this is the same as above
  getter output_frame : FFmpeg::Frame

  # the hardware accelerated scaler
  @scaler : FFmpeg::SWScale

  # if we need to change formats to crop things
  @cropped_frame : FFmpeg::Frame
  @format_change : FFmpeg::SWScale

  getter input_width : Int32
  getter input_height : Int32
  getter desired_width : Int32
  getter desired_height : Int32

  getter? requires_cropping : Bool
  getter? fast_path : Bool

  # pre-calculated crop requirements
  getter left_crop : Int32
  getter top_crop : Int32

  def scale(input : FFmpeg::Frame) : FFmpeg::Frame
    if requires_cropping?
      unless fast_path?
        @format_change.scale(input, @cropped_frame)
        input = @cropped_frame
      end
      input = input.quick_crop(@top_crop, @left_crop, @top_crop, @left_crop).as(FFmpeg::Frame)
    end
    @scaler.scale(input, @output_frame)
  end

  protected def crop_required(input_width : Int32, input_height : Int32, output_width : Int32, output_height : Int32)
    # Calculate input and output ratios
    input_ratio = input_width / input_height
    output_ratio = output_width / output_height

    return {0, 0} if input_ratio == output_ratio

    if input_ratio > output_ratio
      # Crop horizontally
      new_width = (input_height * output_ratio).to_i
      crop_left = input_width - new_width
      crop_top = 0
    else
      # Crop vertically
      new_height = (input_width / output_ratio).to_i
      crop_top = input_height - new_height
      crop_left = 0
    end

    {crop_left // 2, crop_top // 2}
  end
end
