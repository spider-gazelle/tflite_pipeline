require "math"

# tracks bounding boxes between frames in a scene
class TensorflowLite::Pipeline::ObjectTracking
  def initialize
  end

  getter tracks : Array(Track) = [] of Track
  getter kalman_filter : KalmanFilter = KalmanFilter.new

  alias BoundingBox = TensorflowLite::Image::Detection::BoundingBox

  def track(detections : Array(BoundingBox)) : Array(Track)
    filter(detections, tracks, @kalman_filter)
  end

  def filter(detections : Array(BoundingBox), tracks : Array(Track), kf : KalmanFilter) : Array(Track)
    # Predict the next state for each track
    predicted_tracks = tracks.map do |track|
      track.misses += 1
      kf.predict(track.state)
    end

    # Calculate the cost matrix based on distances between predicted states and detections
    cost_matrix = calculate_cost(detections, predicted_tracks)

    # Find the optimal assignment of detections to tracks
    # assignment = HungarianAlgorithm.find_assignment(cost_matrix)
    assignment = GreedyAlgorithm.find_assignment(cost_matrix)

    # Update tracks with new detections based on the assignment
    assignment.each do |(detection_index, track_index)|
      tracks[track_index].update_with_detection(detections[detection_index], predicted_tracks[track_index], kf)
    end

    # create new detections
    detections.each_with_index do |detection, index|
      unless assignment.any? { |(di, _)| di == index }
        tracks << Track.new(detection)
      end
    end

    # Handle lost tracks
    tracks.reject! { |track| track.misses >= 30 }
    tracks
  end

  def calculate_cost(detections : Array(BoundingBox), predicted_tracks : Array(State)) : Array(Array(Float64))
    # Create an empty cost matrix with dimensions [number of detections][number of tracks]
    cost_matrix = Array.new(detections.size) { Array.new(predicted_tracks.size, 0.0) }

    detections.each_with_index do |detection, i|
      predicted_tracks.each_with_index do |predicted_track, j|
        # Assume that the first two elements of the state mean vector are the predicted x and y coordinates
        predicted_x = predicted_track.mean[0, 0]
        predicted_y = predicted_track.mean[1, 0]

        # Calculate the center coordinates of the detection
        detection_x = (detection.left + detection.right) / 2.0
        detection_y = (detection.top + detection.bottom) / 2.0

        # Compute the Euclidean distance between the predicted position and the detection position
        distance = Math.sqrt((predicted_x - detection_x)**2 + (predicted_y - detection_y)**2)

        # Set the corresponding element of the cost matrix to the computed distance
        cost_matrix[i][j] = distance
      end
    end

    cost_matrix
  end
end

require "./object_tracking/*"
