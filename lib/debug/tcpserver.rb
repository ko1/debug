require 'socket'
require_relative 'server'

module DEBUGGER__
  class UI_TcpServer < UI_Server
    def accept
      host = ENV[''] || 'localhost'
      port = ENV['RUBY_DEBUG_PORT']   || raise("Specify listening port by RUBY_DEBUG_PORT environment variable.")
      port = port.to_i.tap{|i| i != 0 || raise("Specify valid port number (#{port} is specified)")}

      $stderr.puts "Debugger can attach via TCP/IP (#{host}:#{port})"
      Socket.tcp_server_loop(host, port) do |sock, client|
        yield sock
      end
    rescue => e
      $stderr.puts e.message
      exit
    end
  end

  initialize_session UI_TcpServer.new
end
