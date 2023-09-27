require "../configuration"

module TensorflowLite::Pipeline::Configuration
  enum InputType
    VideoDevice
    VideoStream
    Image
  end

  abstract class Input
    include JSON::Serializable

    use_json_discriminator "type", {
      "image"        => InputImage,
      "video_device" => InputDevice,
      "video_stream" => InputStream,
    }
  end

  class InputImage < Input
    property type : InputType = InputType::Image
  end

  class InputDevice < Input
    property type : InputType = InputType::VideoDevice

    # URI of the model
    property path : String
    property width : Int32?
    property height : Int32?
    property format : String = "YUYV"
  end

  class InputStream < Input
    property type : InputType = InputType::VideoStream

    # URI of the network video stream
    property path : String
  end
end
