require_relative 'session'

module DEBUGGER__
  class UI_Console
    def initialize
    end

    def quit n
      exit n
    end

    def ask prompt
      print prompt
      (gets || '').strip
    end

    def puts str
      case str
      when Array
        str.each{|line|
          $stdout.puts line.chomp
        }
      when String
        str.each_line{|line|
          $stdout.puts line.chomp
        }
      when nil
        $stdout.puts
      end
    end

    begin
      require 'readline'
      def readline_body
        Readline.readline("\n(rdbg) ", true)
      end
    rescue LoadError
      def readline_body
        print "\n(rdbg) "
        gets
      end
    end

    def readline
      setup_interrupt do
        (readline_body || 'quit').strip
      end
    end

    def setup_interrupt
      current_thread = Thread.current # should be session_server thread

      prev_handler = trap(:INT){
        current_thread.raise Interrupt
      }

      yield
    ensure
      trap(:INT, prev_handler)
    end
  end

  initialize_session UI_Console.new

  PREV_HANDLER = trap(:SIGINT){
    ThreadClient.current.on_trap
  }

  if (locs = caller_locations).all?{|loc| /require/ =~ loc.label}
    DEBUGGER__.add_line_breakpoint $0, 1
  else
    locs.each{|loc|
      if /require/ !~ loc.label
        add_line_breakpoint loc.absolute_path, loc.lineno + 1, oneshot: true
        break
      end
    }
  end
end
