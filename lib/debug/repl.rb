require_relative 'session'

module DEBUGGER__
  class UI_Repl
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
      def readline
        setup_interrupt do
          str = Readline.readline("\n(rdb) ", true)
          (str || 'quit').strip
        end
      end
    rescue LoadError
      def readline
        setup_interrupt do
          print "\n(rdb) "
          (gets || 'quit').strip
        end
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

  initialize_session UI_Repl.new

  PREV_HANDLER = trap(:SIGINT){
    ThreadClient.current.on_trap
  }

  DEBUGGER__.add_line_breakpoint $0, 1
end
