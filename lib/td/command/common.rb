require 'td/version'

module TreasureData

autoload :API, 'td/client/api'
autoload :Client, 'td/client'
autoload :Database, 'td/client'
autoload :Table, 'td/client'
autoload :Schema, 'td/client'
autoload :Job, 'td/client'

module Command

  class ParameterConfigurationError < ArgumentError
  end

  class BulkImportExecutionError < ArgumentError
  end

  class UpdateError < ArgumentError
  end

  class ImportError < RuntimeError
  end

  private
  def initialize
    @render_indent = ''
  end

  def get_client(opts={})
    unless opts.has_key?(:ssl)
      opts[:ssl] = Config.secure
    end
    unless opts.has_key?(:retry_post_requests)
      opts[:retry_post_requests] = Config.retry_post_requests
    end

    # apikey is mandatory
    apikey = Config.apikey
    raise ConfigError, "Account is not configured." unless apikey

    # optional, if not provided a default is used from the ruby client library
    begin
      if Config.endpoint
        opts[:endpoint] = Config.endpoint
      end
    rescue ConfigNotFoundError => e
      # rescue the ConfigNotFoundError exception which originates when
      #   the config file is not found because the check on the apikey
      #   guarantees that the API key has been provided on the command
      #   line and that's good enough to continue since the default
      #   endpoint will be used in place of this definition.
    end

    opts[:user_agent] = "TD: #{TOOLBELT_VERSION}"
    if h = ENV['TD_API_HEADERS']
      pairs = h.split("\n")
      opts[:headers] = Hash[pairs.map {|pair| pair.split('=', 2) }]
    end

    Client.new(apikey, opts)
  end

  def get_ssl_client(opts={})
    opts[:ssl] = true
    get_client(opts)
  end

  def set_render_format_option(op)
    def op.render_format
      @_render_format
    end
    op.on('-f', '--format FORMAT', 'format of the result rendering (tsv, csv, json or table. default is table)') {|s|
      unless ['tsv', 'csv', 'json', 'table'].include?(s)
        raise "Unknown format #{s.dump}. Supported format: tsv, csv, json, table"
      end
      op.instance_variable_set(:@_render_format, s)
    }
  end

  def cmd_render_table(rows, *opts)
    require 'hirb'

    options = opts.first
    format = options.delete(:render_format)

    case format
    when 'csv', 'tsv'
      require 'csv'
      headers = options[:fields]
      csv_opts = {}
      csv_opts[:col_sep] = "\t" if format == 'tsv'
      CSV.generate('', csv_opts) { |csv|
        csv << headers
        rows.each { |row|
          r = []
          headers.each { |field|
            r << row[field]
          }
          csv << r
        }
      }
    when 'json'
      require 'yajl'

      Yajl.dump(rows)
    when 'table'
      Hirb::Helpers::Table.render(rows, *opts)
    else
      Hirb::Helpers::Table.render(rows, *opts)
    end
  end

  def normalized_message
    <<EOS
