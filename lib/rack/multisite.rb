require 'socket'
require 'rack'
require 'rack/utils'

module Rack
  class Multisite
    VERSION = '0.0.1'

    def initialize(options={}, &block)
      @map = {}
      instance_eval(&block)
      warn "Warning: No catch-all specified. Un-mapped domains will raise an exception" unless @map.has_key?('*') || @map.has_key?(/.*/)
      @parent_pid ||= Process.ppid
      @timeout = options[:timeout] || 300

      # Take advantage of Ruby EE's copy-on-write
      GC.copy_on_write_friendly = true if GC.respond_to?(:copy_on_write_friendly=)

      at_exit do
        if @parent_pid == Process.ppid
            @map.keys.each do |host|
            check_status(host)
            kill_process(host)
          end
        end
      end
    end

    def map(host, dir, opts={})
      @map[host] = {
        :name => (host.is_a?(Regexp) ? "/#{host.source}/" : host),
        :dir => dir,
        :rackup_file => opts[:rackup_file] || 'config.ru',
        :reload_file => File.join(dir, opts[:reload] || 'tmp/restart.txt'),
        :env => opts[:env] || {},
        :timeout => opts[:timeout] || @timeout,
        # The app may need a session secret
        # :secret => rand(2**256).to_s(36),
      }
      rackup_file = File.join(@map[host][:dir], @map[host][:rackup_file])
      raise "Cannot find rackup file #{rackup_file}" unless File.file?(rackup_file)
      warn "No reload file #{@map[host][:reload_file]}" unless File.file?(@map[host][:reload_file])
    end

    def call(env)
      server = env['SERVER_NAME']
      host = @map.has_key?(server) ? server : @map.keys.find{ |k| k.is_a?(Regexp) && k =~ server }
      host = '*' if !host && @map.has_key?('*')

      raise "Could not find server for #{server}" unless host

      check_status(host)

      if needs_reload?(host)
        kill_process(host)
        start_process(host)
      end

      socket = @map[host][:socket]

      sane = Hash[env.select{ |k,v| [String, Hash, Array].include?(v.class) }]

      sane['rack.input'] = env['rack.input'].read
      send_marshal(socket, sane)
      stat, *recv = recv_marshal(socket)
      body = Body.new(socket)
      case stat
      when :ok
        status, headers, errors = recv
        env['rack.errors'].write(errors)
        [status, headers, body]
      when :err
        error, backtrace = recv
        kill_process(host)
        [500, {'Content-Type' => 'text/html'}, [format_error(host, error, backtrace)]]
      end
    end

    def send_marshal(socket, data)
      data = Marshal.dump(data)
      socket.write([data.bytesize].pack('L'))
      socket.write(data)
    end

    def recv_marshal(socket)
      size = socket.read(4).unpack('L').first
      data = socket.read(size)
      data = Marshal.load(data)
      data
    end

    def send_body(socket, chunk)
      # We can be given massive chunks... Too big to write
      chunk.scan(/.{1,2048}/m).each do |subchunk|
        socket.write([subchunk.bytesize].pack('L'))
        socket.write(subchunk)
      end
    end

    def send_body_end(socket)
      socket.write([0].pack('L'))
    end

    class Body
      def initialize(socket)
        @socket = socket
      end

      def each
        while body = recv_body(@socket)
          yield body
        end
      end

      def recv_body(socket)
        size = socket.read(4).unpack('L').first
        return nil if size == 0
        @socket.read(size)
      end
    end

    def format_error(host, error, backtrace)
      "<h1>Error</h1>" +
      "<p>Something went wrong in the handler for '#{@map[host][:name]}'.</p>" +
      "<h3>#{Rack::Utils.escape_html(error)}</h3>" +
      "<pre>#{Rack::Utils.escape_html(backtrace.join("\n"))}</pre>"
    end

    def needs_reload?(host)
      return true if !@map[host][:socket] || @map[host][:socket].closed?
      reload_file = @map[host][:reload_file]
      return false unless reload_file && File.file?(reload_file)
      File.mtime(reload_file) > @map[host][:last_start]
    end

    def check_status(host)
      if !@map[host][:socket] || @map[host][:socket].closed?
        @map[host][:pid] = @map[host][:socket] = nil
        return
      end
      result = select([@map[host][:socket]], nil, nil, 0)
      # A result of nil means everything's fine
      return unless result
      # It dieded :(
      @map[host][:pid] = @map[host][:socket] = nil
    end

    def kill_process(host)
      return unless @map[host][:pid]
      print "Killing handler for #{@map[host][:name]} (PID #{@map[host][:pid]})... "
      Process.kill("KILL", @map[host][:pid])
      @map[host][:socket].close
      Process.wait(@map[host][:pid]) rescue Errno::ECHILD
      @map[host][:pid] = nil
      @map[host][:socket] = nil
      puts "Done"
    end

    def start_process(host)
      print "Spawning handler for #{@map[host][:name]}... "

      child_socket, parent_socket = UNIXSocket.pair

      pid = fork do
      host_config = @map[host]
      begin
        parent_socket.close
        ENV.update(host_config[:env])

        Dir.chdir(host_config[:dir])
        app = eval("Rack::Builder.new{( " + File.read(host_config[:rackup_file]) + "\n )}.to_app")

        loop do
          results = select([child_socket], nil, nil, host_config[:timeout])
          unless results
            puts "Timed out: #{host_config[:name]} (PID #{Process.pid})"
            child_socket.write("\0")
            child_socket.close
            Process.exit
          end

          env = recv_marshal(child_socket)
          # TODO does these need closing?
          env['rack.errors'] = StringIO.new
          env['rack.input'] = StringIO.new(env['rack.input'])

          status, headers, body = app.call(env)

          send_marshal(child_socket, [:ok, status, headers.to_hash, env['rack.errors'].read])
          body.each{ |chunk| send_body(child_socket, chunk) }
          send_body_end(child_socket)
        end
      rescue SystemExit
        Process.exit
      rescue Interrupt, SignalException, SystemExit
        puts "Interrupt: #{host_config[:name]} (PID #{Process.pid}). Exiting"
        # It's a bit crude, but if we write to the socket, this can be picked up by the select() in
        # check_status. I can't find any way to check on child status, without using exceptions
        child_socket.write("\0") unless child_socket.closed?
        Process.exit
        raise
      rescue Object => e
        puts "!! EXCEPTION: #{host_config[:name]} (PID #{Process.pid}) - #{e.class.name}"
        Process.exit if child_socket.closed?
        send_marshal(child_socket, [:err, "#{e.class.name}: #{e.to_s}", e.backtrace])
        child_socket.close
        Process.exit
      end
    end
    child_socket.close

    # The thread might exit by itself
    Process.detach(pid)
    @map[host][:socket] = parent_socket
    @map[host][:pid] = pid
    @map[host][:last_start] = Time.now
    puts "Done (PID #{pid})"
    end
  end
end
