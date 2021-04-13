require 'socket'
require_relative 'session'
require_relative 'config'

module DEBUGGER__
  class UI_ServerBase
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
        ThreadClient.current.on_trap :SIGINT

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

    def puts str = nil
      case str
      when Array
        enum = str.each
      when String
        enum = str.each_line
      when nil
        enum = [''].each
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

  class UI_TcpServer < UI_ServerBase
    def initialize host: nil, port: nil
      @host = host || ENV['RUBY_DEBUG_HOST'] || 'localhost'
      @port = port || begin
        port_str = ENV['RUBY_DEBUG_PORT'] || raise("Specify listening port by RUBY_DEBUG_PORT environment variable.")
        if /\A\d+\z/ !~ port_str
          raise "Specify digits for port number"
        else
          port_str.to_i
        end
      end

      super()
    end

    def accept
      Socket.tcp_server_sockets @host, @port do |socks|
        $stderr.puts "Debugger can attach via TCP/IP (#{socks.map{|e| e.local_address.inspect}})"

        Socket.accept_loop(socks) do |sock, client|
          yield sock
        end
      end
    rescue => e
      $stderr.puts e.message
      pp e.backtrace
      exit
    end
  end

  class UI_UnixDomainServer < UI_ServerBase
    def initialize base_dir: nil
      @base_dir = base_dir || DEBUGGER__.unix_domain_socket_basedir

      super()
    end

    def accept
      @file = DEBUGGER__.create_unix_domain_socket_name(@base_dir)

      $stderr.puts "Debugger can attach via UNIX domain socket (#{@file})"
      Socket.unix_server_loop @file do |sock, addr|
        @client_addr = addr
        yield sock
      end
    end
  end

  def self.open host: nil, port: ENV['RUBY_DEBUG_PORT'], base_dir: nil
    if port
      open_tcp host: host, port: port
    else
      open_unix base_dir: base_dir
    end
  end

  def self.open_tcp(host: nil, port:)
    initialize_session UI_TcpServer.new(host: host, port: port)
  end

  def self.open_unix base_dir: nil
    initialize_session UI_UnixDomainServer.new(base_dir: base_dir)
  end
end
