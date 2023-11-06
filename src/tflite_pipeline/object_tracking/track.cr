require "uuid"
require "json"
require "./state"

class TensorflowLite::Pipeline::ObjectTracking::Track
  include JSON::Serializable

  property uuid : UUID
  property misses : Int32 = 0
  property detection : BoundingBox

  @[JSON::Field(ignore: true)]
  property state : State

  def initialize(detection : BoundingBox)
    @uuid = UUID.random
    @detection = detection

    mean = Matrix.build(4, 1) do |i, _|
      case i
      when 0 then (detection.left + detection.right) / 2.0
      when 1 then (detection.top + detection.bottom) / 2.0
      else        0.0
      end
    end
    covariance = Matrix.build(4, 4) do |i, j|
      i == j ? 1.0 : 0.0
    end
    @state = State.new(mean, covariance)
  end

  # Use Kalman Filter to update the track with the new detection
  def update_with_detection(detection : BoundingBox, prediction : State, kf : KalmanFilter)
    observation = Matrix.build(2, 1) do |m, _|
      m == 0 ? (detection.left + detection.right) / 2.0 : (detection.top + detection.bottom) / 2.0
    end
    @misses = 0
    @detection = detection
    @state = kf.update(prediction, observation)
  end

  @[JSON::Field(ignore: true)]
  getter to_color do
    hash = 0_i64

    @uuid.to_s.each_char.each do |char|
      hash = char.ord.to_i64 &+ ((hash << 5) &- hash)
    end

    color = String.build do |str|
      3.times do |i|
        value = (hash >> (i * 8)) & 0xFF
        str << value.to_s(16).rjust(2, '0')
      end
    end

    "##{color}"
  end
end
