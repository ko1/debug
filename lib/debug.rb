require_relative 'debug/repl'

# default break points
DEBUGGER__.add_catch_breakpoint 'RuntimeError'
class Binding
  DEBUGGER__.add_line_breakpoint __FILE__, __LINE__ + 1
  def bp; nil; end
end

if $0 == __FILE__
  # DEBUGGER__.add_line_breakpoint __dir__ + '/target.rb', 1
  # load __dir__ + '/target.rb'
else
  DEBUGGER__.add_line_breakpoint $0, 1
end
