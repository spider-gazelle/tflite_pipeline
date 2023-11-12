require "../configuration"

module TensorflowLite::Pipeline::Configuration
  enum InputType
    VideoDevice
    VideoStream
    Image
  end

  abstract class Input
    include JSON::Serializable
    include YAML::Serializable

    use_json_discriminator "type", {
      "image"        => InputImage,
      "video_device" => InputDevice,
      "video_stream" => InputStream,
    }

    use_yaml_discriminator "type", {
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

    # Path of the hardware device, such as '/dev/video1'
    property path : String
    property width : Int32?
    property height : Int32?
    property format : String = "YUYV"

    # multicast address for monitoring / replay
    property multicast_ip : String
    property multicast_port : Int32
  end

  class InputStream < Input
    property type : InputType = InputType::VideoStream

    # URI of the network video stream
    property path : String
  end
end
