require "./spec_helper"

SPEC_DETECT_IMAGE = Path.new "./bin/detect_image.jpg"

unless File.exists? SPEC_DETECT_IMAGE
  puts "downloading image file for spec..."
  Dir.mkdir_p "./bin"

  HTTP::Client.get("https://aca.im/downloads/pose.jpg") do |response|
    raise "could not download test image file" unless response.success?
    File.write(SPEC_DETECT_IMAGE, response.body_io)
  end
end

SPEC_DETECT_VIDEO = Path.new "./bin/detect_video.mp4"

unless File.exists? SPEC_DETECT_VIDEO
  puts "downloading video file for spec..."
  Dir.mkdir_p "./bin"

  HTTP::Client.get("https://os.place.tech/neural_nets/test-files/dog-walk.mp4") do |response|
    raise "could not download test image file" unless response.success?
    File.write(SPEC_DETECT_VIDEO, response.body_io)
  end
end

FONT = PCFParser::Font.from_file("#{__DIR__}/gohufont-14.pcf")

module TensorflowLite::Pipeline
  describe TensorflowLite::Pipeline do
    it "works with image input config" do
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
        },{
          "type": "face_detection",
          "model_uri": "https://raw.githubusercontent.com/patlevin/face-detection-tflite/main/fdlite/data/face_detection_back.tflite",
          "scaling_mode": "cover"
        },{
          "type": "pose_detection",
          "model_uri": "https://storage.googleapis.com/tfhub-lite-models/google/lite-model/movenet/singlepose/lightning/tflite/int8/4.tflite",
          "scaling_mode": "cover"
        }]
      })

      config = Configuration::Pipeline.from_json(json)
      coord = Coordinator.new(0, config)
      coord.tasks[0].detector.resolution.should eq({448, 448})

      coord.on_output do |image, detections|
        canvas = image.to_canvas
        detections.each do |detect|
          puts "-- #{detect.type} --"
          puts detect.to_json
          puts "-----"
          detect.markup(canvas, font: FONT)
        end
        StumpyPNG.write(canvas, "./bin/detection_output.png")
        coord.shutdown
      end

      image = StumpyJPEG.read(SPEC_DETECT_IMAGE.expand.to_s)
      spawn { coord.input.as(Input::Image).process(image) }

      coord.run_pipeline
    end

    it "works with video input" do
      json = %({
        "name": "video",
        "aync": false,
        "input": {
          "type": "video_stream",
          "path": "#{SPEC_DETECT_VIDEO}"
        },
        "output": [{
          "type": "object_detection",
          "model_uri": "https://storage.googleapis.com/tfhub-lite-models/tensorflow/lite-model/efficientdet/lite2/detection/metadata/1.tflite",
          "scaling_mode": "cover"
        },{
          "type": "face_detection",
          "model_uri": "https://raw.githubusercontent.com/patlevin/face-detection-tflite/main/fdlite/data/face_detection_back.tflite",
          "scaling_mode": "cover"
        },{
          "type": "pose_detection",
          "model_uri": "https://storage.googleapis.com/tfhub-lite-models/google/lite-model/movenet/singlepose/lightning/tflite/int8/4.tflite",
          "scaling_mode": "cover"
        }]
      })

      config = Configuration::Pipeline.from_json(json)
      coord = Coordinator.new(0, config)
      coord.tasks[0].detector.resolution.should eq({448, 448})

      frames = 0
      files = 0

      coord.on_output do |image, detections, stats|
        frames += 1

        if frames % 20 == 0
          canvas = image.to_canvas
          detections.each do |detect|
            puts "-- #{detect.type} --"
            puts detect.to_json
            puts "-----"
            detect.markup(canvas, font: FONT)
          end
          StumpyPNG.write(canvas, "./bin/video_output#{files}.png")

          files += 1
        end
        if files >= 3
          coord.shutdown
          puts "FPS: #{stats.fps}, Skipped: #{stats.skipped}"
        end
      end

      coord.run_pipeline
    end
  end
end
