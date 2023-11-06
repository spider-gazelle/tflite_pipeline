require "spec"
require "stumpy_png"
require "stumpy_jpeg"
require "../src/tflite_pipeline"

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

Spec.before_suite do
  ::Log.setup(:trace)
end
