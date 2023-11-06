struct TensorflowLite::Pipeline::ObjectTracking::Matrix
  getter rows : Int32
  getter cols : Int32
  getter data : Array(Array(Float64))

  def initialize(@rows : Int32, @cols : Int32)
    @data = Array.new(rows) { Array.new(cols, 0.0) }
  end

  def self.identity(size : Int32) : Matrix
    mat = Matrix.new(size, size)
    size.times do |i|
      mat[i, i] = 1.0
    end
    mat
  end

  # Class method to build a matrix with given dimensions,
  # initializing its elements with a block.
  def self.build(rows : Int32, cols : Int32, & : Int32, Int32 -> Float64) : Matrix
    mat = Matrix.new(rows, cols)
    rows.times do |i|
      cols.times do |j|
        mat[i, j] = yield i, j
      end
    end
    mat
  end

  def [](row : Int32, col : Int32) : Float64
    data[row][col]
  end

  def []=(row : Int32, col : Int32, value : Float64)
    data[row][col] = value
  end

  def transpose : Matrix
    result = Matrix.new(cols, rows)
    rows.times do |i|
      cols.times do |j|
        result[j, i] = self[i, j]
      end
    end
    result
  end

  def +(other : Matrix) : Matrix
    result = Matrix.new(rows, cols)
    rows.times do |i|
      cols.times do |j|
        result[i, j] = self[i, j] + other[i, j]
      end
    end
    result
  end

  def -(other : Matrix) : Matrix
    result = Matrix.new(rows, cols)
    rows.times do |i|
      cols.times do |j|
        result[i, j] = self[i, j] - other[i, j]
      end
    end
    result
  end

  def *(other : Matrix) : Matrix
    result = Matrix.new(rows, other.cols)
    rows.times do |i|
      other.cols.times do |j|
        sum = 0.0
        cols.times do |k|
          sum += self[i, k] * other[k, j]
        end
        result[i, j] = sum
      end
    end
    result
  end

  def inverse : Matrix
    raise "Matrix is not square" unless rows == cols

    size = rows
    mat = Matrix.new(size, size * 2)
    size.times do |i|
      size.times do |j|
        mat[i, j] = self[i, j]
      end
      mat[i, size + i] = 1.0
    end

    size.times do |i|
      diag_value = mat[i, i]
      size.times do |j|
        mat[i, j] /= diag_value
      end
      size.times do |k|
        next if k == i
        factor = mat[k, i]
        size.times do |j|
          mat[k, j] -= factor * mat[i, j]
        end
      end
    end

    result = Matrix.new(size, size)
    size.times do |i|
      size.times do |j|
        result[i, j] = mat[i, size + j]
      end
    end
    result
  end

  # Cholesky Decomposition to solve Ax = b for x where A is a positive definite matrix
  def cholesky_solve(b : Matrix) : Matrix
    raise "Matrix is not square" unless rows == cols

    # Perform Cholesky Decomposition on the matrix.
    # This will decompose the matrix into a lower triangular matrix L
    # such that A = L * L^T
    l = Array.new(rows) { Array.new(cols, 0.0) }

    rows.times do |i|
      (0...i).each do |k|
        sum = 0.0
        k.times { |j| sum += l[i][j] * l[k][j] }
        l[i][k] = (1.0 / l[k][k]) * (self[i, k] - sum)
      end

      sum = 0.0
      i.times { |j| sum += l[i][j] ** 2 }
      l[i][i] = Math.sqrt(self[i, i] - sum)
    end

    # Solve Ly = b for y (forward substitution)
    y = Array.new(rows) { Array.new(1, 0.0) }
    rows.times do |i|
      sum = 0.0
      i.times { |k| sum += l[i][k] * y[k][0] }
      y[i][0] = (b[i, 0] - sum) / l[i][i]
    end

    # Solve L^Tx = y for x (backward substitution)
    x = Array.new(rows) { Array.new(1, 0.0) }
    (rows - 1).downto(0) do |i|
      sum = 0.0
      (i + 1).upto(rows - 1) { |k| sum += l[k][i] * x[k][0] }
      x[i][0] = (y[i][0] - sum) / l[i][i]
    end

    # Convert the result to Matrix form and return
    Matrix.build(x.size, x.first.size) { |row, col| x[row][col] }
  end
end
