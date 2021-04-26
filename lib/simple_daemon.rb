#!/usr/bin/env ruby
# == Simple Daemon
#
# A simple ruby daemon that you copy and change as needed.
# 
# === How does it work?
#
# All this program does is fork the current process (creates a copy of
# itself) then exits, the fork (child process) then goes on to run your
# daemon code. In this example we are just running a while loop with a
# 1 second sleep.
#
# Most of the code is dedicated to managing a pid file. We want a pid
# file so we can use a monitoring tool to make sure our daemon keeps
# running.
#
# === Why?
#
# Writing a daemon sounds hard but as you can see is not that
# complicated, so lets strip away the magic and just write some ruby.
#
# === Usage
#
# You can run this daemon by running:
#
#     $ ./simple_ruby_daemon.rb
#
# or with an optional pid file location as its first argument:
#
#     $ ./simple_ruby_daemon.rb tmp/simple_ruby_daemon.pid
#
# check that it is running by running the following:
#
#     $ ps aux | grep simple_ruby_daemon
#
# Author:: Rufus Post  (mailto:rufuspost@gmail.com)
class SimpleDaemon
  # Checks to see if the current process is the child process and if not
  # will update the pid file with the child pid.
  def self.start pid, pidfile, outfile, errfile
    unless pid.nil?
      raise "Fork failed" if pid == -1
      write pid, pidfile if kill pid, pidfile
      exit
    else
      redirect outfile, errfile
    end
  end

  # Attempts to write the pid of the forked process to the pid file.
  def self.write pid, pidfile
    File.open pidfile, "w" do |f|
      f.write pid
    end
  rescue ::Exception => e
    $stderr.puts "While writing the PID to file, unexpected #{e.class}: #{e}"
    Process.kill "HUP", pid
  end

  # Try and read the existing pid from the pid file and signal the
  # process. Returns true for a non blocking status.
  def self.kill(pid, pidfile)
    opid = open(pidfile).read.strip.to_i
    Process.kill "HUP", opid
    true
  rescue Errno::ENOENT
    $stdout.puts "#{pidfile} did not exist: Errno::ENOENT"
    true
  rescue Errno::ESRCH
    $stdout.puts "The process #{opid} did not exist: Errno::ESRCH"
    true
  rescue Errno::EPERM
    $stderr.puts "Lack of privileges to manage the process #{opid}: Errno::EPERM"
    false
  rescue ::Exception => e
    $stderr.puts "While signaling the PID, unexpected #{e.class}: #{e}"
    false
  end

  # Send stdout and stderr to log files for the child process
  def self.redirect outfile, errfile
    $stdin.reopen '/dev/null'
    out = File.new outfile, "a"
    err = File.new errfile, "a"
    $stdout.reopen out
    $stderr.reopen err
    $stdout.sync = $stderr.sync = true
  end
end

# Process name of your daemon
$0 = "simple ruby daemon"

# Spawn a deamon
SimpleDaemon.start fork, (ARGV[0] || '/tmp/deamon.pid'), (ARGV[1] || '/tmp/daemon.stdout.log'), (ARGV[2] || '/tmp/daemon.stderr.log')

# Set up signals for our daemon, for now they just exit the process.
Signal.trap("HUP") { $stdout.puts "SIGHUP and exit"; exit } # @TODO this should reread config
Signal.trap("INT") { $stdout.puts "SIGINT and exit"; exit }
Signal.trap("QUIT") { $stdout.puts "SIGQUIT and exit"; exit }

# Remove this loop and replace with your own daemon logic.
loop do
  sleep 1
end
# ----- https://gist.github.com/sbusso/1978385
