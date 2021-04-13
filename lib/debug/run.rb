require_relative 'console'

module DEBUGGER__
  initialize_session UI_Console.new

  PREV_HANDLER = trap(:SIGINT){
    ThreadClient.current.on_trap :SIGINT
  }

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

  if loc = DEBUGGER__.require_location
    # require 'debug/console' or 'debug'
    add_line_breakpoint loc.absolute_path, loc.lineno + 1, oneshot: true
  else
    # -r
    add_line_breakpoint $0, 1, oneshot: true
  end
end
