module GreedyAlgorithm
  def self.find_assignment(cost_matrix : Array(Array(Float64))) : Array(Tuple(Int32, Int32))
    assignment = [] of Tuple(Int32, Int32)
    remaining_rows = (0...cost_matrix.size).to_a
    remaining_cols = (0...cost_matrix[0].size).to_a

    while !remaining_rows.empty? && !remaining_cols.empty?
      # Find the pair with the smallest cost
      min_cost = Float64::INFINITY
      min_indices = nil

      remaining_rows.each do |i|
        remaining_cols.each do |j|
          if cost_matrix[i][j] < min_cost
            min_cost = cost_matrix[i][j]
            min_indices = {i, j}
          end
        end
      end

      # this will never be nil, but here to satisfy the compiler
      break unless min_indices

      # Assign the detection to the track
      assignment << min_indices

      # Remove the corresponding row and column
      remaining_rows.delete(min_indices[0])
      remaining_cols.delete(min_indices[1])
    end

    assignment
  end
end