Your event has numbers larger than 2^64.
These numbers are converted into string type.
You should consider using the cast operator in your query: e.g. cast(v['key'] as decimal).
EOS
  end

  #def cmd_render_tree(nodes, *opts)
  #  require 'hirb'
  #  Hirb::Helpers::Tree.render(nodes, *opts)
  #end

  def cmd_debug_error(ex)
    if $verbose
      $stderr.puts "error: #{$!.class}: #{$!.to_s}"
      $!.backtrace.each {|b|
        $stderr.puts "  #{b}"
      }
      $stderr.puts ""
    end
  end

  def self.humanize_bytesize(size, fractional_digits = 1)
    labels = ["B", "kB", "MB", "GB", "TB"]
    max_power = labels.length - 1

    size = size.to_i

    if size == 0
      return "0 B"
    end

    # integer part
    value = size
    power = 0
    while value > 0 do
      value /= 1024
      power += 1
    end
    power -= 1
    power = power > max_power ? max_power : power # limit to TB display
    integer = size / (1024 ** power)
    out = integer.to_s

    # fractional part - remove the integer part to avoid running into floating
    # point precision problems
    value = size % ((1024 ** power) * integer)
    if value > 0 and fractional_digits > 0
      fractional = value.to_f / (1024 ** power)
      fractional *= 10 ** fractional_digits
      out += sprintf ".%0*d", fractional_digits, fractional.to_i
    end
    out += " " + labels[power.to_i]
    out
  end

  def self.humanize_time(time, is_ms = false)
    if time.nil?
      return ''
    end

    time = time.to_i
    millisecs = nil
    elapsed = ''

    if is_ms
      # store the first 3 decimals
      millisecs = time % 1000
      time /= 1000
    end

    if time >= 3600
      elapsed << "#{time / 3600}h "
      time %= 3600
      elapsed << "%dm " % (time / 60)
      time %= 60
      elapsed << "%ds" % time
    elsif time >= 60
      elapsed << "%dm " % (time / 60)
      time %= 60
      elapsed << "%ds" % time
    elsif time > 0
      elapsed << "%ds" % time
    end

    if is_ms and millisecs > 0
      elapsed << " %03dms" % millisecs
    end

    elapsed
  end

  # assumed to
  def self.humanize_elapsed_time(start, finish)
    if start
      if !finish
        finish = Time.now.utc
      end
      elapsed = humanize_time(finish.to_i - start.to_i, false)
    else
      elapsed = ''
    end
    elapsed
  end

  def get_database(client, db_name)
    begin
      return client.database(db_name)
    rescue
      cmd_debug_error $!
      $stderr.puts $!
      $stderr.puts "Use '#{$prog} database:list' to show the list of databases."
      exit 1
    end
    db
  end

  def get_table(client, db_name, table_name)
    db = get_database(client, db_name)
    begin
      table = db.table(table_name)
    rescue
      $stderr.puts $!
      $stderr.puts "Use '#{$prog} table:list #{db_name}' to show the list of tables."
      exit 1
    end
    #if type && table.type != type
    #  $stderr.puts "Table '#{db_name}.#{table_name} is not a #{type} table but a #{table.type} table"
    #end
    table
  end

  def ask_password(max=3, &block)
    3.times do
      begin
        system "stty -echo"  # TODO termios
        print "Password (typing will be hidden): "
        password = STDIN.gets || ""
        password = password[0..-2]  # strip \n
      rescue Interrupt
        $stderr.print "\ncanceled."
        exit 1
      ensure
        system "stty echo"   # TODO termios
        print "\n"
      end

      if password.empty?
        $stderr.puts "canceled."
        exit 0
      end

      yield password
    end
  end

  def self.validate_api_endpoint(endpoint)
    require 'uri'

    uri = URI.parse(endpoint)
    unless uri.kind_of?(URI::HTTP) || uri.kind_of?(URI::HTTPS)
      raise ParameterConfigurationError,
            "API server endpoint URL must use 'http' or 'https' protocol. Example format: 'https://api.treasuredata.com'"
    end
    unless uri.path =~ /^\/*$/
      raise ParameterConfigurationError,
            "API server path must be empty ('#{uri.path}' provided). Example format: 'https://api.treasuredata.com'"
    end

    if !(md = /(\d{1,3}).(\d{1,3}).(\d{1,3}).(\d{1,3})/.match(uri.host)).nil? # IP address
      md[1..-1].each { |v|
        if v.to_i < 0 || v.to_i > 255
          raise ParameterConfigurationError,
                "API server IP address must a 4 integers tuple, with every integer in the [0,255] range. Example format: 'https://1.2.3.4'"
        end
      }
    end
  end

  def self.test_api_endpoint(endpoint)
    begin
      # although the API may return 'Server is down' that is a good enough
      #   indication that we hit a valid TD endpoint to accept it
      Client.server_status(:endpoint => endpoint)
    rescue
      raise ParameterConfigurationError,
            "The specified API server endpoint (#{endpoint}) does not respond."
    end
  end

  def self.get_http_class
    # use Net::HTTP::Proxy in place of Net::HTTP if a proxy is provided
    http_proxy = ENV['HTTP_PROXY']
    if http_proxy
      http_proxy = (http_proxy =~ /\Ahttp:\/\/(.*)\z/) ? $~[1] : http_proxy
      host, port = http_proxy.split(':', 2)
      port = (port ? port.to_i : 80)
      return Net::HTTP::Proxy(host, port)
    else
      return Net::HTTP
    end
  end

  def self.find_files(glob, locations)
    files = []
    locations.each {|loc|
      files = Dir.glob("#{loc}/#{glob}")
      break unless files.empty?
    }
    files
  end

  class DownloadProgressIndicator
    def initialize(msg)
      @base_msg = msg
      print @base_msg + " " * 10
    end
  end

  class TimeBasedDownloadProgressIndicator < DownloadProgressIndicator
    def initialize(msg, start_time, periodicity = 2)
      @start_time = start_time
      @last_time = start_time
      @periodicity = periodicity
      super(msg)
    end

    def update
      if (time = Time.now.to_i) - @last_time >= @periodicity
        msg = "\r#{@base_msg}: #{Command.humanize_elapsed_time(@start_time, time)} elapsed"
        print "\r" + " " * (msg.length + 10)
        print msg
        @last_time = time
        true
      else
        false
      end
    end

    def finish
      puts "\r#{@base_msg}...done" + " " * 20
    end
  end

  class SizeBasedDownloadProgressIndicator < DownloadProgressIndicator
    def initialize(msg, size, perc_step = 1, min_periodicity = nil)
      @size = size

      # perc_step is how small a percentage increment can be shown
      @perc_step = perc_step

      # min_periodicity=X limits updates to one every X second
      @start_time = Time.now.to_i
      @min_periodicity = min_periodicity

      # track progress
      @last_perc_step = 0
      @last_time = @start_time

      super(msg)
    end

    def update(curr_size)
      if @size.nil? || @size == 0
        msg = "\r#{@base_msg}: #{Command.humanize_bytesize(curr_size)}"
        print msg
        true
      else
        ratio = (curr_size.to_f * 100 / @size).round(1)
        if ratio >= (@last_perc_step + @perc_step) &&
           (!@min_periodicity || (time = Time.now.to_i) - @last_time >= @min_periodicity)
          msg = "\r#{@base_msg}: #{Command.humanize_bytesize(curr_size)} / #{ratio}%"
          print "\r" + " " * (msg.length + 10)
          print msg
          @last_perc_step = ratio
          @last_time = time
          true
        else
          false
        end
      end
    end

    def finish
      print "\r#{@base_msg}...done" + " " * 20
    end
  end

end # module Command
end # module TrasureData
