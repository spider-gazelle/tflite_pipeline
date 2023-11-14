require "./spec_helper"

module TensorflowLite::Pipeline
  describe TensorflowLite::Pipeline::ObjectTracking do
    it "tracks objects in the video" do
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
        }]
      })

      config = Configuration::Pipeline.from_json(json)
      coord = Coordinator.new("0", config)
      coord.tasks[0].detector.resolution.should eq({448, 448})

      frames = 0
      files = 0

      tracker = ObjectTracking.new

      coord.on_output do |image, detections, stats|
        frames += 1

        elapsed_time = Time.measure do
          objects = detections.compact_map do |d|
            case d
            when TensorflowLite::Image::Detection::BoundingBox
              d if d.score >= 0.3_f32
            end
          end
          tracker.track objects
        end
        puts "tracks: #{tracker.tracks.size} (#{elapsed_time.total_milliseconds}ms)\n#{tracker.tracks.map(&.uuid)}"

        if frames % 20 == 0
          canvas = image.to_canvas
          tracker.tracks.each do |track|
            detect = track.detection
            puts "-- drawing #{detect.type} --"
            detect.markup(canvas, font: FONT, color: StumpyPNG::RGBA.from_hex(track.to_color))
          end
          StumpyPNG.write(canvas, "./bin/tracking_output#{files}.png")

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
