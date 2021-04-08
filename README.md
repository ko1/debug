# debug.rb

debug.rb is replacement of traditional lib/debug.rb standard library which is implemented by `set_trace_func`.
New debug.rb has several advantages:

* Fast: No performance penalty on non-stepping mode and non-breakpoints.
* Remote debugging: Support remote debugging natively.
  * UNIX domain socket
  * TCP/IP
  * VSCode/DAP integration (TODO)
* Extensible: application can introduce debugging support with several methods
  * By `rdbg` command
  * By loading libraries with `-r` command line option
  * By calling Ruby's method explicitly

# How to install

```
$ gem install debug --pre
```

or specify `-Ipath/to/debug/lib` in `RUBYOPT` or each ruby command-line options, especially for debug lib development.

# How to use

## Invoke with debugger

You can run ruby program on debugger on the console or remote access.

* (a) Run a ruby program on the debug console
* (b) Run a ruby program with opning debug port
  * (b-1) Open with UNIX domain socket
  * (b-2) Open with TCP/IP port

(b) is useful when you want to use debugging features after running the program.
(b-2) is also useful when you don't have a ssh access for the Ruby process.

To use debugging feature, you can have 3 ways.

* (1) Use `rdbg` command
* (2) Use `-r debug...` command line option
* (3) Write `require 'debug...'` in .rb files

### Console debug

```
# (1) Use `rdbg` command
$ rdbg target.rb
$ rdbg -- -r foo -e expr # -- is required to make clear rdbg options and ruby's options

# (2) Use `-r debug/console` command line option

$ ruby -r debug/console target.rb

# (3) Write `require 'debug...' in .rb files

$ cat target.rb
require 'debug/console' # start the debug console
...

# or

$ cat target.rb
require 'debug/session'  # introduce the functionality
DEBUGGER__.console       # and start the debug console

$ ruby target.rb
```

When you run the program with the debug console, you will see the debug console prompt `(rdbg)`.
The debuggee program (`target.rb`) is suspended at the beggining of `target.rb`.

You can type any debugger's command described bellow. "c" or "continue" resume the debuggee program.
You can suspend the debuggee program and show the debug console with `Ctrl-C`.

The following example shows simple usage of the debug console. You can show the all variables

```
$ rdbg  ~/src/rb/target.rb

[1, 5] in /home/ko1/src/rb/target.rb
=>    1| a = 1
      2| b = 2
      3| c = 3
      4| p [a + b + c]
      5|
--> #0  /home/ko1/src/rb/target.rb:1:in `<main>'

(rdbg) info locals                                      # Show all local variables
 %self => main
 a => nil
 b => nil
 c => nil

(rdbg) p a
=> nil

(rdbg) s                                                # Step in ("s" is a short name of "step")

[1, 5] in /home/ko1/src/rb/target.rb
      1| a = 1
=>    2| b = 2
      3| c = 3
      4| p [a + b + c]
      5|
--> #0  /home/ko1/src/rb/target.rb:2:in `<main>'

(rdbg)                                                  # Repeat the last command ("step")

[1, 5] in /home/ko1/src/rb/target.rb
      1| a = 1
      2| b = 2
=>    3| c = 3
      4| p [a + b + c]
      5|
--> #0  /home/ko1/src/rb/target.rb:3:in `<main>'

(rdbg)                                                  # Repeat the last command ("step")

[1, 5] in /home/ko1/src/rb/target.rb
      1| a = 1
      2| b = 2
      3| c = 3
=>    4| p [a + b + c]
      5|
--> #0  /home/ko1/src/rb/target.rb:4:in `<main>'

(rdbg) info locals                                      # Show all local variables
 %self => main
 a => 1
 b => 2
 c => 3

(rdbg) c                                                # Contineu the program ("c" is a short name of "continue")
[6]
```

### Remote debug (1) UNIX domain socket

```
# (1) Use `rdbg` command
$ rdbg -R target.rb
Debugger can attach via UNIX domain socket (/home/ko1/.ruby-debug-sock/ruby-debug-ko1-5042)
...

# (2) Use `-r debug/open` command line option

$ ruby -r debug/open target.rb
Debugger can attach via UNIX domain socket (/home/ko1/.ruby-debug-sock/ruby-debug-ko1-5042)
...

# (3) Write `require 'debug/open' in .rb files
$ cat target.rb
require 'debug/open' # open the debugger entry point by UNIX domain socket.
...

# or

$ cat target.rb
require 'debug/server' # introduce remote debugging feature
DEBUGGER__.open        # open the debugger entry point by UNIX domain socket.
# or DEBUGGER__.open_unix to specify UNIX domain socket.

$ ruby target.rb
Debugger can attach via UNIX domain socket (/home/ko1/.ruby-debug-sock/ruby-debug-ko1-5042)
...
```

It runs target.rb and accept debugger connection within UNIX domain socket.

You can attach the program with the following command:

```
$ rdbg --attach

