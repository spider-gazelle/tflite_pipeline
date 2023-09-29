require "spec"
require "stumpy_png"
require "stumpy_jpeg"
require "../src/tflite_pipeline"

Spec.before_suite do
  ::Log.setup(:trace)
end
