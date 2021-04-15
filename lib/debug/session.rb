require 'json'
require 'pp'
require 'debug_inspector'
require 'iseq_collector'

require_relative 'source_repository'
require_relative 'breakpoint'
require_relative 'thread_client'
require_relative 'config'

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
      @tc = nil
      @initial_commands = []

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
            case ev_args.first
            when :breakpoint
              bp, i = bp_index ev_args[1]
              if bp
                @ui.puts "\nStop by \##{i} #{bp}"
              end
            when :trap
              @ui.puts ''
              @ui.puts "\nStop by #{ev_args[1]}"
            end

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
      @management_threads << @ui.reader_thread if @ui.respond_to? :reader_thread

      setup_threads
    end

    def add_initial_commands cmds
      cmds.each{|c|
        c.gsub('#.*', '').strip!
        @initial_commands << c unless c.empty?
      }
    end

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
      if @initial_commands.empty?
        line = @ui.readline
      else
        line = @initial_commands.shift.strip
      end

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
      ### Control flow

      # * `s[tep]`
      #   * Step in. Resume the program until next breakable point.
      when 's', 'step'
        @tc << [:step, :in]

      # * `n[ext]`
      #   * Step over. Resume the program until next line.
      when 'n', 'next'
        @tc << [:step, :next]

      # * `fin[ish]`
      #   * Finish this frame. Resume the program until the current frame is finished.
      when 'fin', 'finish'
        @tc << [:step, :finish]

      # * `c[ontinue]`
      #   * Resume the program.
      when 'c', 'continue'
        @tc << :continue

      # * `q[uit]` or exit or `Ctrl-D`
      #   * Finish debugger (with the debuggee process on non-remote debugging).
      when 'q', 'quit', 'exit'
        if ask 'Really quit?'
          @ui.quit arg.to_i
          @tc << :continue
        else
          return :retry
        end

      # * `kill` or q[uit]!`
      #   * Stop the debuggee process.
      when 'kill', 'quit!', 'q!'
        if ask 'Really kill?'
          exit! (arg || 1).to_i
        else
          return :retry
        end

      ### Breakpoint

      # * `b[reak]`
      #   * Show all breakpoints.
      # * `b[reak] <line>`
      #   * Set breakpoint on `<line>` at the current frame's file.
      # * `b[reak] <file>:<line>`
      #   * Set breakpoint on `<file>:<line>`.
      # * `b[reak] ... if <expr>`
      #   * break if `<expr>` is true at specified location.
      # * `b[reak] if <expr>`
      #   * break if `<expr>` is true at any lines.
      #   * Note that this feature is super slow.
      when 'b', 'break'
        if arg == nil
          show_bps
        else
          bp = repl_add_breakpoint arg
          show_bps bp if bp
        end
        return :retry

      # skip
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

        vimsrc = File.join(__dir__, 'bp.vim')
        system("vim -R -S #{vimsrc} #{@tc.location.path}")

        if File.exist?(".rdb_breakpoints.json")
          pp JSON.load(File.read(".rdb_breakpoints.json"))
        end

        return :retry

      # * `catch <Error>`
      #   * Set breakpoint on raising `<Error>`.
      when 'catch'
        if arg
          bp = add_catch_breakpoint arg
          show_bps bp if bp
        else
          show_bps
        end
        return :retry

      # * `del[ete]`
      #   * delete all breakpoints.
      # * `del[ete] <bpnum>`
      #   * delete specified breakpoint.
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

      ### Information

      # * `bt` or `backtrace`
      #   * Show backtrace (frame) information.
      when 'bt', 'backtrace'
        @tc << [:show, :backtrace]

      # * `list`
      #   * Show current frame's source code.
      when 'list'
        @tc << [:show, :list]

      # * `i[nfo]`
      #   * Show information about the current frame (local variables)
      #   * It includes `self` as `%self` and a return value as `%return`.
      # * `i[nfo] <expr>`
      #   * Show information about the result of <expr>.
      when 'i', 'info'
        case arg
        when nil
          @tc << [:show, :local]
        else
          @tc << [:show, :object_info, arg]
        end

      # * `display`
      #   * Show display setting.
      # * `display <expr>`
      #   * Show the result of `<expr>` at every suspended timing.
      when 'display'
        @displays << arg if arg && !arg.empty?
        @tc << [:eval, :display, @displays]

      # * `undisplay`
      #   * Remove all display settings.
      # * `undisplay <displaynum>`
      #   * Remove a specified display setting.
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

      # * `trace [on|off]`
      #   * enable or disable line tracer.
      when 'trace'
        case arg
        when 'on'
          dir = __dir__
          @tracer ||= TracePoint.new(){|tp|
            next if File.dirname(tp.path) == dir
            next if tp.path == '<internal:trace_point>'
            # next if tp.event != :line
            @ui.puts pretty_tp(tp)
          }
          @tracer.enable
        when 'off'
          @tracer && @tracer.disable
        end
        enabled = (@tracer && @tracer.enabled?) ? true : false
        @ui.puts "Trace #{enabled ? 'on' : 'off'}"
        return :retry

      ### Frame control

      # * `f[rame]`
      #   * Show current frame.
      # * `f[rame] <framenum>`
      #   * Specify frame. Evaluation are run on this frame environement.
      when 'frame', 'f'
        @tc << [:frame, :set, arg]

      # * `up`
      #   * Specify upper frame.
      when 'up'
        @tc << [:frame, :up]

      # * `down`
      #   * Specify down frame.
      when 'down'
        @tc << [:frame, :down]

      ### Evaluate

      # * `p <expr>`
      #   * Evaluate like `p <expr>` on the current frame.
      when 'p'
        @tc << [:eval, :p, arg.to_s]

      # * `pp <expr>`
      #   * Evaluate like `pp <expr>` on the current frame.
      when 'pp'
        @tc << [:eval, :pp, arg.to_s]

      # * `e[val] <expr>`
      #   * Evaluate `<expr>` on the current frame.
      when 'e', 'eval', 'call'
        @tc << [:eval, :call, arg]

      # skip
      when 'irb'
        @tc << [:eval, :call, 'binding.irb']

      ### Thread control

      # * `th[read]`
      #   * Show all threads.
      # * `th[read] <thnum>`
      #   * Switch thread specified by `<thnum>`.
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

      ### Help

      # * `h[elp]`
      #   * Show help for all commands.
      # * `h[elp] <command>`
      #   * Show help for the given command.
      when 'h', 'help'
        if arg
          DEBUGGER__.helps.each{|cat, cs|
            cs.each{|ws, desc|
              if ws.include? arg
                @ui.puts desc
                return :retry
              end
            }
          }
          @ui.puts "not found: #{arg}"
        else
          @ui.puts DEBUGGER__.help
        end
        return :retry

      ### END
      else
        @ui.puts "unknown command: #{line}"
        @repl_prev_line = nil
        return :retry
      end

    rescue Interrupt
      return :retry
    rescue SystemExit
      raise
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

    def iterate_bps
      disabled_bps = []
      i = 0
      @bps.each{|key, bp|
        if bp.enabled?
          yield key, bp, i
          i += 1
        else
          disabled_bps << bp
        end
      }
    ensure
      disabled_bps.each{|bp| @bps.delete bp}
    end

    def show_bps specific_bp = nil
      iterate_bps do |key, bp, i|
        @ui.puts "#%d %s" % [i, bp.to_s] if !specific_bp || bp == specific_bp
      end
    end

    def bp_index specific_bp_key
      iterate_bps do |key, bp, i|
        if key == specific_bp_key
          return [bp, i]
        end
      end
      nil
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
        del_bp = nil
        iterate_bps{|key, bp, i| del_bp = bp if i == arg}
        if del_bp
          del_bp.disable
          @bps.delete del_bp.key
          return [arg, del_bp]
        end
      end
    end

    def repl_add_breakpoint arg
      arg.strip!

      case arg
      when /\Aif\s+(.+)\z/
        cond = $1
      when /(.+?)\s+if\s+(.+)\z/
        sig = $1
        cond = $2
      else
        sig = arg
      end

      case sig
      when /\A(\d+)\z/
        add_line_breakpoint @tc.location.path, $1.to_i, cond
      when /\A(.+):(\d+)\z/
        add_line_breakpoint $1, $2.to_i, cond
      when /\A(.+)[\.\#](.+)\z/
        add_method_breakpoint arg, cond
      when nil
        add_check_breakpoint cond
      else
        raise "unknown breakpoint format: #{arg}"
      end
    end

    def add_check_breakpoint expr
      bp = CheckBreakpoint.new(expr)
      @bps[bp.key] = bp
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
      founds = []
      @reserved_bps.each_with_index{|rbp, i|
        (path, line, cond, oneshot) = rbp

        if path == (iseq.absolute_path || iseq.path)
          founds << rbp
          unless add_line_breakpoint(path, line, cond, oneshot: oneshot, reserve: false)
            next
          end
        end
      }
      founds.each{|rbp|
        @reserved_bps.delete rbp
      }
    end

    # configuration

    def add_catch_breakpoint arg
      bp = CatchBreakpoint.new(arg)
      @bps[bp.key] = bp
      bp
    end

    def add_line_breakpoint_exact iseq, events, file, line, cond, oneshot
      if @bps[[file, line]]
        return nil # duplicated
      end

      bp = case
        when events.include?(:RUBY_EVENT_CALL)
          # "def foo" line set bp on the beggining of method foo
          LineBreakpoint.new(:call, iseq, line, cond, oneshot: oneshot)
        when events.include?(:RUBY_EVENT_LINE)
          LineBreakpoint.new(:line, iseq, line, cond, oneshot: oneshot)
        when events.include?(:RUBY_EVENT_RETURN)
          LineBreakpoint.new(:return, iseq, line, cond, oneshot: oneshot)
        when events.include?(:RUBY_EVENT_B_RETURN)
          LineBreakpoint.new(:b_return, iseq, line, cond, oneshot: oneshot)
        when events.include?(:RUBY_EVENT_END)
          LineBreakpoint.new(:end, iseq, line, cond, oneshot: oneshot)
        else
          nil
        end
      @bps[bp.key] = bp if bp
    end

    NearestISeq = Struct.new(:iseq, :line, :events)

    def add_line_breakpoint_nearest file, line, cond, oneshot
      nearest = nil # NearestISeq

      ObjectSpace.each_iseq{|iseq|
        if (iseq.absolute_path || iseq.path) == file && iseq.first_lineno <= line
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
        add_line_breakpoint_exact nearest.iseq, nearest.events, file, nearest.line, cond, oneshot
      else
        return nil
      end
    end

    def resolve_path file
      File.realpath(File.expand_path(file))
    rescue Errno::ENOENT
      file
    end

    def add_line_breakpoint file, line, cond = nil, oneshot: false, reserve: true
      file = resolve_path(file)
      bp = add_line_breakpoint_nearest file, line, cond, oneshot
      if !bp && reserve
        @reserved_bps << [file, line, cond, oneshot]
      end
      bp
    end

    def add_method_breakpoint signature
      raise
    end
  end

  # String for requring location
  # nil for -r
  def self.require_location
    locs = caller_locations
    dir_prefix = /#{__dir__}/

    locs.each do |loc|
      case loc.absolute_path
      when dir_prefix
      when %r{rubygems/core_ext/kernel_require\.rb}
      else
        return loc
      end
    end
    nil
  end

  def self.console
    initialize_session UI_Console.new

    @prev_handler = trap(:SIGINT){
      ThreadClient.current.on_trap :SIGINT
    }
  end

  def self.add_line_breakpoint file, line, if: if_not_given =  true, oneshot: true
    ::DEBUGGER__::SESSION.add_line_breakpoint file, line, if_not_given ? nil : binding.local_variable_get(:if), oneshot: true
  end

  def self.add_catch_breakpoint pat
    ::DEBUGGER__::SESSION.add_catch_breakpoint pat
  end

  class << self
    define_method :initialize_session do |ui|
      ::DEBUGGER__.const_set(:SESSION, Session.new(ui))

      # default breakpoints

      # ::DEBUGGER__.add_catch_breakpoint 'RuntimeError'

      Binding.module_eval do
        ::DEBUGGER__.add_line_breakpoint __FILE__, __LINE__ + 1
        def bp; nil; end
      end

      if ::DEBUGGER__::CONFIG[:nonstop] != '1'
        if loc = ::DEBUGGER__.require_location
          # require 'debug/console' or 'debug'
          add_line_breakpoint loc.absolute_path, loc.lineno + 1, oneshot: true
        else
          # -r
          add_line_breakpoint $0, 1, oneshot: true
        end
      end

      load_rc
    end
  end

  def self.load_rc
    ['./rdbgrc.rb', File.expand_path('~/.rdbgrc.rb')].each{|path|
      if File.file? path
        load path
      end
    }

    # debug commands file
    [::DEBUGGER__::CONFIG[:init_script],
     './.rdbgrc',
     File.expand_path('~/.rdbgrc')].each{|path|
      next unless path

      if File.file? path
        ::DEBUGGER__::SESSION.add_initial_commands File.readlines(path)
      end
    }

    # given debug commands
    if ::DEBUGGER__::CONFIG[:commands]
      cmds = ::DEBUGGER__::CONFIG[:commands].split(';;')
      ::DEBUGGER__::SESSION.add_initial_commands cmds
    end
  end

  def self.parse_help
    helps = Hash.new{|h, k| h[k] = []}
    desc = cat = nil
    File.read(__FILE__).each_line do |line|
      case line
      when /\A\s*### (.+)/
        cat = $1
        break if $1 == 'END'
      when /\A      when (.+)/
        next unless cat
        next unless desc
        ws = $1.split(/,\s*/).map{|e| e.gsub('\'', '')}
        helps[cat] << [ws, desc]
        desc = nil
      when /\A\s+# (\s*\*.+)/
        if desc
          desc << "\n" + $1
        else
          desc = $1
        end
      end
    end
    @helps = helps
  end

  def self.helps
    (defined?(@helps) && @helps) || parse_help
  end

  def self.help
    r = []
    self.helps.each{|cat, cmds|
      r << "### #{cat}"
      r << ''
      cmds.each{|ws, desc|
        r << desc
      }
      r << ''
    }
    r.join("\n")
  end

  CONFIG = ::DEBUGGER__.parse_argv(ENV['RUBY_DEBUG_OPT'])
end
