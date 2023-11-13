require "../configuration"

class TensorflowLite::Pipeline::Configuration::Model
  include JSON::Serializable
  include YAML::Serializable

  STORE = "model_storage"

  property type : ModelType
  property model_uri : String        # => URI
  property label_uri : String? = nil # => URI or Nil
  property scaling_mode : Scale      # fit or cover (letterbox or crop)

  # hardware acceleration
  property tpu_delegate : String? = nil
  property? gpu_delegate : Bool = false

  # face detection only
  property strides : Array(Int32)? = nil

  # age estimation ranges
  property age_ranges : Array(Int32)? = nil

  # sub-pipelines only
  # so we can apply things like pose detection only to "people" etc
  property match_label : String? = nil

  property pipeline : Array(Model) = [] of Model

  # =====================================================
  # for internal use, tracking where the files are stored
  # =====================================================

  @[JSON::Field(ignore: true)]
  @[YAML::Field(ignore: true)]
  property! scaler : Coordinator::Scaler

  @[JSON::Field(ignore_deserialize: true)]
  @[YAML::Field(ignore_deserialize: true)]
  getter warnings : Array(String) = [] of String

  @[JSON::Field(ignore: true)]
  @[YAML::Field(ignore: true)]
  getter model_path : Path do
    save_uri URI.parse(@model_uri)
  end

  @[JSON::Field(ignore: true)]
  @[YAML::Field(ignore: true)]
  getter labels : Array(String)? do
    if uri = @label_uri
      File.read_lines save_uri(URI.new(uri))
    end
  end

  def save_uri(uri : URI) : Path
    file_name = uri.path.gsub("/", "_")[1..-1]
    path = Path.new(STORE, file_name)

    unless File.exists?(path)
      Dir.mkdir_p STORE

      HTTP::Client.get(uri) do |response|
        raise "failed to download: #{uri}" unless response.success?
        File.write(path, response.body_io)
      end
    end

    path
  end

  @[JSON::Field(ignore: true)]
  @[YAML::Field(ignore: true)]
  getter client : TensorflowLite::Client do
    edge_tpu = tpu_delegate.presence

    delegate = if edge_tpu && (device = TensorflowLite::EdgeTPU.devices.find { |dev| dev.path == edge_tpu })
                 device.to_delegate
               end

    if !device && edge_tpu
      @warnings << "failed to find requested TPU, falling back to CPU processing"
    end

    if gpu_delegate?
      @warnings << "GPU delegate not available, falling back to CPU processing"
    end

    TensorflowLite::Client.new(model_path, delegate: delegate, labels: labels)
  end

  @[JSON::Field(ignore: true)]
  @[YAML::Field(ignore: true)]
  getter detector : Image::Common do
    case type
    in .object_detection?
      Image::ObjectDetection.new(client)
    in .image_classification?
      Image::Classification.new(client)
    in .pose_detection?
      Image::PoseEstimation.new(client)
    in .face_detection?
      detect = Image::FaceDetection.new(client)
      detect.generate_anchors(strides.as(Array(Int32)))
      detect
    in .age_estimation?
      age = Image::AgeEstimationRange.new(client)
      if ranges = age_ranges
        maps = Array(Range(Int32, Int32)).new(ranges.size - 1)
        ranges.each_with_index do |start, i|
          limit = ranges[i + 1]?
          next unless limit
          maps << (start...limit)
        end
        age.ranges = maps
      end
      age
    in .gender_estimation?
      Image::GenderEstimation.new(client)
    in .image_segmentation?
      raise "not supported"
    end
  end
end
