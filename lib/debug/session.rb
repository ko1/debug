require 'json'
require 'pp'
require 'debug_inspector'
require 'iseq_collector'

require_relative 'source_repository'
require_relative 'breakpoint'
require_relative 'thread_client'

class RubyVM::InstructionSequence
  def traceable_lines_norec lines
    code = self.to_a[13]
    line = 0
    code.each{|e|
      case e
      when Integer
        line = e
      when Symbol
        if /\ARUBY_EVENT_/ =~ e.to_s
          lines[line] = [e, *lines[line]]
        end
      end
    }
  end

  def traceable_lines_rec lines
    self.each_child{|ci| ci.traceable_lines_rec(lines)}
    traceable_lines_norec lines
  end

  def type
    self.to_a[9]
  end

  def argc
    self.to_a[4][:arg_size]
  end

  def locals
    self.to_a[10]
  end
end

module DEBUGGER__
  class Session
    def initialize ui
      @ui = ui
      @sr = SourceRepository.new
      @reserved_bps = []
      @bps = {} # [file, line] => LineBreakpoint || "Error" => CatchBreakpoint
      @th_clients = {} # {Thread => ThreadClient}
      @q_evt = Queue.new
      @displays = []

      @tp_load_script = TracePoint.new(:script_compiled){|tp|
        ThreadClient.current.on_load tp.instruction_sequence, tp.eval_script
      }.enable

      @session_server = Thread.new do
        Thread.current.abort_on_exception = true

        while evt = @q_evt.pop
          tc, output, ev, *ev_args = evt
          output.each{|str| @ui.puts str}

          case ev
          when :load
            iseq, src = ev_args
            on_load iseq, src
            tc << :continue
          when :suspend
            if @displays.empty?
              wait_command_loop tc
            else
              tc << [:eval, :display, @displays]
            end
          when :result
            wait_command_loop tc
          end
        end
      end

      @management_threads = [@session_server]

      setup_threads
    end

    attr_reader :management_threads

    def source path
      @sr.get(path)
    end

    def inspect
      "DEBUGGER__::SESSION"
    end

    def wait_command_loop tc
      @tc = tc
      stop_all_threads do
        loop do
          case wait_command
          when :retry
            # nothing
          else
            break
          end
        rescue Interrupt
          retry
        end
      end
    end

    def wait_command
      line = @ui.readline

      if line.empty?
        if @repl_prev_line
          line = @repl_prev_line
        else
          return :retry
        end
      else
        @repl_prev_line = line
      end

      /([^\s]+)(?:\s+(.+))?/ =~ line
      cmd, arg = $1, $2

      # p cmd: [cmd, *arg]

      case cmd

      # control
      when 's', 'step'
        @tc << [:step, :in]
      when 'n', 'next'
        @tc << [:step, :next]
      when 'fin', 'finish'
        @tc << [:step, :finish]
      when 'c', 'continue'
        @tc << :continue
      when 'q', 'quit'
        if ask 'Really quit?'
          @ui.quit arg.to_i
          @tc << :continue
        else
          return :retry
        end
      when 'kill'
        if ask 'Really quit?'
          exit! (arg || 1).to_i
        else
          return :retry
        end

      # breakpoints
      when 'b', 'break'
        if arg == nil
          show_bps
        else
          bp = repl_add_breakpoint arg
          show_bps bp if bp
        end
        return :retry
      when 'bv'
        h = Hash.new{|h, k| h[k] = []}
        @bps.each{|key, bp|
          if LineBreakpoint === bp
            h[bp.path] << {lnum: bp.line}
          end
        }
        if h.empty?
          # TODO: clean?
        else
          open(".rdb_breakpoints.json", 'w'){|f| JSON.dump(h, f)}
        end

        system("vim -R -S bp.vim #{@tc.location.path}")

        if File.exist?(".rdb_breakpoints.json")
          pp JSON.load(File.read(".rdb_breakpoints.json"))
        end

        return :retry
      when 'catch'
        if arg
          bp = add_catch_breakpoint arg
          show_bps bp if bp
        end
        return :retry
      when 'del', 'delete'
        bp =
        case arg
        when nil
          show_bps
          if ask "Remove all breakpoints?", 'N'
            delete_breakpoint
          end
        when /\d+/
          delete_breakpoint arg.to_i
        else
          nil
        end
        @ui.puts "deleted: \##{bp[0]} #{bp[1]}" if bp
        return :retry

      # evaluate
      when 'p'
        @tc << [:eval, :p, arg.to_s]
      when 'pp'
        @tc << [:eval, :pp, arg.to_s]
      when 'e', 'eval', 'call'
        @tc << [:eval, :call, arg]
      when 'irb'
        @tc << [:eval, :call, 'binding.irb']

      # evaluate/frame selector
      when 'up'
        @tc << [:frame, :up]
      when 'down'
        @tc << [:frame, :down]
      when 'frame', 'f'
        @tc << [:frame, :set, arg]

      # information
      when 'bt', 'backtrace'
        @tc << [:show, :backtrace]
      when 'list'
        @tc << [:show, :list]
      when 'info'
        case arg
        when 'l', 'local', 'locals'
          @tc << [:show, :locals]
        when 'i', 'instance', 'ivars'
          @tc << [:show, :ivars]
        else
          @ui.puts "unknown info argument: #{arg}"
          return :retry
        end
      when 'display'
        @displays << arg if arg && !arg.empty?
        @tc << [:eval, :display, @displays]
      when 'undisplay'
        case arg
        when /(\d+)/
          if @displays[n = $1.to_i]
            if ask "clear \##{n} #{@displays[n]}?"
              @displays.delete_at n
            end
          end
          @tc << [:eval, :display, @displays]
        when nil
          if ask "clear all?", 'N'
            @displays.clear
          end
        end
        return :retry

      # trace
      when 'trace'
        case arg
        when 'on'
          @tracer ||= TracePoint.new(){|tp|
            next if tp.path == __FILE__
            next if tp.path == '<internal:trace_point>'
            # next if tp.event != :line
            @ui.puts pretty_tp(tp)
          }
          @tracer.enable
        when 'off'
          @tracer && @tracer.disable
        else
          enabled = (@tracer && @tracer.enabled?) ? true : false
          @ui.puts "Trace #{enabled ? 'on' : 'off'}"
        end
        return :retry

      # threads
      when 'th', 'thread'
        case arg
        when nil, 'list', 'l'
          thread_list
        when /(\d+)/
          thread_switch $1.to_i
        else
          @ui.puts "unknown thread command: #{arg}"
        end
        return :retry

      else
        @ui.puts "unknown command: #{line}"
        @repl_prev_line = nil
        return :retry
      end
    rescue Interrupt
      return :retry

    rescue Exception => e
      @ui.puts "[REPL ERROR] #{e.inspect}"
      @ui.puts e.backtrace.map{|e| '  ' + e}
      return :retry
    end

    def ask msg, default = 'Y'
      opts = '[y/n]'.tr(default.downcase, default)
      input = @ui.ask("#{msg} #{opts} ")
      input = default if input.empty?
      case input
      when 'y', 'Y'
        true
      else
        false
      end
    end

    def msig klass, receiver
      if klass.singleton_class?
        "#{receiver}."
      else
        "#{klass}#"
      end
    end

    def pretty_tp tp
      loc = "#{tp.path}:#{tp.lineno}"
      level = caller.size

      info =
      case tp.event
      when :line
        "line at #{loc}"
      when :call, :c_call
        klass = tp.defined_class
        "#{tp.event} #{msig(klass, tp.self)}#{tp.method_id} at #{loc}"
      when :return, :c_return
        klass = tp.defined_class
        "#{tp.event} #{msig(klass, tp.self)}#{tp.method_id} => #{tp.return_value.inspect} at #{loc}"
      when :b_call
        "b_call at #{loc}"
      when :b_return
        "b_return => #{tp.return_value} at #{loc}"
      when :class
        "class #{tp.self} at #{loc}"
      when :end
        "class #{tp.self} end at #{loc}"
      else
        "#{tp.event} at #{loc}"
      end

      case tp.event
      when :call, :b_call, :return, :b_return, :class, :end
        level -= 1
      end

      "Tracing:#{' ' * level} #{info}"
    rescue => e
      p e
      pp e.backtrace
      exit!
    end

    def show_bps specified_bp = nil
      @bps.each_with_index{|(key, bp), i|
        if !specified_bp || bp == specified_bp
          @ui.puts "#%d %s" % [i, bp.to_s]
        end
      }
    end

    def thread_list
      thcs, unmanaged_ths = update_thread_list
      thcs.each_with_index{|thc, i|
        @ui.puts "#{@tc == thc ? "--> " : "    "}\##{i} #{thc}"
      }

      if !unmanaged_ths.empty?
        @ui.puts "The following threads are not managed yet by the debugger:"
        unmanaged_ths.each{|th|
          @ui.puts "     " + th.to_s
        }
      end
    end

    def thread_switch n
      if th = @th_clients.keys[n]
        @tc = @th_clients[th]
      end
      thread_list
    end

    def update_thread_list
      list = Thread.list
      thcs = []
      unmanaged = []

      list.each{|th|
        case
        when th == Thread.current
          # ignore
        when @th_clients.has_key?(th)
          thcs << @th_clients[th]
        else
          unmanaged << th
        end
      }
      return thcs, unmanaged
    end

    def delete_breakpoint arg = nil
      case arg
      when nil
        @bps.each{|key, bp| bp.disable}
        @bps.clear
      else
        if bp = @bps[key = @bps.keys[arg]]
          bp.disable
          @bps.delete key
          return [arg, bp]
        end
      end
    end

    def repl_add_breakpoint arg
      arg.strip!

      if /(.+?)\s+if\s+(.+)\z/ =~ arg
        sig = $1
        cond = $2
      else
        sig = arg
      end

      case sig
      when /\A(\d+)\z/
        add_line_breakpoint @tc.location.path, $1.to_i, cond
      when /\A(.+):(\d+)\z/
        path = File.expand_path
        add_line_breakpoint $1, $2.to_i, cond
      when /\A(.+)[\.\#](.+)\z/
        add_method_breakpoint arg, cond
      else
        raise "unknown breakpoint format: #{arg}"
      end
    end

    def break? file, line
      @bps.has_key? [file, line]
    end

    def setup_threads
      stop_all_threads do
        Thread.list.each{|th|
          @th_clients[th] = ThreadClient.new(@q_evt, Queue.new, th)
        }
      end
    end

    def thread_client
      thr = Thread.current
      @th_clients[thr] ||= ThreadClient.new(@q_evt, Queue.new)
    end

    def stop_all_threads
      current = Thread.current

      if Thread.list.size > 1
        TracePoint.new(:line) do
          th = Thread.current
          if current == th || @management_threads.include?(th)
            next
          else
            tc = ThreadClient.current
            tc.on_pause
          end
        end.enable do
          yield
        ensure
          @th_clients.each{|thr, tc|
            case thr
            when current, (@tc && @tc.thread)
              next
            else
              tc << :continue if thr != Thread.current
            end
          }
        end
      else
        yield
      end
    end

    ## event 

    def on_load iseq, src
      @sr.add iseq, src
      @reserved_bps.each{|(path, line, cond)|
        if path == iseq.absolute_path
          bp = add_line_breakpoint(path, line, cond)
        end
      }
    end

    # configuration

    def add_catch_breakpoint arg
      bp = CatchBreakpoint.new(arg)
      @bps[bp.key] = bp
      bp
    end

    def add_line_breakpoint_exact iseq, events, file, line, cond
      if @bps[[file, line]]
        return nil # duplicated
      end

      bp = case
        when events.include?(:RUBY_EVENT_CALL)
          # "def foo" line set bp on the beggining of method foo
          LineBreakpoint.new(:call, iseq, line, cond)
        when events.include?(:RUBY_EVENT_LINE)
          LineBreakpoint.new(:line, iseq, line, cond)
        when events.include?(:RUBY_EVENT_RETURN)
          LineBreakpoint.new(:return, iseq, line, cond)
        when events.include?(:RUBY_EVENT_B_RETURN)
          LineBreakpoint.new(:b_return, iseq, line, cond)
        when events.include?(:RUBY_EVENT_END)
          LineBreakpoint.new(:end, iseq, line, cond)
        else
          nil
        end
      @bps[bp.key] = bp if bp
    end

    NearestISeq = Struct.new(:iseq, :line, :events)

    def add_line_breakpoint_nearest file, line, cond
      nearest = nil # NearestISeq

      ObjectSpace.each_iseq{|iseq|
        if iseq.absolute_path == file && iseq.first_lineno <= line
          iseq.traceable_lines_norec(line_events = {})
          lines = line_events.keys.sort

          if !lines.empty? && lines.last >= line
            nline = lines.bsearch{|l| line <= l}
            events = line_events[nline]

            if !nearest
              nearest = NearestISeq.new(iseq, nline, events)
            else
              if nearest.iseq.first_lineno <= iseq.first_lineno
                if (nearest.line > line && !nearest.events.include?(:RUBY_EVENT_CALL)) ||
                  events.include?(:RUBY_EVENT_CALL)
                  nearest = NearestISeq.new(iseq, nline, events)
                end
              end
            end
          end
        end
      }

      if nearest
        add_line_breakpoint_exact nearest.iseq, nearest.events, file, nearest.line, cond
      else
        return nil
      end
    end

    def resolve_path file
      File.realpath(File.expand_path(file))
    rescue Errno::ENOENT
      file
    end

    def add_line_breakpoint file, line, cond = nil
      file = resolve_path(file)
      bp = add_line_breakpoint_nearest file, line, cond
      @reserved_bps << [file, line, cond] unless bp
      bp
    end

    def add_method_breakpoint signature
      raise
    end
  end

  def self.add_line_breakpoint file, line, if: if_not_given =  true
    ::DEBUGGER__::SESSION.add_line_breakpoint file, line, if_not_given ? nil : binding.local_variable_get(:if)
  end

  def self.add_catch_breakpoint pat
    ::DEBUGGER__::SESSION.add_catch_breakpoint pat
  end
end
