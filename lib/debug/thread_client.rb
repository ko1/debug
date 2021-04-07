module DEBUGGER__
  class ThreadClient
    def self.current
      Thread.current[:DEBUGGER__ThreadClient] || begin
        tc = SESSION.thread_client
        Thread.current[:DEBUGGER__ThreadClient] = tc
      end
    end

    attr_reader :location, :thread

    def initialize q_evt, q_cmd, thr = Thread.current
      @thread = thr
      @q_evt = q_evt
      @q_cmd = q_cmd
      @step_tp = nil
      @output = []
      @mode = nil
    end

    def inspect
      "#<DEBUGGER__ThreadClient #{@thread}>"
    end

    def puts str = ''
      case str
      when nil
        @output << "\n"
      when Array
        str.each{|s| puts s}
      else
        @output << str.chomp + "\n"
      end
    end

    def << req
      @q_cmd << req
    end

    def event! ev, *args
      @q_evt << [self, @output, ev, *args]
      @output = []
    end

    ## events

    def on_trap
      if @mode == :wait_next_action
        raise Interrupt
      else
        on_suspend :trap
      end
    end

    def on_pause
      on_suspend :pause
    end

    def on_load iseq, eval_src
      event! :load, iseq, eval_src
      wait_next_action
    end

    def on_breakpoint tp
      on_suspend tp.event, tp
    end

    def on_suspend event, tp = nil
      @current_frame_index = 0
      @target_frames = target_frames
      cf = @target_frames.first
      if cf
        @location = cf.location
        case event
        when :return, :b_return, :c_return
          cf.has_return_value = true
          cf.return_value = tp.return_value
        end
      end

      if event != :pause
        show_src
        print_frames 3
        event! :suspend, :breakpoint
      end

      wait_next_action
    end
    
    ## control all

    def step_tp
      @step_tp.disable if @step_tp
      @step_tp = TracePoint.new(:line, :b_return, :return){|tp|
        next if SESSION.break? tp.path, tp.lineno
        next if !yield
        tp.disable
        on_suspend tp.event, tp
      }

      @step_tp.enable(target_thread: Thread.current)
    end

    FrameInfo = Struct.new(:location, :self, :binding, :iseq, :class, :has_return_value, :return_value)

    def target_frames
      RubyVM::DebugInspector.open{|dc|
        locs = dc.backtrace_locations
        locs.map.with_index{|e, i|
          unless File.dirname(e.path) == File.dirname(__FILE__)
            FrameInfo.new(
              e,
              dc.frame_self(i),
              dc.frame_binding(i),
              dc.frame_iseq(i),
              dc.frame_class(i))
          end
        }.compact
      }
    end

    def target_frames_count
      RubyVM::DebugInspector.open{|dc|
        locs = dc.backtrace_locations
        locs.count{|e|
          e.path != __FILE__
        }
      }
    end

    def current_frame
      @target_frames[@current_frame_index]
    end

    def file_lines path
      if (src = SESSION.source(path)) && src[0]
        src[0].lines
      elsif File.exist?(path)
        File.readlines(path)
      end
    end

    def show_src frame_index = @current_frame_index, max_lines: 10
      if current_line = @target_frames[frame_index]&.location
        puts
        path, line = current_line.path, current_line.lineno - 1
        if file_lines = file_lines(path)
          lines = file_lines.map.with_index{|e, i|
            if i == line
              "=> #{'%4d' % (i+1)}| #{e}"
            else
              "   #{'%4d' % (i+1)}| #{e}"
            end
          }
          min = [0, line - max_lines/2].max
          max = [min+max_lines, lines.size].min
          puts "[#{min+1}, #{max}] in #{path}"
          puts lines[min ... max]
        end
      end
    end

    def show_locals
      if s = current_frame&.self
        puts " %self => #{s}"
      end
      if current_frame&.has_return_value
        puts " %return => #{current_frame.return_value}"
      end
      if b = current_frame&.binding
        b.local_variables.each{|loc|
          puts " #{loc} => #{b.local_variable_get(loc).inspect}"
        }
      end
    end

    def show_ivars
      if s = current_frame&.self
        puts " self => #{s}"
        s.instance_variables.eaach{|iv|
          puts " #{iv} => #{s.instance_variable_get(iv)}"
        }
      end
    end

    def frame_eval src, failed_value: nil
      begin
        b = current_frame.binding
        if b
          b.eval(src)
        else
          frame_self = current_frame.self
          frame_self.instance_eval(src)
          # puts "eval is not supported on this frame."
        end
      rescue Exception => e
        return failed_value if failed_value

        puts "Error: #{e}"
        e.backtrace_locations.each do |loc|
          break if loc.path == __FILE__
          puts "  #{loc}"
        end
        nil
      end
    end

    def parameters_info b, vars
      vars.map{|var|
        "#{var}=#{short_inspect(b.eval(var.to_s))}"
      }.join(', ')
    end

    def klass_sig frame
      klass = frame.class
      if klass == frame.self.singleton_class
        klass_sig = "#{frame.self}."
      else
        klass_sig = "#{frame.class}#"
      end
    end

    SHORT_INSPECT_LENGTH = 40

    def short_inspect obj
      str = obj.inspect
      if str.length > SHORT_INSPECT_LENGTH
        str[0...SHORT_INSPECT_LENGTH] + '...'
      else
        str
      end
    end

    def frame_str i
      buff = ''.dup
      frame = @target_frames[i]
      b = frame.binding

      buff << (@current_frame_index == i ? '--> ' : '    ')
      if b
        buff << "##{i}\t#{frame.location}"
      else
        buff << "##{i}\t[C] #{frame.location}"
      end

      if b && (iseq = frame.iseq)
        if iseq.type == :block
          if (argc = iseq.argc) > 0
            args = parameters_info b, iseq.locals[0...iseq.argc]
            buff << " {|#{args}|}"
          end
        else
          callee = b.eval('__callee__')
          if callee && (m = frame.self.method(callee))
            args = parameters_info b, m.parameters.map{|type, v| v}
            ksig = klass_sig frame
            buff << " #{ksig}#{callee}(#{args})"
          end
        end

        if frame.has_return_value
          buff << " #=> #{short_inspect(frame.return_value)}"
        end
      else
        # p frame.self
      end

      buff
    end

    def show_frame_all
      @target_frames.size.times{|i|
        puts frame_str(i)
      }
    end

    def print_frame i
      puts frame_str(i)
    end

    def print_frames n
      size = @target_frames.size
      ([size, n].min).times{|i|
        print_frame i
      }
      if n < size
        puts "    # and #{size - n} frames (use `bt' command for all frames)"
      end
    end

    def wait_next_action
      @mode = :wait_next_action

      while cmds = @q_cmd.pop
        cmd, *args = *cmds

        case cmd
        when :continue
          break
        when :step
          step_type = args[0]
          case step_type
          when :in
            step_tp{true}
          when :next
            size = @target_frames.size
            step_tp{
              target_frames_count() <= size
            }
          when :finish
            size = @target_frames.size
            step_tp{target_frames_count() < size}
          else
            raise
          end
          break
        when :eval
          eval_type, eval_src = *args
          result = frame_eval(eval_src)

          case eval_type
          when :p
            puts "=> " + result.inspect
          when :pp
            puts "=> "
            PP.pp(result, out = ''.dup)
            puts out
          when :call
            result = frame_eval(eval_src)
          when :display
            eval_src.each_with_index{|src, i|
              puts "#{i}: #{src} = #{frame_eval(src, failed_value: :error).inspect}"
            }
            result = :ok
          else
            raise "unknown error option: #{args.inspec}"
          end
          event! :result, result
        when :frame
          type, arg = *args
          case type
          when :up
            if @current_frame_index + 1 < @target_frames.size
              @current_frame_index += 1 
              show_src max_lines: 1
              print_frame(@current_frame_index)
            end
          when :down
            if @current_frame_index > 0
              @current_frame_index -= 1
              show_src max_lines: 1
              print_frame(@current_frame_index)
            end
          when :set
            if arg
              index = arg.to_i
              if index >= 0 && index < @target_frames.size
                @current_frame_index = index
              else
                puts "out of frame index: #{index}"
              end
            end
            show_src max_lines: 1
            print_frame(@current_frame_index)
          else
            raise "unsupported frame operation: #{arg.inspect}"
          end
          event! :result, nil
        when :show
          type, = *args
          case type
          when :backtrace
            show_frame_all
          when :list
            show_src
          when :locals
            show_locals
          when :ivars
            show_ivars
          else
            raise "unknown show param: " + args.inspect
          end
          event! :result, nil
        else
          raise [ev, *args].inspect
        end
      end

    rescue SystemExit
      raise
    rescue Exception => e
      pp [__FILE__, __LINE__, e, e.backtrace]
      raise
    ensure
      @mode = nil
    end

    def to_s
      "(#{@thread.name || @thread.status})@#{current_frame&.location}"
    end
  end
end
