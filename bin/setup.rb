# morgan.sziraki@gmail.com
# Mon 18 Jan 2021 07:35:39 GMT

require 'optparse'
require 'ostruct'

class Setup
  def initialize(options)
    @number = options.number
  end

  def print
    puts "Number is #{@number}"
  end
end


# if running as a script
if __FILE__ == $0
  options = OpenStruct.new

  OptionParser.new do |opts|
    opts.banner = "Usage: SCRIPT_NMAE [options]"
    opts.on('-v', '--version', 'an int') { |o| options.number = o }
    opts.on('install', 'an int') { |o| options.number = o }
    opts.on_tail('-h', '--help') {
      puts opts
      exit
    }
  end.parse!


  obj = Setup.new(options)
  obj.print
end

