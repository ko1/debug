module DEBUGGER__
  class Breakpoint
    attr_reader :key

    def initialize
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
      raise "not implemented..."
    end

    def enable
      @tp.enable
    end

    def disable
      @tp.disable
    end

    def enabled?
      @tp.enabled?
    end

    def suspend
      ThreadClient.current.on_breakpoint @tp, self
    end
  end

  class LineBreakpoint < Breakpoint
    attr_reader :path, :line

    def initialize type, iseq, line, cond = nil, oneshot: false
      @iseq = iseq
      @path = iseq.path
      @line = line
      @type = type
      @cond = cond
      @oneshot = oneshot
      @key = [@path, @line].freeze

      super()
    end

    def setup
      if !@cond
        @tp = TracePoint.new(@type) do |tp|
          tp.disable if @oneshot
          suspend
        end
      else
        @tp = TracePoint.new(@type) do |tp|
          next unless safe_eval tp.binding, @cond
          tp.disable if @oneshot
          suspend
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

  class CatchBreakpoint < Breakpoint
    def initialize pat
      @key = @pat = pat.freeze
      super()
    end

    def setup
      @tp = TracePoint.new(:raise){|tp|
        exc = tp.raised_exception
        exc.class.ancestors.each{|cls|
          suspend if pat === cls.name
        }
      }
    end

    def to_s
      "catch bp #{@pat.inspect}"
    end
  end

  class CheckBreakpoint < Breakpoint
    def initialize expr
      @key = @expr = expr.freeze
      super()
    end

    def setup
      @tp = TracePoint.new(:line){|tp|
        next if tp.path.start_with? __dir__
        next if tp.path.start_with? '<internal:'

        if safe_eval tp.binding, @expr
          suspend
        end
      }
    end

    def to_s
      "check bp: #{@expr}"
    end
  end
end
