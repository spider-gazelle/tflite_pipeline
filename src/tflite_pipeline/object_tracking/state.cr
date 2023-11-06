require "./matrix"

struct TensorflowLite::Pipeline::ObjectTracking::State
  getter mean : Matrix
  getter covariance : Matrix

  def initialize(@mean, @covariance)
  end
end
