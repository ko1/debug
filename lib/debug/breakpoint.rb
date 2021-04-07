module DEBUGGER__
  class LineBreakpoint
    attr_reader :path, :line, :key

    def initialize type, iseq, line, cond = nil, oneshot: false
      @iseq = iseq
      @path = iseq.path
      @line = line
      @type = type
      @cond = cond
      @oneshot = oneshot
      @key = [@path, @line].freeze
      setup
      enable
    end

    def safe_eval b, expr
      b.eval(expr)
    rescue Exception => e
      puts "[EVAL ERROR]"
      puts "  expr: #{expr}"
      puts "  err: #{e} (#{e.class})"
      nil
    end

    def setup
      if !@cond
        @tp = TracePoint.new(@type) do |tp|
          tp.disable if @oneshot
          ThreadClient.current.on_breakpoint tp
        end
      else
        @tp = TracePoint.new(@type) do |tp|
          next unless safe_eval tp.binding, @cond
          tp.disable if @oneshot
          ThreadClient.current.on_breakpoint tp
        end
      end
    end

    def enable
      if @type == :line
        @tp.enable(target: @iseq, target_line: @line)
      else
        @tp.enable(target: @iseq)
      end
    rescue ArgumentError
      puts @iseq.disasm # for debug
      raise
    end

    def disable
      @tp.disable
    end

    def to_s
      "line bp #{@iseq.absolute_path}:#{@line} (#{@type})" +
        if @cond
          "if #{@cond}"
        else
          ""
        end
    end

    def inspect
      "<#{self.class.name} #{self.to_s}>"
    end
  end

  class CatchBreakpoint
    attr_reader :key

    def initialize pat
      @pat = pat
      @tp = TracePoint.new(:raise){|tp|
        exc = tp.raised_exception
        exc.class.ancestors.each{|cls|
          if pat === cls.name
            puts "catch #{exc.class.inspect} by #{@pat.inspect}"
            ThreadClient.current.on_suspend :catch
          end
        }
      }
      @tp.enable

      @key = pat.freeze
    end

    def disable
      @tp.disable
    end

    def to_s
      "catch bp #{@pat.inspect}"
    end
  end
end
