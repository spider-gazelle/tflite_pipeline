require "tflite_image"
require "json"
require "yaml"

module TensorflowLite::Pipeline::Configuration
  enum ModelType
    ObjectDetection
    ImageClassification
    ImageSegmentation
    PoseDetection
    FaceDetection
    AgeEstimation
    GenderEstimation
  end

  alias Scale = TensorflowLite::Image::Scale
end

require "./configuration/*"