[1, 4] in /home/ko1/src/rb/target.rb
      1| (1..).each do |i|
=>    2|   sleep 0.5
      3|   p i
      4| end
--> #0  [C] /home/ko1/src/rb/target.rb:2:in `sleep'
    #1  /home/ko1/src/rb/target.rb:2:in `block in <main>' {|i=17|}
    #2  [C] /home/ko1/src/rb/target.rb:1:in `each'
    # and 1 frames (use `bt' command for all frames)
```

The debugee process will be suspended and wait for the debug command from the remote debugger.

If you are running multiple debuggee processes, this command shows the selection like that:

```
$ rdbg --attach
Please select a debug session:
  ruby-debug-ko1-19638
  ruby-debug-ko1-19603
```

and you need to specify one (copy and paste the name):

```
$ rdbg --attach ruby-debug-ko1-19638
```

The socket file is located at
* `RUBY_DEBUG_SOCK_DIR` environment variable if available.
* `XDG_RUNTIME_DIR` environment variable if available.
* `$HOME/ruby-debug-sock` if `$HOME` is available.

### Remote debug (2) TCP/IP

You can open the TCP/IP port instead of using UNIX domain socket.

```
# (1) Use `rdbg` command
$ rdbg -R --port=12345 target.rb
Debugger can attach via TCP/IP (localhost:12345)
...

# (2) Use `-r debug/open` command line option

$ RUBY_DEBUG_PORT=12345 ruby -r debug/open target.rb
Debugger can attach via TCP/IP (localhost:12345)
...

# (3) Write `require 'debug/open' in .rb files
$ cat target.rb
require 'debug/open' # open the debugger entry point by UNIX domain socket.
...

# and run with environment variable RUBY_DEBUG_PORT
$ RUBY_DEBUG_PORT=12345 ruby target.rb
Debugger can attach via TCP/IP (localhost:12345)
...

# or

$ cat target.rb
require 'debug/server' # introduce remote debugging feature
DEBUGGER__.open(port: 12345)
# or DEBUGGER__.open_tcp(port: 12345)

$ ruby target.rb
Debugger can attach via TCP/IP (localhost:12345)
...
```

You can also specify the host with `RUBY_DEBUG_HOST` environment variable. Also `DEBUGGER__.open` method accepts a `host:` keyword parameter. If the host is not given, `localhost` will be used.

To attach it, specify the port number (and hostname if needed).

```
$ rdbg --attach 12345
$ rdbg --attach hostname 12345
```

## Debug command on the debug console

* `Enter` repeats the last command (useful when repeating `step`s).
* `Ctrl-D` is equal to `quit` command.

### Control flow

* `s[tep]`
  * Step in. Resume the program until next breakable point.
* `n[ext]`
  * Step over. Resume the program until next line.
* `fin[ish]`
  * Finish this frame. Resume the program until the current frame is finished.
* `c[ontinue]`
  * Resume the program.
* `q[uit]` or `Ctrl-D`
  * Finish debugger (with the debuggee process on non-remote debugging).
* `kill`
  * Stop the debuggee process.

### Breakpoint

* `b[reak]`
  * Show all breakpoints.
* `b[reak] <line>`
  * Set breakpoint on `<line>` at the current frame's file.
* `b[reak] <file>:<line>`
  * Set breakpoint on `<file>:<line>`.
* `catch <Error>`
  * Set breakpoint on raising `<Error>`.
* `del[ete]`
  * delete all breakpoints.
* `del[ete] <bpnum>`
  * delete specified breakpoint.

### Frame control

* `bt` or `backtrace`
  * Show backtrace information.
* `f[rame]`
  * Show current frame.
* `f[rame] <framenum>`
  * Specify frame. Evaluation are run on this frame environement.
* `up`
  * Specify upper frame.
* `down`
  * Specify down frame.

### Evaluate

* `p <expr>`
  * Evaluate like `p <expr>` on the current frame.
* `pp <expr>`
  * Evaluate like `pp <expr>` on the current frame.
* `e[val] <expr>`
  * Evaluate `<expr>` on the current frame.

### Information

* `list`
  * Show current frame's source code.
* `info l[ocal[s]]`
  * Show current frame's local variables. It includes `self` as `%self` and a return value as `%return`.
* `info i[nstance]` or `info ivars`
  * Show current frame's insntance variables.
* `display`
  * Show display setting.
* `display <expr>`
  * Add `<expr>` at suspended timing.
* `undisplay`
  * Remove all display settings.
* `undisplay <displaynum>`
  * Remove a specified display setting.
* `trace [on|off]`
  * enable or disable line tracer.

### Thread control

* `th[read] [l[ist]]`
  * Show all threads.
* `th[read] <thnum>`
  * Switch thread specified by `<thnum>`

