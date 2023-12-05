class TensorflowLite::Pipeline::Stats
  @counts = [0, 0]
  @sums = [0.seconds, 0.seconds]
  @index = 0

  getter min : Time::Span = 9999.seconds
  getter max : Time::Span = 0.seconds
  property skipped : UInt64 = 0_u64

  def add_time(time : Time::Span)
    update_min_max(time)
    update_average(time)
  end

  def record_time(&)
    elapsed_time = Time.measure do
      yield
    end
    add_time elapsed_time
  end

  ZERO_SECONDS = 0.seconds

  # average over the last 20 -> 40 seconds
  def average : Time::Span
    count = @counts.sum
    return ZERO_SECONDS if count.zero?
    @sums.sum / count
  end

  def average_milliseconds
    average.total_milliseconds
  end

  def fps(ms = average_milliseconds)
    return 0.0 if ms.zero?
    1000.0 / ms
  end

  private def update_min_max(time : Time::Span)
    @min = [@min, time].min
    @max = [@max, time].max
  end

  BREAKPOINT = 20.seconds

  private def update_average(time : Time::Span)
    idx = @index
    @sums[idx] += time
    @counts[idx] += 1

    if @sums[idx] > BREAKPOINT
      @index = idx = idx == 0 ? 1 : 0
      @sums[idx] = 0.seconds
      @counts[idx] = 0
    end
  end
end
