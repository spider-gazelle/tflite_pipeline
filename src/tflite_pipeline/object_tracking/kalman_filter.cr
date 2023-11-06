require "./state"
require "./matrix"

struct TensorflowLite::Pipeline::ObjectTracking::KalmanFilter
  def initialize(@transition_matrix : Matrix, @observation_matrix : Matrix, @process_noise_cov : Matrix, @observation_noise_cov : Matrix)
  end

  def self.new
    transition_matrix = Matrix.build(4, 4) do |i, j|
      i == j ? 1.0 : 0.0
    end
    observation_matrix = Matrix.build(2, 4) do |i, j|
      i == j ? 1.0 : 0.0
    end
    process_noise_cov = Matrix.build(4, 4) do |i, j|
      i == j ? 1.0 : 0.0
    end
    observation_noise_cov = Matrix.build(2, 2) do |i, j|
      i == j ? 1.0 : 0.0
    end

    new(transition_matrix, observation_matrix, process_noise_cov, observation_noise_cov)
  end

  def predict(state : State) : State
    predicted_mean = @transition_matrix * state.mean
    predicted_covariance = @transition_matrix * state.covariance * @transition_matrix.transpose + @process_noise_cov
    State.new(predicted_mean, predicted_covariance)
  end

  def update(state : State, observation : Matrix) : State
    innovation = observation - @observation_matrix * state.mean
    innovation_covariance = @observation_matrix * state.covariance * @observation_matrix.transpose + @observation_noise_cov

    # Use Cholesky Decomposition to solve for Kalman Gain instead of matrix inversion
    kalman_gain = state.covariance * @observation_matrix.transpose * (innovation_covariance.cholesky_solve(Matrix.identity(innovation_covariance.rows)))
    # kalman_gain = state.covariance * @observation_matrix.transpose * innovation_covariance.inverse

    updated_mean = state.mean + kalman_gain * innovation
    identity_matrix = Matrix.identity(@transition_matrix.rows)
    updated_covariance = (identity_matrix - kalman_gain * @observation_matrix) * state.covariance
    State.new(updated_mean, updated_covariance)
  end
end
