class TensorflowLite::Pipeline::BackgroundTask
  @process : Process? = nil
  @mutex : Mutex = Mutex.new(:reentrant)

  getter on_exit : Channel(Nil) = Channel(Nil).new

  def close
    @mutex.synchronize do
      on_exit.close
      if proc = @process
        proc.terminate rescue nil
      end
      @process = nil
    end
  rescue error
    Log.warn { error.message }
  end

  def finalize
    close
  end

  def run(executable, *args) : Nil
    wait_running = Channel(Process).new

    spawn do
      Process.run(executable, args, error: :inherit, output: :inherit) do |process|
        @mutex.synchronize do
          @process = process

          if on_exit.closed?
            close
            wait_running.close
          else
            begin
              wait_running.send process
            rescue
              # most likely there was a timeout waiting for this process to launch
              close
            end
          end
        end
      end

      wait_running.close
      close
    end

    # terminate ffmpeg once the spec has finished
    select
    when @process = wait_running.receive?
      raise "failed to start process: #{executable}" unless @process
      sleep 1
    when timeout(5.seconds)
      wait_running.close
      close
      raise "timeout waiting for process to start"
    end
  end
end
