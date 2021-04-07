require 'socket'
require_relative 'session'

module DEBUGGER__
  class UI_Server
    def initialize
      @sock = nil
      @client_addr = nil
      @q_msg = Queue.new
      @q_ans = Queue.new

      @reader_thread = Thread.new do
        accept do |server|
          @sock = server
          @q_msg = Queue.new
          @q_ans = Queue.new

          setup_interrupt do
            pause

            begin
              while line = @sock.gets
                case line
                when /\Apause/
                  pause
                when /\Acommand ?(.+)/
                  @q_msg << $1
                when /\Aanswer (.*)/
                  @q_ans << $1
                else
                  STDERR.puts "unsupported: #{line}"
                  exit!
                end
              end
            end
          end
        ensure
          @sock = nil
          @q_msg.close
          @q_ans.close
        end
      end
    end


    def setup_interrupt
      prev_handler = trap(:SIGINT) do
        # $stderr.puts "trapped SIGINT"
        ThreadClient.current.on_trap

        case prev_handler
        when Proc
          prev_handler.call
        else
          # ignore
        end
      end

      yield
    ensure
      trap(:SIGINT, prev_handler)
    end

    def accept
      raise "NOT IMPLEMENTED ERROR"
    end

    attr_reader :reader_thread

    class NoRemoteError < Exception; end

    def sock
      yield @sock if @sock
    rescue Errno::EPIPE
      # ignore
    end

    def ask prompt
      sock do |s|
        s.puts "ask #{prompt}"
        @q_ans.pop
      end
    end

    def puts str
      case str
      when Array
        enum = str.each
      when String
        enum = str.each_line
      end

      sock do |s|
        enum.each do |line|
          s.puts "out #{line.chomp}"
        end
      end
    end

    def readline
      (sock do |s|
        s.puts "input"
        @q_msg.pop
      end || 'continue').strip
    end

    def pause
      # $stderr.puts "DEBUG: pause request"
      Process.kill(:SIGINT, Process.pid)
    end

    def quit n
      # ignore n
      sock do |s|
        s.puts "quit"
      end
    end
  end
end
