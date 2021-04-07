# debug.rb

## How to install

This is temporary installation guide until gemify.

```
$ git clone https://github.com/ko1/debug.git
$ gem install debug_inspector
$ gem install iseq_collector
$ export RUBYOPT=-I`pwd`/debug/lib
# or add "-I`pwd`/debug/lib" for the following command
```

# How to use

## Invoke with debugger

### REPL debug

```
$ ruby -r debug target.rb
```

and you can see the debugger prompt. The program was suspended at the beggining of target.rb. To continue the program, type `c` (or `continue`). See other debug commands below.

You can re-enable debug command mode by `Ctrl-C`.

### Remote debug (1) UNIX domain socket

```
$ ruby -r debug/unixserver target.rb
```

It runs target.rb and accept debugger connection within UNIX domain socket.

You can attach the program with the folliowing command:

```
$ ruby -r debug/client -e connect
Debugger can attach via UNIX domain socket (/home/ko1/.ruby-debug-sock/ruby-debug-ko1-20642)
...
```

The debugee process will be suspended and wait for the debug command.

If you are running multiple debuggee processes, this command shows the selection like that:

```
$ ruby -r debug/client -e connect
Please select a debug session:
  ruby-debug-ko1-19638
  ruby-debug-ko1-19603
```

and you need to specify one:

```
$ ruby -r debug/client -e connect ruby-debug-ko1-19638
```

The socket file is located at
* `RUBY_DEBUG_SOCK_DIR` environment variable if available.
* `XDG_RUNTIME_DIR` environment variable if available.
* `$HOME/ruby-debug-sock` if `$HOME` is available.

### Remote debug (2) TCP/IP

```
$ RUBY_DEBUG_PORT=12345 RUBY_DEBUG_HOST=localhost ruby -r debug/tcpserver target.rb
Debugger can attach via TCP/IP (localhost:12345)
...
```

This command invoke target.rb with TCP/IP attach server with given port and host. If host is not given, `localhost` will be used. 

```
$ ruby -r debug/client -e connect localhost 12345
```

tries to connect with given host (`localhost`) and port (`12345`). You can eliminate host part and `localhost` will be used.


## Debug command

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
  * Finish debugger (with a process, if not remote debugging).
* `kill`
  * Stop the debuggee program.

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

