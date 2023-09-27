require "./spec_helper"

module TensorflowLite::Pipeline
  describe TensorflowLite::Pipeline do
    it "reads config and inits a coordinator" do
      json = %({
        "name": "image",
        "aync": false,
        "input": {
          "type": "image"
        },
        "output": [{
          "type": "object_detection",
          "model_uri": "https://storage.googleapis.com/tfhub-lite-models/tensorflow/lite-model/efficientdet/lite2/detection/metadata/1.tflite",
          "scaling_mode": "cover"
        }]
      })

      config = Configuration::Pipeline.from_json(json)
      coord = Coordinator.new(0, config)
      coord.tasks[0].detector.resolution.should eq({448, 448})
    end
  end
end
