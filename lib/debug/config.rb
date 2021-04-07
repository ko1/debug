module DEBUGGER__
  def self.unix_domain_socket_basedir
    case
    when path = ENV['RUBY_DEBUG_SOCK_DIR']
    when path = ENV['XDG_RUNTIME_DIR']
    when home = ENV['HOME']
      path = File.join(home, '.ruby-debug-sock')
      unless File.exist?(path)
        Dir.mkdir(path, 0700)
      end
    else
      raise 'specify RUBY_DEBUG_SOCK_DIR environment variable for UNIX domain socket directory.'
    end

    path
  end

  def self.create_unix_domain_socket_name_prefix
    user = ENV['USER'] || 'ruby-debug'
    File.join(unix_domain_socket_basedir, "ruby-debug-#{user}")
  end

  def self.create_unix_domain_socket_name
    create_unix_domain_socket_name_prefix + "-#{Process.pid}"
  end
end
