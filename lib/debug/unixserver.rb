require_relative 'server'
require_relative 'config'

module DEBUGGER__
  class UI_UnixDomainServer < UI_Server
    def accept
      @file = DEBUGGER__.create_unix_domain_socket_name

      $stderr.puts "Debugger can attach via UNIX domain socket (#{@file})"
      Socket.unix_server_loop @file do |sock, addr|
        @client_addr = addr
        yield sock
      end
    end
  end

  initialize_session UI_UnixDomainServer.new
end
